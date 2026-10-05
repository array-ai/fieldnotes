@preconcurrency import CoreML
import FieldnoteKit
import FluidAudio
import Foundation
import OSLog

/// Batch diarization over the accumulated 16 kHz mono buffer, once, on stop
/// (spec 4.2 / 4.4). Apple still ships no diarization API in iOS 27 — the Speech
/// modules are `SpeechTranscriber`, `DictationTranscriber` and `SpeechDetector`
/// (voice activity only) — so this is FluidAudio's CoreML pipelines.
///
/// Three interchangeable methods, chosen in Settings (`DiarizationMethod`):
///
/// - **Nemotron 3** — NVIDIA's end-to-end streaming Sortformer. Predicts up to eight
///   speakers per frame, overlap included, with no clustering step.
/// - **pyannote community-1** — segmentation + WeSpeaker embeddings + PLDA/VBx
///   clustering over the whole recording.
/// - **pyannote 3.1 (legacy)** — segmentation + WeSpeaker with greedy clustering.
///
/// # Models are bundled, never downloaded
///
/// FluidAudio's convenience paths fetch their CoreML models over the network on first
/// use. Fieldnote makes zero outbound requests (constraint 1 and 2), so every model
/// is vendored into the app bundle at build time and loaded from there with plain
/// `MLModel(contentsOf:)` or FluidAudio's local-file loaders. If a bundled model is
/// missing this type fails loudly rather than reaching for the network — see
/// `Scripts/vendor-diarization-models.sh` and the README note.
public actor DiarizationService {

    public struct Output: Sendable {
        public var spans: [DiarizedSpan]
        /// One raw embedding per cluster. Dead weight in v1 by design: v2's
        /// cross-meeting matching (spec 11.3) needs a corpus, and backfilling
        /// embeddings from archived audio later is far more painful than storing
        /// them now. Empty for Nemotron 3, which has no embedding stage.
        public var embeddings: [String: [Float]]
    }

    /// One instance for the app, so models loaded for one meeting (or prewarmed
    /// while it was recording) are still loaded for the next.
    public static let shared = DiarizationService()

    private let log = Logger(subsystem: "com.publicarray.fieldnotes", category: "diarization")
    private let debug = DebugLog.shared

    // One cached engine per method: loading compiles CoreML graphs, which is slow
    // enough to matter when a backlog of meetings is processed in one task.
    private var legacyManager: DiarizerManager?
    private var community1Models: OfflineDiarizerModels?

    // Nemotron 3 has two loaded forms. The Neural Engine one is the fast one to run,
    // but CoreML compiles it for the ANE on first load — about two minutes on an
    // iPhone, measured — before caching the result. The CPU one loads in seconds.
    // So the ANE load starts early (app launch) and runs once, shared by everyone
    // waiting on it; anything that needs the model before it's ready uses the CPU
    // one instead of waiting.
    private var aneModels: Nemotron3Models?
    private var aneLoad: Task<LoadedModels, Error>?
    private var cpuModels: Nemotron3Models?

    /// Live identification during a recording: its own stream state, sharing a
    /// loaded model with the batch path. Calls never overlap — this actor serialises
    /// them — so sharing the model's buffers is safe.
    private var live: Nemotron3Diarizer?
    /// Requested but the model isn't ready yet: audio waits here, then catches up.
    private var liveRequested = false
    private var liveQueue: [Float] = []
    private var liveProbabilities: [Float] = []
    private var liveFrames = 0
    /// Ten minutes of 16 kHz audio. Past this, waiting on the model isn't worth the
    /// memory; speakers are found after stop instead.
    private let maxLiveQueue = 16_000 * 600

    public init() {}

    public func diarize(
        samples: [Float],
        method: DiarizationMethod,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> Output {
        guard samples.count > 16_000 else {
            // Under a second of audio. Nothing to cluster.
            return Output(spans: [], embeddings: [:])
        }

        progress(0.05)
        let seconds = String(format: "%.1f", Double(samples.count) / 16_000)
        debug.log("speakers", "\(method.rawValue): \(seconds)s of audio")

        if method != .nemotron3 {
            // Nemotron logs its own load, which may be the CPU fallback.
            let loadStarted = ContinuousClock.now
            let wasLoaded = isLoaded(method)
            try await load(method)
            debug.log("speakers", "\(method.rawValue): models \(wasLoaded ? "already loaded" : "loaded in \(DebugLog.elapsed(since: loadStarted))")")
        }

        let runStarted = ContinuousClock.now
        let output: Output
        do {
            switch method {
            case .nemotron3:
                output = try await diarizeNemotron(samples, progress: progress)
            case .pyannoteCommunity1:
                output = try await diarizeCommunity1(samples, progress: progress)
            case .pyannoteLegacy:
                output = try diarizeLegacy(samples, progress: progress)
            }
        } catch {
            debug.log("speakers", "\(method.rawValue): failed after \(DebugLog.elapsed(since: runStarted)): \(error)")
            throw error
        }
        debug.log(
            "speakers",
            "\(method.rawValue): \(output.spans.count) spans, \(Set(output.spans.map(\.speakerID)).count) speaker(s), inference \(DebugLog.elapsed(since: runStarted))"
        )
        progress(1.0)
        log.notice("\(method.rawValue, privacy: .public): diarized \(output.spans.count, privacy: .public) spans across \(Set(output.spans.map(\.speakerID)).count, privacy: .public) speakers")
        return output
    }

    /// Loads a method's models ahead of time — called when a recording starts, so
    /// CoreML's first-load compile (often the slowest part for a short meeting)
    /// happens while the user is still talking rather than after stop.
    public func prewarm(_ method: DiarizationMethod) async {
        guard !isLoaded(method) else { return }
        let started = ContinuousClock.now
        do {
            if method == .nemotron3 {
                _ = try await neuralEngineModels()
            } else {
                try await load(method)
            }
            debug.log("speakers", "\(method.rawValue): prewarmed in \(DebugLog.elapsed(since: started))")
        } catch {
            debug.log("speakers", "\(method.rawValue): prewarm failed: \(error)")
        }
    }

    /// Starts the slow Neural Engine compile without waiting for it. Called at app
    /// launch, so it is normally done long before a meeting ends.
    public func warmUpInBackground(_ method: DiarizationMethod) {
        if method == .nemotron3 {
            startNeuralEngineLoad()
        } else {
            Task(priority: .utility) { await self.prewarm(method) }
        }
    }

    /// Seconds to load Nemotron for the CPU, for the benchmark. Drops the result.
    public func timeCPULoad() async throws -> Double {
        let started = ContinuousClock.now
        _ = try await Nemotron3Models.load(
            config: DiarizationModelProvider.nemotronConfig,
            directory: try DiarizationModelProvider.nemotronDirectory(),
            computeUnits: .cpuOnly
        )
        let elapsed = started.duration(to: .now)
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }

    /// Drops a method's loaded models, so the benchmark can time a cold load.
    /// Refuses while live identification is running.
    public func unload(_ method: DiarizationMethod) {
        switch method {
        case .nemotron3:
            // Never drop a load that's still running: something may be waiting on it.
            guard live == nil, !liveRequested, aneLoad == nil || aneModels != nil else { return }
            aneModels = nil
            aneLoad = nil
            cpuModels = nil
        case .pyannoteCommunity1:
            community1Models = nil
        case .pyannoteLegacy:
            legacyManager = nil
        }
    }

    public func isLoaded(_ method: DiarizationMethod) -> Bool {
        switch method {
        case .nemotron3: aneModels != nil
        case .pyannoteCommunity1: community1Models != nil
        case .pyannoteLegacy: legacyManager != nil
        }
    }

    private func load(_ method: DiarizationMethod) async throws {
        switch method {
        case .nemotron3: _ = try await neuralEngineModels()
        case .pyannoteCommunity1: _ = try preparedCommunity1Models()
        case .pyannoteLegacy: _ = try preparedLegacyManager()
        }
    }

    /// Per-meeting labels only. "S1" is a label in this meeting, not a person, and it
    /// does not carry to the next meeting (spec 4.4).
    static func label(for speakerID: String) -> String {
        let digits = speakerID.filter(\.isNumber)
        return digits.isEmpty ? speakerID : "S\(digits)"
    }

    // MARK: - Nemotron 3

    /// Audio is fed in slices through the streaming API rather than `processComplete`,
    /// which computes the mel spectrogram for the whole recording up front — ~550 MB
    /// for a three-hour meeting. The streaming frontend drops audio and features as
    /// soon as they are consumed, and its output is frame-exact with `processComplete`.
    private func diarizeNemotron(
        _ samples: [Float],
        progress: @Sendable (Double) -> Void
    ) async throws -> Output {
        let waited = ContinuousClock.now
        let models = try await nemotronModelsForRun()
        debug.log("speakers", "nemotron3: model ready for this run after \(DebugLog.elapsed(since: waited))")
        return try await runNemotron(samples, models: models, progress: progress)
    }

    /// Benchmark only: runs Nemotron on the CPU model, whatever else is loaded.
    /// Returns the speaker count and the seconds the run took.
    public func benchmarkNemotronOnCPU(_ samples: [Float]) async throws -> (speakers: Int, seconds: Double) {
        if cpuModels == nil {
            cpuModels = try await Nemotron3Models.load(
                config: DiarizationModelProvider.nemotronConfig,
                directory: try DiarizationModelProvider.nemotronDirectory(),
                computeUnits: .cpuOnly
            )
        }
        guard let cpuModels else { throw DiarizationModelProvider.Failure.modelsMissing }
        let started = ContinuousClock.now
        let output = try await runNemotron(samples, models: cpuModels, progress: { _ in })
        let elapsed = started.duration(to: .now)
        return (
            Set(output.spans.map(\.speakerID)).count,
            Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        )
    }

    private func runNemotron(
        _ samples: [Float],
        models: Nemotron3Models,
        progress: @Sendable (Double) -> Void
    ) async throws -> Output {
        let config = DiarizationModelProvider.nemotronConfig
        let diarizer = Nemotron3Diarizer(config: config, models: models)
        progress(0.15)
        diarizer.reset()

        let slice = 60 * config.sampleRate
        var probabilities: [Float] = []
        var frameCount = 0
        var offset = 0
        while offset < samples.count {
            let end = min(offset + slice, samples.count)
            diarizer.appendAudio(Array(samples[offset..<end]))
            for chunk in try diarizer.processBufferedAudio() {
                probabilities.append(contentsOf: chunk.probabilities)
                frameCount += chunk.frameCount
            }
            offset = end
            progress(0.15 + 0.8 * Double(offset) / Double(samples.count))
            try Task.checkCancellation()
        }
        for chunk in try diarizer.finishStream() {
            probabilities.append(contentsOf: chunk.probabilities)
            frameCount += chunk.frameCount
        }

        let spans = SpeakerActivity.spans(
            probabilities: probabilities,
            frameCount: frameCount,
            speakerCount: config.numSpeakers,
            frameSeconds: Double(config.outputFrameSeconds)
        )
        return Output(spans: spans, embeddings: [:])
    }

    /// The Neural Engine models, waiting for the one shared load if it's running.
    private func neuralEngineModels() async throws -> Nemotron3Models {
        if let aneModels { return aneModels }
        startNeuralEngineLoad()
        guard let aneLoad else { throw DiarizationModelProvider.Failure.modelsMissing }
        return try await aneLoad.value.models
    }

    private func startNeuralEngineLoad() {
        guard aneModels == nil, aneLoad == nil else { return }
        debug.log("speakers", "nemotron3: Neural Engine load started (first load compiles the model; slow once)")
        aneLoad = Task {
            let started = ContinuousClock.now
            do {
                // Neural Engine, not GPU: processing runs inside a background task,
                // and the split W8A8 build is 100% ANE-resident by design.
                let models = try await Nemotron3Models.load(
                    config: DiarizationModelProvider.nemotronConfig,
                    directory: try DiarizationModelProvider.nemotronDirectory(),
                    computeUnits: .cpuAndNeuralEngine
                )
                self.aneModels = models
                self.debug.log("speakers", "nemotron3: Neural Engine model ready in \(DebugLog.elapsed(since: started))")
                return LoadedModels(models: models)
            } catch {
                self.aneLoad = nil
                self.debug.log("speakers", "nemotron3: Neural Engine load failed: \(error)")
                throw error
            }
        }
    }

    /// Whatever can run now: the Neural Engine models if they're ready, otherwise the
    /// CPU models (loading those if needed) while the Neural Engine compile carries on
    /// for next time.
    private func nemotronModelsForRun() async throws -> Nemotron3Models {
        if let aneModels {
            debug.log("speakers", "nemotron3: using the Neural Engine model")
            return aneModels
        }
        startNeuralEngineLoad()
        if let cpuModels {
            debug.log("speakers", "nemotron3: Neural Engine model not ready yet; using the CPU model")
            return cpuModels
        }
        let started = ContinuousClock.now
        let models = try await Nemotron3Models.load(
            config: DiarizationModelProvider.nemotronConfig,
            directory: try DiarizationModelProvider.nemotronDirectory(),
            computeUnits: .cpuOnly
        )
        // The ANE load may have finished while this one ran.
        if let aneModels { return aneModels }
        cpuModels = models
        debug.log("speakers", "nemotron3: Neural Engine model not ready yet; CPU model loaded in \(DebugLog.elapsed(since: started))")
        return models
    }

    // MARK: - Live (Nemotron 3, while recording)

    /// Starts identifying speakers from audio as it is recorded. Nemotron 3 is a
    /// streaming model; with the bundled preset it labels each stretch of speech about
    /// ten seconds after it is spoken.
    ///
    /// Returns at once. Recording never waits on the model: audio queues until a
    /// model is ready (CPU within seconds, or the Neural Engine one if already
    /// loaded), then catches up.
    public func beginLive() {
        live = nil
        liveRequested = true
        liveQueue = []
        liveProbabilities = []
        liveFrames = 0
        let requested = ContinuousClock.now
        Task {
            do {
                let models = try await self.nemotronModelsForRun()
                guard self.liveRequested, self.live == nil else { return }
                let diarizer = Nemotron3Diarizer(config: DiarizationModelProvider.nemotronConfig, models: models)
                diarizer.reset()
                self.live = diarizer
                let backlog = self.liveQueue
                self.liveQueue = []
                self.debug.log("speakers", "live identification running after \(DebugLog.elapsed(since: requested)), catching up on \(String(format: "%.1f", Double(backlog.count) / 16_000))s of audio")
                _ = try? self.feedLive(backlog)
            } catch {
                self.debug.log("speakers", "live identification couldn't load a model: \(error)")
                self.cancelLive()
            }
        }
    }

    /// Feeds 16 kHz mono samples. Returns the updated spans when this audio completed
    /// at least one more chunk of the model's window, nil otherwise.
    public func appendLive(_ samples: [Float]) throws -> [DiarizedSpan]? {
        guard !samples.isEmpty else { return nil }
        guard live != nil else {
            guard liveRequested else { return nil }
            liveQueue.append(contentsOf: samples)
            if liveQueue.count > maxLiveQueue {
                debug.log("speakers", "live identification gave up waiting for a model; speakers will be found after stop")
                cancelLive()
            }
            return nil
        }
        return try feedLive(samples)
    }

    private func feedLive(_ samples: [Float]) throws -> [DiarizedSpan]? {
        guard let live, !samples.isEmpty else { return nil }
        live.appendAudio(samples)
        let results = try live.processBufferedAudio()
        guard !results.isEmpty else { return nil }
        for chunk in results {
            liveProbabilities.append(contentsOf: chunk.probabilities)
            liveFrames += chunk.frameCount
        }
        return liveSpans()
    }

    /// Flushes the tail and returns the whole recording's speakers. Nil if live
    /// identification wasn't running.
    public func finishLive() throws -> Output? {
        guard let live else {
            if liveRequested {
                debug.log("speakers", "live identification wasn't running by stop; speakers will be found after stop")
            }
            cancelLive()
            return nil
        }
        liveRequested = false
        for chunk in try live.finishStream() {
            liveProbabilities.append(contentsOf: chunk.probabilities)
            liveFrames += chunk.frameCount
        }
        let spans = liveSpans()
        self.live = nil
        liveProbabilities = []
        liveFrames = 0
        debug.log("speakers", "live identification finished: \(spans.count) spans, \(Set(spans.map(\.speakerID)).count) speaker(s)")
        return Output(spans: spans, embeddings: [:])
    }

    /// Stops without a result, after a failure.
    public func cancelLive() {
        live = nil
        liveRequested = false
        liveQueue = []
        liveProbabilities = []
        liveFrames = 0
    }

    private func liveSpans() -> [DiarizedSpan] {
        let config = DiarizationModelProvider.nemotronConfig
        return SpeakerActivity.spans(
            probabilities: liveProbabilities,
            frameCount: liveFrames,
            speakerCount: config.numSpeakers,
            frameSeconds: Double(config.outputFrameSeconds)
        )
    }

    // MARK: - pyannote community-1

    private func diarizeCommunity1(
        _ samples: [Float],
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> Output {
        // A fresh manager per run: it is cheap (the models are the cached part), and
        // it is not Sendable, so one stored on this actor could not be handed to its
        // nonisolated async `process`.
        let manager = OfflineDiarizerManager()
        manager.initialize(models: try preparedCommunity1Models())
        progress(0.15)
        let result = try await manager.process(audio: samples) { done, total in
            guard total > 0 else { return }
            progress(0.15 + 0.75 * Double(done) / Double(total))
        }
        progress(0.95)

        let spans = result.segments.map { segment in
            DiarizedSpan(
                start: TimeInterval(segment.startTimeSeconds),
                end: TimeInterval(segment.endTimeSeconds),
                speakerID: Self.label(for: segment.speakerId),
                confidence: Double(segment.qualityScore)
            )
        }
        var embeddings: [String: [Float]] = [:]
        for (speaker, embedding) in result.speakerDatabase ?? [:] {
            embeddings[Self.label(for: speaker)] = embedding
        }
        return Output(spans: spans, embeddings: embeddings)
    }

    private func preparedCommunity1Models() throws -> OfflineDiarizerModels {
        if let community1Models { return community1Models }
        let loaded = try DiarizationModelProvider.community1Models()
        community1Models = loaded
        return loaded
    }

    // MARK: - pyannote 3.1 (legacy)

    private func diarizeLegacy(
        _ samples: [Float],
        progress: @Sendable (Double) -> Void
    ) throws -> Output {
        let manager = try preparedLegacyManager()
        progress(0.2)

        let result = try manager.performCompleteDiarization(samples, sampleRate: 16_000)
        progress(0.9)

        var spans: [DiarizedSpan] = []
        var embeddings: [String: [Float]] = [:]
        for segment in result.segments {
            let label = Self.label(for: segment.speakerId)
            spans.append(
                DiarizedSpan(
                    start: TimeInterval(segment.startTimeSeconds),
                    end: TimeInterval(segment.endTimeSeconds),
                    speakerID: label,
                    confidence: Double(segment.qualityScore)
                )
            )
            if embeddings[label] == nil {
                embeddings[label] = segment.embedding
            }
        }
        return Output(spans: spans, embeddings: embeddings)
    }

    private func preparedLegacyManager() throws -> DiarizerManager {
        if let legacyManager { return legacyManager }
        let models = try DiarizationModelProvider.legacyModels()
        let created = DiarizerManager()
        created.initialize(models: models)
        legacyManager = created
        return created
    }
}

/// Loads the vendored CoreML models from the app bundle.
///
/// Deliberately never uses FluidAudio's convenience loaders. `DiarizerModels.load(from:)`,
/// `OfflineDiarizerModels.load(from:)` and `Nemotron3Models.loadFromHuggingFace` all
/// fall back to a network fetch when a file is missing — which would break constraint 1
/// silently and only on a fresh install. Everything here reads local files only.
public enum DiarizationModelProvider {

    /// Where `xtool.yml` puts `Resources/DiarizationModels`: the bundle root.
    public static var bundledModelDirectory: URL? {
        Bundle.main.resourceURL?.appending(path: "DiarizationModels", directoryHint: .isDirectory)
    }

    // MARK: Legacy pyannote 3.1

    /// From FluidAudio's `ModelNames.Diarizer`. Compiled CoreML bundles (`.mlmodelc`).
    static let segmentationFile = "pyannote_segmentation.mlmodelc"
    static let embeddingFile = "wespeaker_v2.mlmodelc"

    public static func legacyModels() throws -> DiarizerModels {
        // An optional download now, not bundled.
        guard let directory = ModelDownloads.installedDirectory(for: .pyannoteLegacy) else { throw Failure.notDownloaded }
        // `load(localSegmentationModel:localEmbeddingModel:)` touches no network: its
        // own documentation says "No models are downloaded."
        return try DiarizerModels.load(
            localSegmentationModel: try existing(segmentationFile, in: directory),
            localEmbeddingModel: try existing(embeddingFile, in: directory)
        )
    }

    // MARK: pyannote community-1

    public static func community1Models() throws -> OfflineDiarizerModels {
        // An optional download now, not bundled.
        guard let directory = ModelDownloads.installedDirectory(for: .pyannoteCommunity1) else { throw Failure.notDownloaded }
        let start = Date()

        func model(_ name: String, _ units: MLComputeUnits) throws -> MLModel {
            let configuration = MLModelConfiguration()
            configuration.computeUnits = units
            return try MLModel(contentsOf: existing(name, in: directory), configuration: configuration)
        }

        // Compute units mirror `OfflineDiarizerModels.load`: FBank is fastest on CPU.
        let names = ModelNames.OfflineDiarizer.self
        return OfflineDiarizerModels(
            segmentationModel: try model(names.segmentationFile, .cpuAndNeuralEngine),
            fbankModel: try model(names.fbankFile, .cpuOnly),
            embeddingModel: try model(names.embeddingFile, .cpuAndNeuralEngine),
            pldaRhoModel: try model(names.pldaRhoFile, .cpuAndNeuralEngine),
            pldaPsi: try pldaPsi(at: existing(names.pldaParameters, in: directory)),
            compilationDuration: Date().timeIntervalSince(start)
        )
    }

    /// The `psi` tensor from `plda-parameters.json`: base64 little-endian Float32.
    /// FluidAudio's own parser is private to its network-backed loader, so this is
    /// the same few lines.
    static func pldaPsi(at url: URL) throws -> [Double] {
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        guard
            let tensors = root?["tensors"] as? [String: Any],
            let psi = tensors["psi"] as? [String: Any],
            let base64 = psi["data_base64"] as? String,
            let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters),
            data.count >= MemoryLayout<Float>.size
        else { throw Failure.modelsMissing }

        var floats = [Float](repeating: 0, count: data.count / MemoryLayout<Float>.size)
        _ = floats.withUnsafeMutableBytes { data.copyBytes(to: $0) }
        return floats.map(Double.init)
    }

    // MARK: Nemotron 3

    /// `c128-split-w8a8`: the 10.24 s window that counts speakers correctly on all 16
    /// AMI test meetings, with W8A8 weights at half the size (95 MB) of the fp16
    /// presets and a graph that runs entirely on the Neural Engine. Latency is
    /// irrelevant here — diarization runs once, after stop.
    static let nemotronPreset = "c128-split-w8a8"

    static var nemotronConfig: Nemotron3Config {
        // A preset name FluidAudio does not know is a programming error caught the
        // first time diarization runs on any device, not a runtime condition.
        guard let config = Nemotron3Config.preset(named: nemotronPreset) else {
            preconditionFailure("FluidAudio has no Nemotron 3 preset named \(nemotronPreset)")
        }
        return config
    }

    /// Holds the preset's `.mlmodelc` next to `learnable_sil_emb.bin` and
    /// `pre_encode_proj_t.bin`, flat, which is the layout `Nemotron3Models.load`
    /// expects.
    static func nemotronDirectory() throws -> URL {
        let directory = try modelDirectory().appending(path: "Nemotron3", directoryHint: .isDirectory)
        _ = try existing(nemotronConfig.modelFileName, in: directory)
        _ = try existing(ModelNames.Nemotron3.silenceEmbeddingFile, in: directory)
        _ = try existing(ModelNames.Nemotron3.preEncodeProjectionFile, in: directory)
        return directory
    }

    // MARK: Shared

    private static func modelDirectory() throws -> URL {
        guard let directory = bundledModelDirectory else { throw Failure.modelsMissing }
        return directory
    }

    private static func existing(_ name: String, in directory: URL) throws -> URL {
        let url = directory.appending(path: name)
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            throw Failure.modelsMissing
        }
        return url
    }

    public enum Failure: Error, LocalizedError {
        case modelsMissing
        case notDownloaded

        public var errorDescription: String? {
            switch self {
            case .notDownloaded:
                "This speaker model isn't downloaded. Download it in Settings → Models."
            case .modelsMissing:
                """
                The bundled Nemotron speaker model is missing from the app. Vendor it \
                into Resources/DiarizationModels before building — see \
                Scripts/fetch-diarization-models.sh.
                """
            }
        }
    }
}

/// Carries a loaded model out of the load task. `Nemotron3Models` holds CoreML
/// objects and isn't Sendable; it is only ever used on `DiarizationService`.
final class LoadedModels: @unchecked Sendable {
    let models: Nemotron3Models
    init(models: Nemotron3Models) { self.models = models }
}

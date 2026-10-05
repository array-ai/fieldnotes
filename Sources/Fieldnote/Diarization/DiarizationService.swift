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
    private var nemotron: Nemotron3Diarizer?
    private var nemotronModels: Nemotron3Models?

    /// Live identification during a recording: its own stream state, sharing the
    /// loaded model with the batch path. The two never run at once — this actor
    /// serialises every call — so sharing the model's buffers is safe.
    private var live: Nemotron3Diarizer?
    private var liveProbabilities: [Float] = []
    private var liveFrames = 0

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

        let loadStarted = ContinuousClock.now
        let wasLoaded = isLoaded(method)
        try await load(method)
        debug.log("speakers", "\(method.rawValue): models \(wasLoaded ? "already loaded" : "loaded in \(DebugLog.elapsed(since: loadStarted))")")

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
            try await load(method)
            debug.log("speakers", "\(method.rawValue): prewarmed in \(DebugLog.elapsed(since: started))")
        } catch {
            debug.log("speakers", "\(method.rawValue): prewarm failed: \(error)")
        }
    }

    /// Drops a method's loaded models, so the benchmark can time a cold load.
    /// Refuses while live identification is running.
    public func unload(_ method: DiarizationMethod) {
        switch method {
        case .nemotron3:
            guard live == nil else { return }
            nemotron = nil
            nemotronModels = nil
        case .pyannoteCommunity1:
            community1Models = nil
        case .pyannoteLegacy:
            legacyManager = nil
        }
    }

    public func isLoaded(_ method: DiarizationMethod) -> Bool {
        switch method {
        case .nemotron3: nemotron != nil
        case .pyannoteCommunity1: community1Models != nil
        case .pyannoteLegacy: legacyManager != nil
        }
    }

    private func load(_ method: DiarizationMethod) async throws {
        switch method {
        case .nemotron3: _ = try await preparedNemotron()
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
        let diarizer = try await preparedNemotron()
        progress(0.15)
        diarizer.reset()

        let config = diarizer.config
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

    private func preparedNemotron() async throws -> Nemotron3Diarizer {
        if let nemotron { return nemotron }
        let config = DiarizationModelProvider.nemotronConfig
        // Neural Engine, not GPU: this runs inside a background continued-processing
        // task, and the split W8A8 build is 100% ANE-resident by design.
        let models = try await Nemotron3Models.load(
            config: config,
            directory: try DiarizationModelProvider.nemotronDirectory(),
            computeUnits: .cpuAndNeuralEngine
        )
        let created = Nemotron3Diarizer(config: config, models: models)
        nemotronModels = models
        nemotron = created
        return created
    }

    // MARK: - Live (Nemotron 3, while recording)

    /// Starts identifying speakers from audio as it is recorded. Nemotron 3 is a
    /// streaming model; with the bundled preset it labels each stretch of speech about
    /// ten seconds after it is spoken.
    public func beginLive() async throws {
        let started = ContinuousClock.now
        _ = try await preparedNemotron()
        guard let models = nemotronModels else { return }
        let diarizer = Nemotron3Diarizer(config: DiarizationModelProvider.nemotronConfig, models: models)
        diarizer.reset()
        live = diarizer
        liveProbabilities = []
        liveFrames = 0
        debug.log("speakers", "live identification started (model ready in \(DebugLog.elapsed(since: started)))")
    }

    /// Feeds 16 kHz mono samples. Returns the updated spans when this audio completed
    /// at least one more chunk of the model's window, nil otherwise.
    public func appendLive(_ samples: [Float]) throws -> [DiarizedSpan]? {
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
        guard let live else { return nil }
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
        let directory = try modelDirectory()
        // `load(localSegmentationModel:localEmbeddingModel:)` touches no network: its
        // own documentation says "No models are downloaded."
        return try DiarizerModels.load(
            localSegmentationModel: try existing(segmentationFile, in: directory),
            localEmbeddingModel: try existing(embeddingFile, in: directory)
        )
    }

    // MARK: pyannote community-1

    public static func community1Models() throws -> OfflineDiarizerModels {
        let directory = try modelDirectory()
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

        public var errorDescription: String? {
            """
            The speaker-identification models are not in the app bundle. Fieldnote \
            does not download them, by design. Vendor them into \
            Resources/DiarizationModels before building — see \
            Scripts/vendor-diarization-models.sh.
            """
        }
    }
}

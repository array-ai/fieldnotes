import FieldnoteKit
import FluidAudio
import Foundation

/// NVIDIA Nemotron 3.5 ASR Streaming (optional download): the transcript written
/// while recording, in place of Apple's live model.
///
/// It takes the same 16 kHz mono samples as live speaker identification. `append`
/// only queues them, so the audio pump never waits on the model; a drain loop feeds
/// the queue through the model in 2.24 s chunks and publishes the lines so far.
/// Until the model has loaded (seconds, or a few minutes the very first time while
/// the Neural Engine compiles it) audio just queues.
///
/// If the model can't load or fails mid-recording, `finish` returns nil and the
/// pipeline transcribes the recording from disk instead, with this model or Apple's.
actor NemotronStreamingTranscriber {

    /// The pack's Latin-script, 2,240 ms build (the only one downloaded).
    static let variantPath = "latin/2240ms"

    static func modelDirectory() -> URL? {
        ModelDownloads.installedDirectory(for: .nemotronStreaming)?
            .appendingPathComponent(variantPath, isDirectory: true)
    }

    /// Chosen in Settings, downloaded, and covering this language.
    static func isSelected(for localeIdentifier: String) -> Bool {
        let engine = TranscriptionEngine(storedValue: UserDefaults.standard.string(forKey: TranscriptionEngine.defaultsKey))
        return engine == .nemotronStreaming && engine.supports(localeIdentifier) && modelDirectory() != nil
    }

    private let manager = StreamingNemotronMultilingualAsrManager()
    private let onLines: @Sendable ([TranscriptSegment]) -> Void
    private var loading: Task<Void, Error>?
    private var ready = false
    private var failed = false
    private var pending: [Float] = []
    private var draining = false

    init(onLines: @escaping @Sendable ([TranscriptSegment]) -> Void = { _ in }) {
        self.onLines = onLines
    }

    /// Starts loading; returns at once.
    func begin(localeIdentifier: String) {
        guard loading == nil, let directory = Self.modelDirectory() else {
            failed = true
            return
        }
        let manager = manager
        let language = localeIdentifier.replacingOccurrences(of: "_", with: "-")
        loading = Task {
            let started = ContinuousClock.now
            let shared = try await StreamingNemotronMultilingualAsrManager.preloadShared(from: directory)
            try await manager.loadFromShared(shared)
            await manager.setLanguage(language)
            DebugLog.shared.log("transcript", "nemotronStreaming: model ready in \(DebugLog.elapsed(since: started))")
            await self.markReady()
        }
    }

    private func markReady() {
        ready = true
        drainIfNeeded()
    }

    /// Queues 16 kHz mono samples. Never waits on the model.
    func append(_ samples: [Float]) {
        guard !failed, !samples.isEmpty else { return }
        pending.append(contentsOf: samples)
        drainIfNeeded()
    }

    private func drainIfNeeded() {
        guard ready, !draining, !failed, !pending.isEmpty else { return }
        draining = true
        Task { await self.drain() }
    }

    private func drain() async {
        while !pending.isEmpty, !failed {
            let batch = pending
            pending = []
            do {
                _ = try await manager.process(samples: batch)
                onLines(await currentLines())
            } catch {
                failed = true
                DebugLog.shared.log("transcript", "nemotronStreaming: stopped while recording (\(error)); the recording will be transcribed after stop")
            }
        }
        draining = false
    }

    private func currentLines() async -> [TranscriptSegment] {
        Self.lines(from: await manager.getTokenTimings())
    }

    static func lines(from timings: [TokenTiming]) -> [TranscriptSegment] {
        let words = buildWordTimings(from: timings).map {
            TranscriptWord(text: $0.word + " ", start: $0.startTime, end: $0.endTime)
        }
        return WordLines.lines(from: words)
    }

    /// Processes what's still queued and returns the whole transcript, or nil if
    /// the model never loaded or failed (the pipeline then transcribes from disk).
    func finish() async -> [TranscriptSegment]? {
        defer { Task { await manager.cleanup() } }
        guard let loading, !failed else { return nil }
        guard ready else {
            // Still loading at stop: don't hold the stop up; transcribe from disk.
            loading.cancel()
            DebugLog.shared.log("transcript", "nemotronStreaming: model not ready by stop; the recording will be transcribed after stop")
            return nil
        }
        while draining { try? await Task.sleep(for: .milliseconds(50)) }
        do {
            if !pending.isEmpty {
                let batch = pending
                pending = []
                _ = try await manager.process(samples: batch)
            }
            let result = try await manager.finishWithTokenTimings()
            return Self.lines(from: result.timings)
        } catch {
            DebugLog.shared.log("transcript", "nemotronStreaming: couldn't finish (\(error)); the recording will be transcribed after stop")
            return nil
        }
    }

    // MARK: - From a file

    /// Transcribes a meeting's stored 16 kHz audio: imports, a redo, or a recording
    /// whose live transcript didn't finish.
    static func transcribe(
        meetingID: UUID,
        localeIdentifier: String,
        progress: @Sendable (Double) -> Void
    ) async throws -> [TranscriptSegment] {
        guard let directory = modelDirectory() else { throw ParakeetTranscriber.Failure.notDownloaded }
        let id = DebugLog.short(meetingID)
        let loadStarted = ContinuousClock.now
        let manager = StreamingNemotronMultilingualAsrManager()
        let shared = try await StreamingNemotronMultilingualAsrManager.preloadShared(from: directory)
        try await manager.loadFromShared(shared)
        await manager.setLanguage(localeIdentifier.replacingOccurrences(of: "_", with: "-"))
        DebugLog.shared.log("transcript", "\(id): nemotronStreaming loaded in \(DebugLog.elapsed(since: loadStarted))")
        progress(0.1)

        let samples = try AudioSamples(meetingID: meetingID)
        guard samples.count > 8_000 else { throw ParakeetTranscriber.Failure.noAudio }
        let runStarted = ContinuousClock.now
        // Ten seconds at a time, for progress and cancellation.
        let step = 160_000
        var offset = 0
        while offset < samples.count {
            try Task.checkCancellation()
            let end = min(offset + step, samples.count)
            _ = try await manager.process(samples: try samples.slice(offset..<end))
            offset = end
            progress(0.1 + 0.9 * Double(offset) / Double(samples.count))
        }
        let result = try await manager.finishWithTokenTimings()
        await manager.cleanup()
        let lines = lines(from: result.timings)
        let seconds = Double(samples.count) / 16_000
        let elapsed = runStarted.duration(to: .now)
        let run = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        DebugLog.shared.log(
            "transcript",
            String(format: "%@: nemotronStreaming transcribed %.0f s in %.1f s (%.0f× real time), %d lines",
                   id, seconds, run, seconds / max(run, 0.001), lines.count)
        )
        return lines
    }
}

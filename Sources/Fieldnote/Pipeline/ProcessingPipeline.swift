import FieldnoteKit
import Foundation
import OSLog

/// Transcribe → diarize → summarise, resumable at every stage.
///
/// Runs inside a `BGContinuedProcessingTask` (see `BackgroundProcessingCoordinator`),
/// which means two things shape the design:
///
/// 1. **Progress is reported constantly and honestly.** The system prioritises
///    killing tasks that report minimal progress, so every stage pushes fractional
///    progress as it goes rather than once when it finishes (spec 4.7).
/// 2. **Every stage checkpoints before the next one starts.** A task killed in
///    summarising resumes in summarising, not at raw audio.
public actor ProcessingPipeline {

    public struct Input: Sendable {
        public var meetingID: UUID
        public var title: String
        public var date: Date
        public var locale: Locale
        public var chunks: [ChunkedAudioWriter.Chunk]
        /// Segments captured live during the recording. When these cover the meeting,
        /// the transcribing stage is already done and is skipped.
        public var liveSegments: [TranscriptSegment]
        public var duration: TimeInterval

        public init(
            meetingID: UUID,
            title: String,
            date: Date,
            locale: Locale,
            chunks: [ChunkedAudioWriter.Chunk],
            liveSegments: [TranscriptSegment],
            duration: TimeInterval
        ) {
            self.meetingID = meetingID
            self.title = title
            self.date = date
            self.locale = locale
            self.chunks = chunks
            self.liveSegments = liveSegments
            self.duration = duration
        }
    }

    public struct Output: Sendable {
        public var segments: [TranscriptSegment]
        public var embeddings: [String: [Float]]
        public var summary: MeetingSummary
        /// A redone transcript replaces hand-edited lines too; otherwise the edited
        /// old lines would sit alongside their re-transcribed versions.
        public var replacesEditedSegments: Bool = false
    }

    /// Fractional progress within a stage, 0...1.
    public typealias ProgressHandler = @Sendable (ProcessingStage, Double) -> Void
    /// Called as each stage starts, with when processing is expected to finish.
    public typealias EstimateHandler = @Sendable (ProcessingStage, Date) -> Void
    /// The labelled transcript, once speakers are done and before summarising.
    public typealias TranscriptHandler = @Sendable (_ segments: [TranscriptSegment], _ embeddings: [String: [Float]], _ replacesEditedSegments: Bool) async -> Void

    private let log = Logger(subsystem: "com.publicarray.fieldnotes", category: "pipeline")
    private let debug = DebugLog.shared
    private let transcriber: FileTranscriptionService
    private let diarizer: DiarizationService
    private let summariser: SummarizationService

    public init(
        locale: Locale = Locale(identifier: "en_AU"),
        // Shared, so loaded speaker models stay loaded from one meeting to the next.
        diarizer: DiarizationService = .shared,
        summariser: SummarizationService = SummarizationService()
    ) {
        self.transcriber = FileTranscriptionService(locale: locale)
        self.diarizer = diarizer
        self.summariser = summariser
    }

    /// - Parameter inBackgroundTask: true inside a `BGContinuedProcessingTask`. Apple's
    ///   on-device model rate-limits every request made from one (measured: even with
    ///   the app on screen), so summarising waits for an in-app run instead.
    public func run(
        _ input: Input,
        inBackgroundTask: Bool = false,
        progress: @escaping ProgressHandler = { _, _ in },
        estimate: @escaping EstimateHandler = { _, _ in },
        transcriptReady: @escaping TranscriptHandler = { _, _, _ in }
    ) async throws -> Output {
        let store = try ProcessingCheckpointStore(meetingID: input.meetingID)
        var checkpoint = await store.load()

        // What actually has work to do, for the time estimate.
        let hasLiveSpeakers = await store.loadLiveSpans() != nil
        let work = ProcessingEstimator.Work(
            transcribes: !checkpoint.isComplete(.transcribing)
                && (checkpoint.redoTranscript == true
                    || ParakeetTranscriber.isSelected(for: input.locale.identifier)
                    || !coversRecording(input.liveSegments, duration: input.duration)),
            diarizes: !checkpoint.isComplete(.diarizing) && !hasLiveSpeakers,
            summarises: !checkpoint.isComplete(.summarising)
        )
        var estimator = ProcessingEstimates.load()
        estimator.models = [
            .transcribing: NemotronStreamingTranscriber.isSelected(for: input.locale.identifier)
                ? TranscriptionEngine.nemotronStreaming.rawValue
                : (ParakeetTranscriber.selectedEngine(for: input.locale.identifier) ?? .apple).rawValue,
            .diarizing: {
                let method = DiarizationMethod(storedValue: UserDefaults.standard.string(forKey: DiarizationMethod.defaultsKey))
                return (method.isInstalled ? method : .nemotron3).rawValue
            }(),
            .summarising: SummaryEngine(storedValue: UserDefaults.standard.string(forKey: SummaryEngine.defaultsKey)).rawValue,
        ]
        let announce: (ProcessingStage) -> Void = { stage in
            let seconds = estimator.remaining(from: stage, audio: input.duration, work: work)
            estimate(stage, Date().addingTimeInterval(seconds))
        }
        let learn: (ProcessingStage, ContinuousClock.Instant) -> Void = { stage, start in
            guard work.includes(stage) else { return }
            let elapsed = start.duration(to: .now)
            estimator.record(
                stage,
                elapsed: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18,
                audio: input.duration
            )
            ProcessingEstimates.save(estimator)
        }
        let id = DebugLog.short(input.meetingID)
        if !checkpoint.completedStages.isEmpty {
            log.notice("Resuming meeting \(input.meetingID.uuidString, privacy: .public) after \(checkpoint.completedStages.count, privacy: .public) completed stages")
        }
        let done = checkpoint.completedStages.map(\.rawValue).sorted().joined(separator: ", ")
        debug.log("pipeline", "\(DebugLog.short(input.meetingID)): \(inBackgroundTask ? "background task" : "in app"), \(await PowerState.summary())")
        debug.log("pipeline", "\(id): start, \(String(format: "%.1f", input.duration))s of audio in \(input.chunks.count) chunk(s), \(input.liveSegments.count) live lines\(done.isEmpty ? "" : ", already done: \(done)")")
        let started = ContinuousClock.now

        var stageStart = ContinuousClock.now
        announce(.transcribing)
        let segments = try await transcribeStage(input, store: store, checkpoint: &checkpoint, progress: progress)
        debug.log("pipeline", "\(id): transcribing finished in \(DebugLog.elapsed(since: stageStart)), \(segments.count) lines")
        learn(.transcribing, stageStart)

        stageStart = .now
        announce(.diarizing)
        let diarization = try await diarizeStage(input, segments: segments, store: store, checkpoint: &checkpoint, progress: progress)
        let speakers = Set(diarization.segments.compactMap(\.speakerID)).count
        debug.log("pipeline", "\(id): identifying speakers finished in \(DebugLog.elapsed(since: stageStart)), \(speakers) speaker(s)")
        learn(.diarizing, stageStart)
        // Saved to the meeting now, so it can be read while the summary is written,
        // or if the user stops the summary.
        await transcriptReady(diarization.segments, diarization.embeddings, checkpoint.redoTranscript == true)

        stageStart = .now
        announce(.summarising)
        if inBackgroundTask, !checkpoint.isComplete(.summarising) {
            // Apple rate-limits its model for background work on battery, not on power.
            let onPower = await PowerState.isOnPower()
            if !(SummaryInBackground.isEnabled && onPower) {
                debug.log("pipeline", "\(id): transcript and speakers done; summarising waits for the app\(SummaryInBackground.isEnabled ? " or a charger" : "") (background on battery is rate-limited)")
                throw SummarizationService.Deferred(detail: "background task", withoutAttempt: true)
            }
            debug.log("pipeline", "\(id): on power, summarising in the background")
        }
        let summary = try await summariseStage(
            input,
            segments: diarization.segments,
            store: store,
            checkpoint: &checkpoint,
            progress: progress
        )
        debug.log("pipeline", "\(id): summarising finished in \(DebugLog.elapsed(since: stageStart)), \(summary.degradedChunks.count) degraded part(s)")
        learn(.summarising, stageStart)
        debug.log("pipeline", "\(id): done in \(DebugLog.elapsed(since: started))")

        return Output(
            segments: diarization.segments,
            embeddings: diarization.embeddings,
            summary: summary,
            replacesEditedSegments: checkpoint.redoTranscript == true
        )
    }

    // MARK: - Stage 1: transcribe

    private func transcribeStage(
        _ input: Input,
        store: ProcessingCheckpointStore,
        checkpoint: inout ProcessingCheckpoint,
        progress: @escaping ProgressHandler
    ) async throws -> [TranscriptSegment] {
        if checkpoint.isComplete(.transcribing), let saved = await store.loadSegments() {
            debug.log("pipeline", "\(DebugLog.short(input.meetingID)): transcribing already done, using checkpoint")
            progress(.transcribing, 1.0)
            return saved
        }
        progress(.transcribing, 0)
        let redo = checkpoint.redoTranscript == true

        // Parakeet, if the user chose it and has it: always redoes the transcript
        // after stop. Any failure falls back to Apple's transcript below.
        if let engine = ParakeetTranscriber.selectedEngine(for: input.locale.identifier) {
            do {
                let segments = try await ParakeetTranscriber.transcribe(
                    engine: engine,
                    meetingID: input.meetingID,
                    localeIdentifier: input.locale.identifier
                ) { fraction in
                    progress(.transcribing, fraction)
                }
                if !segments.isEmpty {
                    try await store.saveSegments(segments)
                    try await store.markComplete(.transcribing, in: &checkpoint)
                    progress(.transcribing, 1.0)
                    return segments
                }
                debug.log("pipeline", "\(DebugLog.short(input.meetingID)): Parakeet returned nothing; using Apple's transcript")
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                debug.log("pipeline", "\(DebugLog.short(input.meetingID)): Parakeet failed (\(error)); using Apple's transcript")
            }
        }

        // Nemotron 3.5 normally wrote the transcript live (reused just below). From
        // disk only when that's missing: an import, a redo, or a live run that failed.
        if NemotronStreamingTranscriber.isSelected(for: input.locale.identifier),
           redo || !coversRecording(input.liveSegments, duration: input.duration) {
            do {
                let segments = try await NemotronStreamingTranscriber.transcribe(
                    meetingID: input.meetingID,
                    localeIdentifier: input.locale.identifier
                ) { fraction in
                    progress(.transcribing, fraction)
                }
                if !segments.isEmpty {
                    try await store.saveSegments(segments)
                    try await store.markComplete(.transcribing, in: &checkpoint)
                    progress(.transcribing, 1.0)
                    return segments
                }
                debug.log("pipeline", "\(DebugLog.short(input.meetingID)): Nemotron returned nothing; using Apple's transcript")
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                debug.log("pipeline", "\(DebugLog.short(input.meetingID)): Nemotron failed (\(error)); using Apple's transcript")
            }
        }

        // The live transcript is the normal case: it was produced while the meeting
        // was happening and there is nothing to redo. The file path exists for the
        // abnormal one — app killed, transcription started late, audio imported.
        if !redo, coversRecording(input.liveSegments, duration: input.duration) {
            debug.log("pipeline", "\(DebugLog.short(input.meetingID)): live transcript covers the recording, reusing it")
            try await store.saveSegments(input.liveSegments)
            try await store.markComplete(.transcribing, in: &checkpoint)
            progress(.transcribing, 1.0)
            return input.liveSegments
        }

        log.notice("Live transcript incomplete; transcribing from disk")
        debug.log(
            "pipeline",
            "\(DebugLog.short(input.meetingID)): \(redo ? "redo requested" : "live transcript ends early"); transcribing \(input.chunks.count) audio chunk(s) from disk"
        )
        let resumeFrom = checkpoint.lastTranscribedChunkIndex.map { $0 + 1 } ?? 0
        var recovered = await store.loadSegments() ?? []

        let fresh = try await transcriber.transcribe(
            chunks: input.chunks,
            fromChunkIndex: resumeFrom
        ) { fraction, _ in
            progress(.transcribing, fraction)
        }

        recovered.append(contentsOf: fresh)
        recovered.sort { $0.start < $1.start }

        try await store.saveSegments(recovered)
        checkpoint.lastTranscribedChunkIndex = input.chunks.last?.index
        try await store.markComplete(.transcribing, in: &checkpoint)
        progress(.transcribing, 1.0)
        return recovered
    }

    /// Treats a live transcript as complete when it reaches near the end of the
    /// audio. A recording that was killed leaves a transcript that stops early.
    private func coversRecording(_ segments: [TranscriptSegment], duration: TimeInterval) -> Bool {
        guard let last = segments.last, duration > 0 else { return false }
        return last.end >= duration - 15
    }

    // MARK: - Stage 2: diarize

    private struct Diarization {
        var segments: [TranscriptSegment]
        var embeddings: [String: [Float]]
    }

    private func diarizeStage(
        _ input: Input,
        segments: [TranscriptSegment],
        store: ProcessingCheckpointStore,
        checkpoint: inout ProcessingCheckpoint,
        progress: @escaping ProgressHandler
    ) async throws -> Diarization {
        if checkpoint.isComplete(.diarizing),
           let spans = await store.loadSpans(),
           let saved = await store.loadSegments() {
            debug.log("pipeline", "\(DebugLog.short(input.meetingID)): speakers already done, using checkpoint")
            progress(.diarizing, 1.0)
            return Diarization(
                segments: WordSpeakerSplit.apply(spans: spans, to: saved),
                embeddings: await store.loadEmbeddings() ?? [:]
            )
        }

        progress(.diarizing, 0)

        if let live = await store.loadLiveSpans() {
            debug.log("pipeline", "\(DebugLog.short(input.meetingID)): using the \(live.count) speaker spans identified while recording")
            let labelled = WordSpeakerSplit.apply(spans: live, to: segments)
            try await store.saveSpans(live, embeddings: [:])
            try await store.saveSegments(labelled)
            try await store.markComplete(.diarizing, in: &checkpoint)
            progress(.diarizing, 1.0)
            return Diarization(segments: labelled, embeddings: [:])
        }

        let audio: AudioSamples
        do {
            audio = try AudioSamples(meetingID: input.meetingID)
        } catch {
            debug.log("pipeline", "\(DebugLog.short(input.meetingID)): could not read the speaker audio buffer: \(error)")
            throw error
        }
        // Read at run time rather than captured at init: the pipeline runs off the main
        // actor inside a background task, long after Settings last changed.
        var method = DiarizationMethod(
            storedValue: UserDefaults.standard.string(forKey: DiarizationMethod.defaultsKey)
        )
        if !method.isInstalled {
            // A pyannote method chosen but not downloaded (or deleted): Nemotron is
            // always bundled, so use it rather than fail the meeting.
            debug.log("pipeline", "\(DebugLog.short(input.meetingID)): \(method.rawValue) isn't downloaded; using nemotron3")
            method = .nemotron3
        }
        let output = try await diarizer.diarize(audio: audio, method: method) { fraction in
            progress(.diarizing, fraction)
        }

        let labelled = WordSpeakerSplit.apply(spans: output.spans, to: segments)
        try await store.saveSpans(output.spans, embeddings: output.embeddings)
        try await store.saveSegments(labelled)
        try await store.markComplete(.diarizing, in: &checkpoint)
        progress(.diarizing, 1.0)
        return Diarization(segments: labelled, embeddings: output.embeddings)
    }

    // MARK: - Stage 3: summarise

    private func summariseStage(
        _ input: Input,
        segments: [TranscriptSegment],
        store: ProcessingCheckpointStore,
        checkpoint: inout ProcessingCheckpoint,
        progress: @escaping ProgressHandler
    ) async throws -> MeetingSummary {
        if checkpoint.isComplete(.summarising), let saved = await store.loadSummary() {
            debug.log("pipeline", "\(DebugLog.short(input.meetingID)): summary already done, using checkpoint")
            progress(.summarising, 1.0)
            return saved
        }
        // Reported now, not after the first model call: otherwise the meeting keeps
        // showing the previous stage for the whole first generation.
        progress(.summarising, 0)

        let context = SummarizationService.MeetingContext(
            id: input.meetingID,
            title: input.title,
            date: input.date
        )
        let deferrals = checkpoint.summaryDeferrals ?? 0
        let inFront = await PowerState.isAppInFront()
        let summary: MeetingSummary
        do {
            // After a few waits, accept thinner notes rather than waiting forever.
            let saved = await store.loadSummaryParts()
            summary = try await summariser.summarise(
                segments: segments,
                meeting: context,
                // One automatic retry; after that it's the user's Try again. A run
                // with the app out of view always waits instead: the model refuses
                // it there, which says nothing about the meeting.
                allowDeferral: deferrals < 1 || !inFront,
                savedParts: saved,
                savePart: { key, notes in try? await store.saveSummaryPart(notes, key: key) }
            ) { fraction in
                progress(.summarising, fraction)
            }
        } catch let notWritten as SummarizationService.NotWritten {
            debug.log("pipeline", "\(DebugLog.short(input.meetingID)): notes not written after the automatic retry (\(await PowerState.summary())): \(notWritten.detail.prefix(160))")
            throw notWritten
        } catch let deferred as SummarizationService.Deferred {
            if await PowerState.isAppInFront() {
                checkpoint.summaryDeferrals = deferrals + 1
            }
            try await store.save(checkpoint)
            debug.log("pipeline", "\(DebugLog.short(input.meetingID)): summarising put off, will retry once when the app is open (\(await PowerState.summary())): \(deferred.detail.prefix(160))")
            throw deferred
        }

        try await store.saveSummary(summary)
        try await store.markComplete(.summarising, in: &checkpoint)
        progress(.summarising, 1.0)
        return summary
    }
}

/// The learned processing speeds for this phone, kept in UserDefaults.
enum ProcessingEstimates {
    // v2: rates per model. The old per-stage rates mixed models, so start over.
    private static let key = "processingEstimator.v2"

    static func load() -> ProcessingEstimator {
        guard let data = UserDefaults.standard.data(forKey: key),
              let stored = try? JSONDecoder().decode(ProcessingEstimator.self, from: data) else {
            return ProcessingEstimator()
        }
        return stored
    }

    static func save(_ estimator: ProcessingEstimator) {
        guard let data = try? JSONEncoder().encode(estimator) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

extension DiarizationMethod {
    /// Nemotron ships in the app; the pyannote methods are optional downloads.
    public var modelPack: ModelPack.ID? {
        switch self {
        case .nemotron3: nil
        case .pyannoteCommunity1: .pyannoteCommunity1
        }
    }

    public var isInstalled: Bool {
        modelPack.map { ModelDownloads.installedDirectory(for: $0) != nil } ?? true
    }
}

/// "Finish notes while charging" (Settings): lets summaries run in the background,
/// where Apple's model is only rate-limited on battery. Off by default.
public enum SummaryInBackground {
    public static let defaultsKey = "summariseWhileCharging"
    public static var isEnabled: Bool { UserDefaults.standard.bool(forKey: defaultsKey) }
}

#if os(iOS)
import UIKit

public enum PowerState {
    /// Plugged in (charging or full).
    @MainActor
    public static func isOnPowerNow() -> Bool {
        UIDevice.current.isBatteryMonitoringEnabled = true
        let state = UIDevice.current.batteryState
        return state == .charging || state == .full
    }

    public static func isOnPower() async -> Bool {
        await MainActor.run { isOnPowerNow() }
    }

    public static func isAppInFront() async -> Bool {
        await MainActor.run { UIApplication.shared.applicationState == .active }
    }

    /// "battery 64%, Low Power Mode on, app in front": for the Activity log.
    public static func summary() async -> String {
        await MainActor.run {
            UIDevice.current.isBatteryMonitoringEnabled = true
            let level = UIDevice.current.batteryLevel
            let percent = level >= 0 ? " \(Int((level * 100).rounded()))%" : ""
            let power: String = switch UIDevice.current.batteryState {
            case .charging: "charging\(percent)"
            case .full: "plugged in, full"
            case .unplugged: "on battery\(percent)"
            default: "power unknown"
            }
            let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled ? ", Low Power Mode on" : ""
            let app: String = switch UIApplication.shared.applicationState {
            case .active: "app in front"
            case .inactive: "app inactive"
            default: "app in background"
            }
            return "\(power)\(lowPower), \(app)"
        }
    }
}
#else
public enum PowerState {
    public static func isOnPower() async -> Bool { true }
    public static func isAppInFront() async -> Bool { true }
    public static func summary() async -> String { "power unknown" }
}
#endif

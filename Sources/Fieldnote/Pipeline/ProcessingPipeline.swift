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

    public func run(
        _ input: Input,
        progress: @escaping ProgressHandler = { _, _ in },
        estimate: @escaping EstimateHandler = { _, _ in }
    ) async throws -> Output {
        let store = try ProcessingCheckpointStore(meetingID: input.meetingID)
        var checkpoint = await store.load()

        // What actually has work to do, for the time estimate.
        let hasLiveSpeakers = await store.loadLiveSpans() != nil
        let work = ProcessingEstimator.Work(
            transcribes: !checkpoint.isComplete(.transcribing)
                && (checkpoint.redoTranscript == true || !coversRecording(input.liveSegments, duration: input.duration)),
            diarizes: !checkpoint.isComplete(.diarizing) && !hasLiveSpeakers,
            summarises: !checkpoint.isComplete(.summarising)
        )
        var estimator = ProcessingEstimates.load()
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

        stageStart = .now
        announce(.summarising)
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

        let buffer = try DiarizationBuffer(meetingID: input.meetingID)
        let samples: [Float]
        do {
            samples = try await buffer.samples()
        } catch {
            debug.log("pipeline", "\(DebugLog.short(input.meetingID)): could not read the speaker audio buffer: \(error)")
            throw error
        }
        // Read at run time rather than captured at init: the pipeline runs off the main
        // actor inside a background task, long after Settings last changed.
        let method = DiarizationMethod(
            storedValue: UserDefaults.standard.string(forKey: DiarizationMethod.defaultsKey)
        )
        let output = try await diarizer.diarize(samples: samples, method: method) { fraction in
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
        let summary = try await summariser.summarise(segments: segments, meeting: context) { fraction in
            progress(.summarising, fraction)
        }

        try await store.saveSummary(summary)
        try await store.markComplete(.summarising, in: &checkpoint)
        progress(.summarising, 1.0)
        return summary
    }
}

/// The learned processing speeds for this phone, kept in UserDefaults.
enum ProcessingEstimates {
    private static let key = "processingEstimator"

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

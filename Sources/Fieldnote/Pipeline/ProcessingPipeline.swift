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
        public var type: MeetingType
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
            type: MeetingType,
            date: Date,
            locale: Locale,
            chunks: [ChunkedAudioWriter.Chunk],
            liveSegments: [TranscriptSegment],
            duration: TimeInterval
        ) {
            self.meetingID = meetingID
            self.title = title
            self.type = type
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
    }

    /// Fractional progress within a stage, 0...1.
    public typealias ProgressHandler = @Sendable (ProcessingStage, Double) -> Void

    private let log = Logger(subsystem: "com.publicarray.fieldnotes", category: "pipeline")
    private let transcriber: FileTranscriptionService
    private let diarizer: DiarizationService
    private let summariser: SummarizationService

    public init(
        locale: Locale = Locale(identifier: "en_AU"),
        diarizer: DiarizationService = DiarizationService(),
        summariser: SummarizationService = SummarizationService()
    ) {
        self.transcriber = FileTranscriptionService(locale: locale)
        self.diarizer = diarizer
        self.summariser = summariser
    }

    public func run(_ input: Input, progress: @escaping ProgressHandler = { _, _ in }) async throws -> Output {
        let store = try ProcessingCheckpointStore(meetingID: input.meetingID)
        var checkpoint = await store.load()
        if !checkpoint.completedStages.isEmpty {
            log.notice("Resuming meeting \(input.meetingID.uuidString, privacy: .public) after \(checkpoint.completedStages.count, privacy: .public) completed stages")
        }

        let segments = try await transcribeStage(input, store: store, checkpoint: &checkpoint, progress: progress)
        let diarization = try await diarizeStage(input, segments: segments, store: store, checkpoint: &checkpoint, progress: progress)
        let summary = try await summariseStage(
            input,
            segments: diarization.segments,
            store: store,
            checkpoint: &checkpoint,
            progress: progress
        )

        return Output(segments: diarization.segments, embeddings: diarization.embeddings, summary: summary)
    }

    // MARK: - Stage 1: transcribe

    private func transcribeStage(
        _ input: Input,
        store: ProcessingCheckpointStore,
        checkpoint: inout ProcessingCheckpoint,
        progress: @escaping ProgressHandler
    ) async throws -> [TranscriptSegment] {
        if checkpoint.isComplete(.transcribing), let saved = await store.loadSegments() {
            progress(.transcribing, 1.0)
            return saved
        }

        // The live transcript is the normal case: it was produced while the meeting
        // was happening and there is nothing to redo. The file path exists for the
        // abnormal one — app killed, transcription started late, audio imported.
        if coversRecording(input.liveSegments, duration: input.duration) {
            try await store.saveSegments(input.liveSegments)
            try await store.markComplete(.transcribing, in: &checkpoint)
            progress(.transcribing, 1.0)
            return input.liveSegments
        }

        log.notice("Live transcript incomplete; transcribing from disk")
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
            progress(.diarizing, 1.0)
            return Diarization(
                segments: SpeakerAlignment.apply(spans: spans, to: saved),
                embeddings: await store.loadEmbeddings() ?? [:]
            )
        }

        let buffer = try DiarizationBuffer(meetingID: input.meetingID)
        let samples = try await buffer.samples()
        let output = try await diarizer.diarize(samples: samples) { fraction in
            progress(.diarizing, fraction)
        }

        let labelled = SpeakerAlignment.apply(spans: output.spans, to: segments)
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
            progress(.summarising, 1.0)
            return saved
        }

        let context = SummarizationService.MeetingContext(
            id: input.meetingID,
            title: input.title,
            type: input.type,
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

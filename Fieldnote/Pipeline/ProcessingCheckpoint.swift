import Foundation

/// What a killed pipeline run needs to know to pick up where it stopped.
///
/// The system terminates continued-processing tasks under memory pressure, and long
/// tasks expire unpredictably in production even when they behave in testing
/// (spec 4.7). So every stage writes its output to disk and stamps the checkpoint
/// before the next stage starts. A resumed run never re-does a completed stage, and
/// never restarts from raw audio.
public struct ProcessingCheckpoint: Codable, Sendable {
    public var meetingID: UUID
    public var completedStages: Set<ProcessingStage>
    /// Highest chunk index already transcribed. Lets the transcribing stage itself
    /// resume part-way, which matters most: it is the longest stage.
    public var lastTranscribedChunkIndex: Int?
    public var updatedAt: Date
    public var failureCount: Int

    public init(meetingID: UUID) {
        self.meetingID = meetingID
        self.completedStages = []
        self.lastTranscribedChunkIndex = nil
        self.updatedAt = Date()
        self.failureCount = 0
    }

    public func isComplete(_ stage: ProcessingStage) -> Bool {
        completedStages.contains(stage)
    }

    public var nextStage: ProcessingStage? {
        ProcessingStage.allCases.first { !completedStages.contains($0) }
    }
}

/// Reads and writes checkpoints and the per-stage artefacts beside them.
public actor ProcessingCheckpointStore {

    private let meetingID: UUID
    private let directory: URL
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    public init(meetingID: UUID) throws {
        self.meetingID = meetingID
        self.directory = FieldnoteStorage.checkpointDirectory(for: meetingID)
        try FieldnoteStorage.ensureDirectory(directory)
    }

    // MARK: - Checkpoint

    public func load() -> ProcessingCheckpoint {
        let url = directory.appendingPathComponent("checkpoint.json")
        guard let data = try? Data(contentsOf: url),
              let checkpoint = try? decoder.decode(ProcessingCheckpoint.self, from: data) else {
            return ProcessingCheckpoint(meetingID: meetingID)
        }
        return checkpoint
    }

    public func save(_ checkpoint: ProcessingCheckpoint) throws {
        var stamped = checkpoint
        stamped.updatedAt = Date()
        try write(stamped, to: "checkpoint.json")
    }

    public func markComplete(_ stage: ProcessingStage, in checkpoint: inout ProcessingCheckpoint) throws {
        checkpoint.completedStages.insert(stage)
        try save(checkpoint)
    }

    // MARK: - Artefacts

    public func saveSegments(_ segments: [TranscriptSegment]) throws {
        try write(segments, to: "segments.json")
    }

    public func loadSegments() -> [TranscriptSegment]? {
        read([TranscriptSegment].self, from: "segments.json")
    }

    public func saveSpans(_ spans: [DiarizedSpan], embeddings: [String: [Float]]) throws {
        try write(spans, to: "spans.json")
        try write(embeddings, to: "embeddings.json")
    }

    public func loadSpans() -> [DiarizedSpan]? {
        read([DiarizedSpan].self, from: "spans.json")
    }

    public func loadEmbeddings() -> [String: [Float]]? {
        read([String: [Float]].self, from: "embeddings.json")
    }

    public func saveSummary(_ summary: MeetingSummary) throws {
        try write(summary, to: "summary.json")
    }

    public func loadSummary() -> MeetingSummary? {
        read(MeetingSummary.self, from: "summary.json")
    }

    /// Called once the meeting is persisted. Keeps the on-disk footprint honest.
    public func clear() {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Plumbing

    private func write<T: Encodable>(_ value: T, to name: String) throws {
        let url = directory.appendingPathComponent(name)
        let data = try encoder.encode(value)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
    }

    private func read<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        let url = directory.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(type, from: data)
    }
}

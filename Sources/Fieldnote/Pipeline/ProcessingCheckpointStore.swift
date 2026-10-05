import FieldnoteKit
import Foundation

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

    /// Speakers identified while recording. Used instead of the batch pass when
    /// present; cleared with the rest of the checkpoint, so a redo starts fresh.
    public func saveLiveSpans(_ spans: [DiarizedSpan]) throws {
        try write(spans, to: "live-spans.json")
    }

    public func loadLiveSpans() -> [DiarizedSpan]? {
        read([DiarizedSpan].self, from: "live-spans.json")
    }

    public func saveSummary(_ summary: MeetingSummary) throws {
        try write(summary, to: "summary.json")
    }

    public func loadSummary() -> MeetingSummary? {
        read(MeetingSummary.self, from: "summary.json")
    }

    /// Summary parts already written, by `TranscriptChunk.partKey`, so a run that was
    /// stopped or killed continues from the next part instead of starting over.
    public func loadSummaryParts() -> [String: ChunkNotes] {
        read([String: ChunkNotes].self, from: "summary-parts.json") ?? [:]
    }

    public func saveSummaryPart(_ notes: ChunkNotes, key: String) throws {
        var parts = loadSummaryParts()
        parts[key] = notes
        try write(parts, to: "summary-parts.json")
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

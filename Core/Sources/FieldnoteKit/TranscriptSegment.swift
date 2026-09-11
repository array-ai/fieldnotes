import Foundation

/// One finalized line of transcript. The unit everything else cites.
public struct TranscriptSegment: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var start: TimeInterval
    public var end: TimeInterval
    public var text: String
    /// Per-meeting label ("S1", "S2"). Not a person. v1 has no cross-meeting identity
    /// (spec 4.4); v2 turns these into a registry (spec 11.3).
    public var speakerID: String?
    public var confidence: Double
    public var isFinalized: Bool
    public var editedByUser: Bool

    public init(
        id: UUID = UUID(),
        start: TimeInterval,
        end: TimeInterval,
        text: String,
        speakerID: String? = nil,
        confidence: Double = 1.0,
        isFinalized: Bool = true,
        editedByUser: Bool = false
    ) {
        self.id = id
        self.start = start
        self.end = end
        self.text = text
        self.speakerID = speakerID
        self.confidence = confidence
        self.isFinalized = isFinalized
        self.editedByUser = editedByUser
    }

    public var duration: TimeInterval { max(0, end - start) }
}

/// One diarized span: this speaker held the floor from `start` to `end`.
public struct DiarizedSpan: Codable, Hashable, Sendable {
    public var start: TimeInterval
    public var end: TimeInterval
    public var speakerID: String
    public var confidence: Double

    public init(start: TimeInterval, end: TimeInterval, speakerID: String, confidence: Double = 1.0) {
        self.start = start
        self.end = end
        self.speakerID = speakerID
        self.confidence = confidence
    }

    public var duration: TimeInterval { max(0, end - start) }
}

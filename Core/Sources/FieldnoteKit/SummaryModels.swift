import Foundation

/// The v1 summary. Every decision and action item carries a resolved source segment,
/// or it does not survive grounding.
public struct MeetingSummary: Codable, Hashable, Sendable {
    public var overview: String
    public var decisions: [Decision]
    public var actionItems: [ActionItem]
    public var openQuestions: [OpenQuestion]
    /// Free-form in v1. There is no term list to match against until v2 (spec 11.1),
    /// so these are stored exactly as transcribed, mangled spellings and all.
    public var mentionedSystems: [String]
    /// Chunks whose summarisation tripped a guardrail and fell back to a shorter
    /// neutral prompt, or failed outright. Surfaced in the UI; never silently dropped.
    public var degradedChunks: [DegradedChunk]

    public init(
        overview: String = "",
        decisions: [Decision] = [],
        actionItems: [ActionItem] = [],
        openQuestions: [OpenQuestion] = [],
        mentionedSystems: [String] = [],
        degradedChunks: [DegradedChunk] = []
    ) {
        self.overview = overview
        self.decisions = decisions
        self.actionItems = actionItems
        self.openQuestions = openQuestions
        self.mentionedSystems = mentionedSystems
        self.degradedChunks = degradedChunks
    }
}

public struct Decision: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var statement: String
    public var sourceSegmentID: UUID
    public var supportingSegmentIDs: [UUID]

    public init(id: UUID = UUID(), statement: String, sourceSegmentID: UUID, supportingSegmentIDs: [UUID] = []) {
        self.id = id
        self.statement = statement
        self.sourceSegmentID = sourceSegmentID
        self.supportingSegmentIDs = supportingSegmentIDs
    }
}

public struct ActionItem: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var task: String
    /// Free text in v1. There is no person registry to resolve against until v2
    /// (spec 11.3), so this is whatever the transcript called them.
    public var owner: String?
    /// The due date as spoken, kept verbatim so the user can see what was said.
    public var dueDate: String?
    /// The spoken date resolved against the meeting's own date, not generation time.
    public var resolvedDueDate: Date?
    public var sourceSegmentID: UUID
    public var supportingSegmentIDs: [UUID]

    public init(
        id: UUID = UUID(),
        task: String,
        owner: String? = nil,
        dueDate: String? = nil,
        resolvedDueDate: Date? = nil,
        sourceSegmentID: UUID,
        supportingSegmentIDs: [UUID] = []
    ) {
        self.id = id
        self.task = task
        self.owner = owner
        self.dueDate = dueDate
        self.resolvedDueDate = resolvedDueDate
        self.sourceSegmentID = sourceSegmentID
        self.supportingSegmentIDs = supportingSegmentIDs
    }
}

public struct OpenQuestion: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var text: String
    public var sourceSegmentID: UUID

    public init(id: UUID = UUID(), text: String, sourceSegmentID: UUID) {
        self.id = id
        self.text = text
        self.sourceSegmentID = sourceSegmentID
    }
}

public struct DegradedChunk: Codable, Hashable, Sendable {
    public enum Reason: String, Codable, Sendable {
        case guardrail
        case contextOverflow
        case modelError
    }

    public var chunkIndex: Int
    public var reason: Reason
    /// Did the shorter neutral prompt produce anything usable?
    public var recovered: Bool
    public var startTime: TimeInterval
    public var endTime: TimeInterval

    public init(chunkIndex: Int, reason: Reason, recovered: Bool, startTime: TimeInterval, endTime: TimeInterval) {
        self.chunkIndex = chunkIndex
        self.reason = reason
        self.recovered = recovered
        self.startTime = startTime
        self.endTime = endTime
    }
}

import Foundation

/// The v1 summary. Every decision and action item carries a resolved source segment,
/// or it does not survive grounding.
public struct MeetingSummary: Codable, Hashable, Sendable {
    public var overview: String
    /// The notes, by topic, each point cited and timestamped. Nil for summaries
    /// made before topics existed (optional, so those still decode).
    public var topics: [SummaryTopic]?
    public var decisions: [Decision]
    public var actionItems: [ActionItem]
    public var openQuestions: [OpenQuestion]
    /// Free-form in v1. There is no term list to match against until v2 (spec 11.1),
    /// so these are stored exactly as transcribed, mangled spellings and all.
    public var mentionedSystems: [String]
    /// Chunks whose summarisation tripped a guardrail and fell back to a shorter
    /// neutral prompt, or failed outright. Surfaced in the UI; never silently dropped.
    public var degradedChunks: [DegradedChunk]
    /// Speaker label ("S1") to a name grounded in something actually said -- a
    /// self-introduction or another speaker addressing them by name. Applied where a
    /// meeting has no existing name for that label already (manual renames always win;
    /// see `MeetingStore.apply`).
    public var speakerNames: [String: String]

    public init(
        overview: String = "",
        topics: [SummaryTopic]? = nil,
        decisions: [Decision] = [],
        actionItems: [ActionItem] = [],
        openQuestions: [OpenQuestion] = [],
        mentionedSystems: [String] = [],
        degradedChunks: [DegradedChunk] = [],
        speakerNames: [String: String] = [:]
    ) {
        self.overview = overview
        self.topics = topics
        self.decisions = decisions
        self.actionItems = actionItems
        self.openQuestions = openQuestions
        self.mentionedSystems = mentionedSystems
        self.degradedChunks = degradedChunks
        self.speakerNames = speakerNames
    }
}

public struct SummaryTopic: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var title: String
    /// One sentence on what the section covered and where it landed.
    public var summary: String
    public var points: [TopicPoint]
    /// A single emoji for the meeting list's highlights. Decoration only.
    public var emoji: String?

    public init(id: UUID = UUID(), title: String, summary: String, points: [TopicPoint], emoji: String? = nil) {
        self.id = id
        self.title = title
        self.summary = summary
        self.points = points
        self.emoji = emoji
    }
}

public struct TopicPoint: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var text: String
    public var details: [String]
    public var sourceSegmentID: UUID

    public init(id: UUID = UUID(), text: String, details: [String] = [], sourceSegmentID: UUID) {
        self.id = id
        self.text = text
        self.details = details
        self.sourceSegmentID = sourceSegmentID
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
    /// Raw values are persisted in stored summaries: add cases, never rename them.
    public enum Reason: String, Codable, Sendable {
        case guardrail
        case contextOverflow
        case modelError
        case refusal
        case rateLimited
        case timeout
    }

    public var chunkIndex: Int
    public var reason: Reason
    /// Did the shorter neutral prompt produce anything usable?
    public var recovered: Bool
    public var startTime: TimeInterval
    public var endTime: TimeInterval
    /// The model's own error text, for the debug log and debug view. Optional so
    /// summaries stored before it existed still decode.
    public var detail: String?

    public init(
        chunkIndex: Int,
        reason: Reason,
        recovered: Bool,
        startTime: TimeInterval,
        endTime: TimeInterval,
        detail: String? = nil
    ) {
        self.chunkIndex = chunkIndex
        self.reason = reason
        self.recovered = recovered
        self.startTime = startTime
        self.endTime = endTime
        self.detail = detail
    }

    /// Completes "This part of the meeting …" in the summary's Coverage section.
    public var explanation: String {
        let why: String = switch reason {
        case .guardrail: "tripped the model's safety filter"
        case .refusal: "was refused by the model"
        case .contextOverflow: "was too long for the model"
        case .rateLimited: "hit the model's rate limit"
        case .timeout: "timed out"
        case .modelError: "failed in the model"
        }
        return recovered ? "\(why); summarised with a shorter prompt" : "\(why); not summarised"
    }
}

import Foundation
import FoundationModels

// MARK: - What the model is asked to produce
//
// The model never emits UUIDs. Asking a 3B–20B model to copy a UUID accurately is
// asking it to hallucinate one, and an unresolvable citation is worse than no
// citation because it looks like grounding. So the prompt numbers the transcript
// lines it is given, the model cites those numbers, and `SummaryGrounder` maps the
// numbers back to real segment IDs — discarding any claim whose citation does not
// resolve (spec 4.5: no unsourced claims in output).

@Generable
struct DraftChunkNotes {
    @Guide(description: "Key points discussed in this excerpt, in the order they came up. Plain sentences, no bullets.")
    var points: [String]

    @Guide(description: "Decisions the participants actually settled in this excerpt. Omit anything still open.")
    var decisions: [DraftDecision]

    @Guide(description: "Tasks someone committed to. Omit vague intentions.")
    var actionItems: [DraftActionItem]

    @Guide(description: "Questions raised in this excerpt that nobody answered.")
    var openQuestions: [DraftClaim]

    @Guide(description: "Product, vendor, system and site names mentioned. Copy them exactly as transcribed, even if they look misspelt.")
    var mentionedSystems: [String]
}

@Generable
struct DraftDecision {
    @Guide(description: "The decision, stated in one sentence.")
    var statement: String

    @Guide(description: "Line numbers from the excerpt that show this decision being made. At least one.")
    var sourceLines: [Int]
}

@Generable
struct DraftActionItem {
    @Guide(description: "The task, stated as an imperative. One sentence.")
    var task: String

    @Guide(description: "Who committed to it, exactly as named or labelled in the transcript. Empty if nobody was named.")
    var owner: String

    @Guide(description: "The due date exactly as spoken, for example 'next Tuesday' or 'end of month'. Empty if none was given.")
    var dueDate: String

    @Guide(description: "Line numbers from the excerpt that show this commitment. At least one.")
    var sourceLines: [Int]
}

@Generable
struct DraftClaim {
    @Guide(description: "The point, in one sentence.")
    var text: String

    @Guide(description: "Line numbers from the excerpt that support it. At least one.")
    var sourceLines: [Int]
}

/// The roll-up pass. Runs over the chunk notes, not over the raw transcript.
@Generable
struct DraftRollup {
    @Guide(description: "A 3-6 sentence overview of the whole meeting. No preamble, no 'in this meeting'.")
    var overview: String
}

// MARK: - What gets persisted

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

import Foundation

// What the summariser hands to `SummaryGrounder`.
//
// These are plain values, not the framework's `@Generable` types. The split is
// deliberate: the generated types are the model's wire format and only exist where
// FoundationModels does, while grounding — the step that decides which claims are
// trustworthy enough to keep — is the part most worth testing, and testing it should
// not require a device or an Apple SDK.
//
// The app converts its drafts into these (see `DraftTypes.swift`).

/// Notes from one chunk of transcript, with citations as line numbers.
///
/// The model never emits UUIDs. Asking a 3B-20B model to copy one accurately is
/// asking it to invent one, and an unresolvable citation is worse than no citation
/// because it looks like grounding. So the prompt numbers the lines, the model cites
/// numbers, and the grounder maps them back.
public struct ChunkNotes: Sendable, Hashable {
    public var points: [String]
    public var decisions: [NoteDecision]
    public var actionItems: [NoteActionItem]
    public var openQuestions: [NoteClaim]
    public var mentionedSystems: [String]

    public init(
        points: [String] = [],
        decisions: [NoteDecision] = [],
        actionItems: [NoteActionItem] = [],
        openQuestions: [NoteClaim] = [],
        mentionedSystems: [String] = []
    ) {
        self.points = points
        self.decisions = decisions
        self.actionItems = actionItems
        self.openQuestions = openQuestions
        self.mentionedSystems = mentionedSystems
    }
}

public struct NoteDecision: Sendable, Hashable {
    public var statement: String
    public var sourceLines: [Int]

    public init(statement: String, sourceLines: [Int]) {
        self.statement = statement
        self.sourceLines = sourceLines
    }
}

public struct NoteActionItem: Sendable, Hashable {
    public var task: String
    public var owner: String
    public var dueDate: String
    public var sourceLines: [Int]

    public init(task: String, owner: String = "", dueDate: String = "", sourceLines: [Int]) {
        self.task = task
        self.owner = owner
        self.dueDate = dueDate
        self.sourceLines = sourceLines
    }
}

public struct NoteClaim: Sendable, Hashable {
    public var text: String
    public var sourceLines: [Int]

    public init(text: String, sourceLines: [Int]) {
        self.text = text
        self.sourceLines = sourceLines
    }
}

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
public struct ChunkNotes: Codable, Sendable, Hashable {
    /// What was discussed, grouped into topics with cited key points.
    public var topics: [NoteTopic]
    public var points: [String]
    public var decisions: [NoteDecision]
    public var actionItems: [NoteActionItem]
    public var openQuestions: [NoteClaim]
    public var mentionedSystems: [String]
    /// A name claimed for a speaker, cited the same way as everything else: `text` is
    /// the name, `sourceLines` is where it was said or where someone was addressed by
    /// it. Grounding resolves the citation to a real segment and takes that segment's
    /// *actual* speaker label as ground truth — never whatever label the model itself
    /// might restate — so a hallucinated pairing has nothing to attach to.
    public var speakerNames: [NoteClaim]

    public init(
        topics: [NoteTopic] = [],
        points: [String] = [],
        decisions: [NoteDecision] = [],
        actionItems: [NoteActionItem] = [],
        openQuestions: [NoteClaim] = [],
        mentionedSystems: [String] = [],
        speakerNames: [NoteClaim] = []
    ) {
        self.topics = topics
        self.points = points
        self.decisions = decisions
        self.actionItems = actionItems
        self.openQuestions = openQuestions
        self.mentionedSystems = mentionedSystems
        self.speakerNames = speakerNames
    }

    /// Joins the notes from pieces of one chunk that had to be split to fit the
    /// model's context. Citations are global line numbers, so they still resolve
    /// against the original chunk; duplicates are dropped later by the grounder.
    public func merged(with other: ChunkNotes) -> ChunkNotes {
        ChunkNotes(
            topics: topics + other.topics,
            points: points + other.points,
            decisions: decisions + other.decisions,
            actionItems: actionItems + other.actionItems,
            openQuestions: openQuestions + other.openQuestions,
            mentionedSystems: mentionedSystems + other.mentionedSystems,
            speakerNames: speakerNames + other.speakerNames
        )
    }
}

/// One topic as the model saw it in one excerpt.
public struct NoteTopic: Codable, Sendable, Hashable {
    public var title: String
    public var summary: String
    public var points: [NotePoint]

    public init(title: String, summary: String = "", points: [NotePoint] = []) {
        self.title = title
        self.summary = summary
        self.points = points
    }
}

/// A key point under a topic, with short supporting details. The point carries the
/// citation; the details are elaboration of the same cited lines.
public struct NotePoint: Codable, Sendable, Hashable {
    public var text: String
    public var details: [String]
    public var sourceLines: [Int]

    public init(text: String, details: [String] = [], sourceLines: [Int]) {
        self.text = text
        self.details = details
        self.sourceLines = sourceLines
    }
}

public struct NoteDecision: Codable, Sendable, Hashable {
    public var statement: String
    public var sourceLines: [Int]

    public init(statement: String, sourceLines: [Int]) {
        self.statement = statement
        self.sourceLines = sourceLines
    }
}

public struct NoteActionItem: Codable, Sendable, Hashable {
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

public struct NoteClaim: Codable, Sendable, Hashable {
    public var text: String
    public var sourceLines: [Int]

    public init(text: String, sourceLines: [Int]) {
        self.text = text
        self.sourceLines = sourceLines
    }
}

extension TranscriptChunk {
    /// Identifies a chunk's exact lines, so a saved summary part is only reused for
    /// the same excerpt (budgets can change between runs, and with them chunk bounds).
    public var partKey: String {
        "\(lineNumbers.first ?? 0)-\(lineNumbers.last ?? 0)-\(segments.count)"
    }
}

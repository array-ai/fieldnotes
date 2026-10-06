import FieldnoteKit
import Foundation
import FoundationModels

// What the model is asked to produce.
//
// These mirror `ChunkNotes` in FieldnoteKit. The mirroring is the price of keeping
// grounding testable without an Apple SDK, and it is cheap: the generated types are
// a wire format, and converting them is a dozen lines at the bottom of this file.

@Generable
struct DraftChunkNotes {
    @Guide(description: "One to three topics discussed, in order.")
    var topics: [DraftTopic]

    @Guide(description: "Things the group decided or agreed to do. Not opinions, reactions or questions. Empty if none.")
    var decisions: [DraftDecision]

    @Guide(description: "Tasks someone agreed to do, each starting with a verb. Empty if none.")
    var actionItems: [DraftActionItem]

    @Guide(description: "Questions someone asked that were not answered, in your own words. Empty if none.")
    var openQuestions: [DraftClaim]

    @Guide(description: "A speaker's own name when they introduce themselves (\"I'm X\"). Cite that line. Empty if none.")
    var speakerNames: [DraftClaim]
}

@Generable
struct DraftTopic {
    @Guide(description: "Three to seven word headline stating the point.")
    var title: String

    @Guide(description: "One sentence on what was said about it, in your own words.")
    var summary: String

    @Guide(description: "Two to five key points.")
    var points: [DraftPoint]
}

@Generable
struct DraftPoint {
    @Guide(description: "One sentence in your own words. Never a quote from the transcript.")
    var text: String

    // No "details": Apple's model filled them with words copied from the point
    // (a few words repeated from the point itself) and they cost output tokens.
    @Guide(description: "One to three line numbers.", .maximumCount(3))
    var sourceLines: [Int]
}

@Generable
struct DraftDecision {
    @Guide(description: "One sentence.")
    var statement: String

    @Guide(description: "One to three line numbers.", .maximumCount(3))
    var sourceLines: [Int]
}

@Generable
struct DraftActionItem {
    @Guide(description: "Imperative sentence.")
    var task: String

    @Guide(description: "Who, as named. Empty if none or unclear.")
    var owner: String

    @Guide(description: "When, as said. Empty if none.")
    var dueDate: String

    @Guide(description: "One to three line numbers.", .maximumCount(3))
    var sourceLines: [Int]
}

@Generable
struct DraftClaim {
    @Guide(description: "One sentence.")
    var text: String

    @Guide(description: "One to three line numbers.", .maximumCount(3))
    var sourceLines: [Int]
}

/// The final pass: the meeting's overview, and which excerpt topics belong together
/// as one section. Sees only topic titles and summaries, never transcript.
@Generable
struct DraftOutline {
    @Guide(description: "One to three sentences on the whole meeting. No preamble.")
    var overview: String

    @Guide(description: "The meeting's main sections in order, usually five to twelve. Join only neighbouring topics on the same subject. Each topic number in exactly one section.")
    var sections: [DraftSection]
}

@Generable
struct DraftSection {
    @Guide(description: "Three to seven word headline stating the point.")
    var title: String

    @Guide(description: "One sentence.")
    var summary: String

    @Guide(description: "One fitting emoji.")
    var emoji: String

    @Guide(description: "Topic numbers covered.")
    var topicNumbers: [Int]
}

/// The roll-up pass. Runs over the chunk notes, not over the raw transcript. Used
/// for the overview when the outline pass fails.
@Generable
struct DraftRollup {
    @Guide(description: "One to three sentences on the whole meeting. No preamble.")
    var overview: String
}

// MARK: - Into plain values

extension DraftChunkNotes {
    var notes: ChunkNotes {
        ChunkNotes(
            topics: topics.map { topic in
                NoteTopic(
                    title: topic.title,
                    summary: topic.summary,
                    points: topic.points.map { NotePoint(text: $0.text, details: [], sourceLines: Self.lines($0.sourceLines)) }
                )
            },
            // The overview fallback reads these.
            points: topics.map { "\($0.title): \($0.summary)" },
            decisions: decisions.map { NoteDecision(statement: $0.statement, sourceLines: Self.lines($0.sourceLines)) },
            actionItems: actionItems.map {
                NoteActionItem(task: $0.task, owner: Self.owner($0.owner), dueDate: $0.dueDate, sourceLines: Self.lines($0.sourceLines))
            },
            openQuestions: openQuestions.map { NoteClaim(text: $0.text, sourceLines: Self.lines($0.sourceLines)) },
            // No longer asked for: it cost context on every call for little use.
            mentionedSystems: [],
            speakerNames: speakerNames.map { NoteClaim(text: $0.text, sourceLines: Self.lines($0.sourceLines)) }
        )
    }

    /// The first three cited lines. One answer cited 270 in a row, all the way to
    /// the token cap (builds 45 and 46, despite the guide's wording); `.maximumCount`
    /// now stops that while generating, and this stays as a backstop.
    static func lines(_ lines: [Int]) -> [Int] { Array(lines.prefix(3)) }

    /// The transcript labels unnamed speakers by letter; an owner written as just
    /// "E" reads as "Speaker E".
    static func owner(_ owner: String) -> String {
        let trimmed = owner.trimmingCharacters(in: .whitespaces)
        return trimmed.count == 1 && trimmed.first?.isUppercase == true ? "Speaker \(trimmed)" : owner
    }
}

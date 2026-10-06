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

    @Guide(description: "Up to two brief facts said.")
    var details: [String]

    @Guide(description: "Line numbers.")
    var sourceLines: [Int]
}

@Generable
struct DraftDecision {
    @Guide(description: "One sentence.")
    var statement: String

    @Guide(description: "Line numbers.")
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

    @Guide(description: "Line numbers.")
    var sourceLines: [Int]
}

@Generable
struct DraftClaim {
    @Guide(description: "One sentence.")
    var text: String

    @Guide(description: "Line numbers.")
    var sourceLines: [Int]
}

/// The final pass: the meeting's overview, and which excerpt topics belong together
/// as one section. Sees only topic titles and summaries, never transcript.
@Generable
struct DraftOutline {
    @Guide(description: "One to three sentences on the whole meeting. No preamble.")
    var overview: String

    @Guide(description: "Main topics in order; join topics on the same subject. Each topic number in exactly one section.")
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
                    points: topic.points.map { NotePoint(text: $0.text, details: $0.details, sourceLines: $0.sourceLines) }
                )
            },
            // The overview fallback reads these.
            points: topics.map { "\($0.title): \($0.summary)" },
            decisions: decisions.map { NoteDecision(statement: $0.statement, sourceLines: $0.sourceLines) },
            actionItems: actionItems.map {
                NoteActionItem(task: $0.task, owner: $0.owner, dueDate: $0.dueDate, sourceLines: $0.sourceLines)
            },
            openQuestions: openQuestions.map { NoteClaim(text: $0.text, sourceLines: $0.sourceLines) },
            // No longer asked for: it cost context on every call for little use.
            mentionedSystems: [],
            speakerNames: speakerNames.map { NoteClaim(text: $0.text, sourceLines: $0.sourceLines) }
        )
    }
}

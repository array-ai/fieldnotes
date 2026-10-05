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
    @Guide(description: "What was discussed in this excerpt, grouped into one to four topics, in the order they came up.")
    var topics: [DraftTopic]

    @Guide(description: "Decisions the participants actually settled in this excerpt. Omit anything still open.")
    var decisions: [DraftDecision]

    @Guide(description: "Tasks someone committed to. Omit vague intentions.")
    var actionItems: [DraftActionItem]

    @Guide(description: "Questions raised in this excerpt that nobody answered.")
    var openQuestions: [DraftClaim]

    @Guide(description: """
        A speaker's real name, only when a participant actually said it -- someone \
        introducing themselves ("My name is X", "This is X"), or another speaker \
        addressing them by name ("Thanks, X"). Cite the line where the name was said \
        or where they were addressed, not where they merely spoke. Do not guess a name \
        from context, tone, or how someone talks. Empty if no name was ever stated.
        """)
    var speakerNames: [DraftClaim]
}

@Generable
struct DraftTopic {
    @Guide(description: "A short headline for the topic, three to seven words, stating the point rather than naming the subject.")
    var title: String

    @Guide(description: "One sentence: what was said about it and where it landed.")
    var summary: String

    @Guide(description: "The key points made, in order. Two to five.")
    var points: [DraftPoint]
}

@Generable
struct DraftPoint {
    @Guide(description: "The point, in one sentence.")
    var text: String

    @Guide(description: "Up to three short supporting details actually said: figures, names, reasons. Empty if none.")
    var details: [String]

    @Guide(description: "Line numbers from the excerpt where this point was made. At least one.")
    var sourceLines: [Int]
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

/// The final pass: the meeting's overview, and which excerpt topics belong together
/// as one section. Sees only topic titles and summaries, never transcript.
@Generable
struct DraftOutline {
    @Guide(description: """
        An overview of the whole meeting in one to three sentences, using only the \
        topics given. No preamble, no 'in this meeting'.
        """)
    var overview: String

    @Guide(description: """
        The meeting's main topics in the order they were discussed. Put excerpt topics \
        that are about the same subject into one section. Every excerpt topic belongs \
        to exactly one section.
        """)
    var sections: [DraftSection]
}

@Generable
struct DraftSection {
    @Guide(description: "A headline of three to seven words stating the point, for example 'Dual MYOB systems reduce efficiency'.")
    var title: String

    @Guide(description: "One sentence on what was said and where it landed.")
    var summary: String

    @Guide(description: "One emoji that fits the topic.")
    var emoji: String

    @Guide(description: "The numbers of the excerpt topics this section covers. At least one.")
    var topicNumbers: [Int]
}

/// The roll-up pass. Runs over the chunk notes, not over the raw transcript. Used
/// for the overview when the outline pass fails.
@Generable
struct DraftRollup {
    @Guide(description: """
        An overview of the whole meeting, using only the notes given -- never anything \
        from your own instructions, since those describe the setup, not what happened. Match the length to how much \
        the notes actually contain: a one- or two-sentence answer is correct and \
        preferred over padding when the notes are thin. No preamble, no 'in this \
        meeting'.
        """)
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

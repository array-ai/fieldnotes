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
    @Guide(description: "Key points discussed in this excerpt, in the order they came up. Plain sentences, no bullets.")
    var points: [String]

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
            points: points,
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

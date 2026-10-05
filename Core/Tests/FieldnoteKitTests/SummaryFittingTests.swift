import FieldnoteKit
import Foundation
import Testing

/// The pieces that keep a summary inside the model's context window: the budget
/// arithmetic, splitting a chunk that turned out too big, and merging its notes back.
@Suite("Summary fitting")
struct SummaryFittingTests {

    private func chunk(lines: Int, index: Int = 3, firstLine: Int = 11) -> TranscriptChunk {
        let segments = (0..<lines).map { i in
            TranscriptSegment(start: Double(i), end: Double(i) + 1, text: "line \(i)", speakerID: "S1")
        }
        return TranscriptChunk(
            index: index,
            lineNumbers: Array(firstLine..<(firstLine + lines)),
            segments: segments,
            overlapCount: 2
        )
    }

    @Test("Halves cover every line once and keep the chunk index")
    func halves() throws {
        let original = chunk(lines: 5)
        let (first, second) = try #require(original.halves())
        #expect(first.lineNumbers + second.lineNumbers == original.lineNumbers)
        #expect(first.index == original.index && second.index == original.index)
        #expect(first.segments.count == 2 && second.segments.count == 3)
        #expect(second.overlapCount == 0)
    }

    @Test("A single line can't be split")
    func singleLine() {
        #expect(chunk(lines: 1).halves() == nil)
    }

    @Test("Merged notes keep everything from both halves")
    func merge() {
        let a = ChunkNotes(points: ["a"], decisions: [NoteDecision(statement: "d1", sourceLines: [11])])
        let b = ChunkNotes(points: ["b"], openQuestions: [NoteClaim(text: "q", sourceLines: [14])])
        let merged = a.merged(with: b)
        #expect(merged.points == ["a", "b"])
        #expect(merged.decisions.count == 1)
        #expect(merged.openQuestions.count == 1)
    }

    @Test("Merged notes from split halves still ground against the original chunk")
    func mergedNotesGround() throws {
        let original = chunk(lines: 4)
        let (first, second) = try #require(original.halves())
        let notes = ChunkNotes(decisions: [NoteDecision(statement: "Ship it", sourceLines: [first.lineNumbers[0]])])
            .merged(with: ChunkNotes(decisions: [NoteDecision(statement: "Test it", sourceLines: [second.lineNumbers[0]])]))
        let outcome = SummaryGrounder(meetingDate: Date()).ground([notes], chunks: [original])
        #expect(outcome.decisions.map(\.statement) == ["Ship it", "Test it"])
        #expect(outcome.discardedClaims == 0)
    }

    @Test("The prompt limit is what's left after fixed costs and the answer")
    func budget() {
        let budget = PromptBudget(contextSize: 4_096, fixedCost: 900, outputReserve: 1_024, isMeasured: true)
        #expect(budget.promptLimit == 2_172)
        #expect(budget.chunkBudget < budget.promptLimit)
        #expect(budget.fits(promptTokens: 2_172))
        #expect(!budget.fits(promptTokens: 2_173))
    }

    @Test("The old fixed 2,800-token chunk does not fit a 4,096 context")
    func oldBudgetOverflowed() {
        // What the app used before: 2,800 transcript tokens, regardless of the
        // instructions, schema and answer that share the same window.
        #expect(!PromptBudget.fallback.fits(promptTokens: 2_800))
    }

    @Test("A tiny context still leaves a usable floor")
    func floor() {
        let budget = PromptBudget(contextSize: 1_000, fixedCost: 900, outputReserve: 1_024, isMeasured: true)
        #expect(budget.promptLimit == 256)
        #expect(budget.chunkBudget == 256)
    }

    @Test("Stored summaries without the new detail field still decode")
    func degradedChunkDecodesOldData() throws {
        let old = #"{"chunkIndex":0,"reason":"guardrail","recovered":true,"startTime":0,"endTime":5}"#
        let decoded = try JSONDecoder().decode(DegradedChunk.self, from: Data(old.utf8))
        #expect(decoded.detail == nil)
        #expect(decoded.explanation.contains("shorter prompt"))
    }
}

@Suite("Editable summary prompt")
struct SummaryPromptTests {

    @Test("The rules are always part of the instructions")
    func rulesKept() {
        let custom = SummaryPrompt(preamble: "You take terse notes for a building inspector.", request: "List defects.")
        #expect(custom.instructions.hasPrefix("You take terse notes"))
        #expect(custom.instructions.contains(PromptTemplates.groundingRules))
        #expect(!custom.isBuiltIn)
    }

    @Test("Empty fields fall back to the built-in text")
    func emptyFallsBack() {
        let blank = SummaryPrompt(preamble: "  ", request: "")
        #expect(blank.instructions == SummaryPrompt.builtIn.instructions)
        #expect(blank.effectiveRequest == SummaryPrompt.builtIn.request)
    }

    @Test("The request lands in the excerpt prompt")
    func requestInPrompt() {
        let chunk = TranscriptChunk(index: 0, lineNumbers: [1], segments: [TranscriptSegment(start: 0, end: 1, text: "hi")], overlapCount: 0)
        let prompt = PromptTemplates.chunkPrompt(chunk: chunk, chunkIndex: 0, chunkCount: 1, request: "List defects.")
        #expect(prompt.contains("List defects."))
        #expect(prompt.contains("1 | Unknown: hi"))
    }
}

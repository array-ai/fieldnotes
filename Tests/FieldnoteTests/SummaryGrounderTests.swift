import Foundation
import Testing

@Suite("Grounding")
struct SummaryGrounderTests {

    private func chunk(lines: Int = 5) -> TranscriptChunk {
        let segments = (0..<lines).map { index in
            TranscriptSegment(
                start: Double(index) * 10,
                end: Double(index) * 10 + 10,
                text: "line \(index + 1)"
            )
        }
        return TranscriptChunk(
            index: 0,
            lineNumbers: Array(1...lines),
            segments: segments,
            overlapCount: 0
        )
    }

    private var meetingDate: Date {
        DateComponents(calendar: .current, year: 2026, month: 9, day: 8, hour: 10).date!
    }

    @Test("A claim citing a line that does not exist is discarded, not saved unsourced")
    func hallucinatedCitationsAreDropped() {
        let chunk = chunk()
        let notes = DraftChunkNotes(
            points: [],
            decisions: [DraftDecision(statement: "Replace the firewall", sourceLines: [99])],
            actionItems: [],
            openQuestions: [],
            mentionedSystems: []
        )
        let outcome = SummaryGrounder(meetingDate: meetingDate).ground([notes], chunks: [chunk])

        #expect(outcome.decisions.isEmpty)
        #expect(outcome.discardedClaims == 1)
    }

    @Test("A valid citation resolves to the real segment ID")
    func validCitationsResolve() {
        let chunk = chunk()
        let notes = DraftChunkNotes(
            points: [],
            decisions: [DraftDecision(statement: "Replace the firewall", sourceLines: [3, 4])],
            actionItems: [],
            openQuestions: [],
            mentionedSystems: []
        )
        let outcome = SummaryGrounder(meetingDate: meetingDate).ground([notes], chunks: [chunk])

        #expect(outcome.decisions.count == 1)
        #expect(outcome.decisions[0].sourceSegmentID == chunk.segments[2].id)
        #expect(outcome.decisions[0].supportingSegmentIDs == [chunk.segments[3].id])
    }

    @Test("The same commitment seen in two overlapping chunks appears once")
    func overlapDoesNotDuplicate() {
        let first = chunk()
        let second = TranscriptChunk(
            index: 1,
            lineNumbers: [4, 5, 6],
            segments: Array(first.segments.suffix(2)) + [TranscriptSegment(start: 50, end: 60, text: "line 6")],
            overlapCount: 2
        )
        let action = DraftActionItem(task: "Order the replacement switch", owner: "Dave", dueDate: "", sourceLines: [4])
        let notes = DraftChunkNotes(points: [], decisions: [], actionItems: [action], openQuestions: [], mentionedSystems: [])

        let outcome = SummaryGrounder(meetingDate: meetingDate).ground([notes, notes], chunks: [first, second])
        #expect(outcome.actionItems.count == 1)
    }

    @Test("Spoken due dates resolve against the meeting date")
    func dueDatesResolveAgainstMeeting() {
        let chunk = chunk()
        let action = DraftActionItem(
            task: "Send the quote",
            owner: "Dave",
            dueDate: "next Tuesday",
            sourceLines: [1]
        )
        let notes = DraftChunkNotes(points: [], decisions: [], actionItems: [action], openQuestions: [], mentionedSystems: [])
        let outcome = SummaryGrounder(meetingDate: meetingDate).ground([notes], chunks: [chunk])

        let item = try! #require(outcome.actionItems.first)
        #expect(item.dueDate == "next Tuesday")
        let resolved = try! #require(item.resolvedDueDate)
        #expect(resolved > meetingDate)
        #expect(Calendar.current.component(.weekday, from: resolved) == 3)
    }

    @Test("An empty owner becomes nil rather than an empty string in the export")
    func emptyOwnerIsNil() {
        let chunk = chunk()
        let action = DraftActionItem(task: "Check the UPS", owner: "  ", dueDate: "", sourceLines: [2])
        let notes = DraftChunkNotes(points: [], decisions: [], actionItems: [action], openQuestions: [], mentionedSystems: [])
        let outcome = SummaryGrounder(meetingDate: meetingDate).ground([notes], chunks: [chunk])

        #expect(outcome.actionItems[0].owner == nil)
        #expect(outcome.actionItems[0].dueDate == nil)
    }

    @Test("Mentioned systems are deduplicated case-insensitively but keep their spelling")
    func systemsDeduplicate() {
        let chunk = chunk()
        let notes = DraftChunkNotes(
            points: [],
            decisions: [],
            actionItems: [],
            openQuestions: [],
            mentionedSystems: ["UniFi", "unifi", "Huntress"]
        )
        let outcome = SummaryGrounder(meetingDate: meetingDate).ground([notes], chunks: [chunk])
        #expect(outcome.mentionedSystems == ["UniFi", "Huntress"])
    }
}

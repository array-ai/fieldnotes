import FieldnoteKit
import Foundation
import Testing

@Suite("Siri answers")
struct SiriAnswersTests {

    private func meeting(
        title: String = "Network refresh",
        startedAt: Date = Date(timeIntervalSince1970: 1_000_000),
        state: ProcessingState = .complete,
        overview: String = "The comms room switch has failed and is being replaced",
        actionItems: [ActionItem]? = nil
    ) -> MeetingSnapshot {
        let source = UUID()
        let summary = MeetingSummary(
            overview: overview,
            actionItems: actionItems ?? [
                ActionItem(task: "Order a replacement switch", owner: "S2", sourceSegmentID: source),
                ActionItem(task: "Book the electrician.", sourceSegmentID: source)
            ]
        )
        var snapshot = MeetingSnapshot(title: title, type: .general, startedAt: startedAt, state: state)
        snapshot.summary = state == .complete ? summary : nil
        snapshot.speakerNames = ["S2": "Dave"]
        return snapshot
    }

    @Test("The last meeting is the newest one with finished notes")
    func lastFinished() {
        let older = meeting(title: "Older", startedAt: Date(timeIntervalSince1970: 1))
        let newest = meeting(title: "Newest", startedAt: Date(timeIntervalSince1970: 2))
        let processing = meeting(title: "Processing", startedAt: Date(timeIntervalSince1970: 3), state: .summarising)
        #expect(SiriAnswers.lastFinished([older, processing, newest])?.title == "Newest")
        #expect(SiriAnswers.lastFinished([processing]) == nil)
    }

    @Test("Action items name their owner, with speaker labels resolved")
    func actionItems() {
        #expect(
            SiriAnswers.actionItems(meeting())
                == "Network refresh has 2 action items. Dave: Order a replacement switch. Book the electrician."
        )
        #expect(SiriAnswers.actionItems(meeting(actionItems: [])) == "Network refresh has no action items.")
    }

    @Test("Only the first few action items are read out")
    func actionItemsCapped() {
        let items = (1...8).map { ActionItem(task: "Task \($0)", sourceSegmentID: UUID()) }
        let answer = SiriAnswers.actionItems(meeting(actionItems: items))
        #expect(answer.hasPrefix("Network refresh has 8 action items."))
        #expect(answer.contains("Task 5."))
        #expect(!answer.contains("Task 6"))
        #expect(answer.hasSuffix("And 3 more in Fieldnote."))
    }

    @Test("The summary is the overview, cut short at a word when long")
    func summary() {
        #expect(
            SiriAnswers.summary(meeting())
                == "Network refresh. The comms room switch has failed and is being replaced."
        )
        let long = meeting(overview: String(repeating: "word ", count: 200))
        let answer = SiriAnswers.summary(long)
        #expect(answer.count <= SiriAnswers.maxCharacters + 1)
        #expect(answer.hasSuffix("word…"))
    }

    @Test("Status names the meeting only when allowed")
    func status() {
        let now = Date(timeIntervalSince1970: 10_000)
        var working = meeting(title: "Budget", startedAt: now, state: .summarising)
        working.estimatedCompletion = now.addingTimeInterval(4 * 60)
        #expect(
            SiriAnswers.status([working], includeTitle: false, now: now)
                == "Fieldnote is still working on the notes for your last meeting. About 4 minutes left."
        )
        #expect(SiriAnswers.status([meeting()], includeTitle: true) == "The notes for Network refresh are ready.")
        #expect(SiriAnswers.status([meeting()], includeTitle: false) == "The notes for your last meeting are ready.")
        #expect(SiriAnswers.status([], includeTitle: true) == "You have no meetings in Fieldnote yet.")
    }
}

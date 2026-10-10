import FieldnoteKit
import Foundation
import Testing

@Suite("Meeting search")
struct MeetingSearchTests {

    @Test("Every word must appear, in any order")
    func anyOrder() {
        let text = MeetingSearch.normalize("We'll review the budget on Friday")
        #expect(MeetingSearch.matches(text, terms: MeetingSearch.terms("budget review")))
        #expect(!MeetingSearch.matches(text, terms: MeetingSearch.terms("budget monday")))
    }

    @Test("Case, accents and curly quotes don't matter")
    func folding() {
        let text = MeetingSearch.normalize("Café meeting, we don\u{2019}t agree")
        #expect(MeetingSearch.matches(text, terms: MeetingSearch.terms("CAFE")))
        #expect(MeetingSearch.matches(text, terms: MeetingSearch.terms("don't")))
    }

    @Test("The list's search covers the title, client, place, speakers and the notes under each meeting")
    func indexesListFields() {
        let segment = UUID()
        let summary = MeetingSummary(
            overview: "Network upgrade plans",
            topics: [SummaryTopic(title: "Firewall rollout", summary: "Branch offices first", points: [
                TopicPoint(text: "Sydney goes live in March", details: ["Needs a change window"], sourceSegmentID: segment),
            ])],
            decisions: [], actionItems: [ActionItem(task: "Order the switch", owner: "Dave", sourceSegmentID: segment)],
            openQuestions: [OpenQuestion(text: "Who owns the licences?", sourceSegmentID: segment)]
        )
        let text = MeetingSearch.indexText(title: "Weekly", client: "Acme Logistics", placeName: "Melbourne", speakerNames: ["Priya"], summary: summary)
        for query in ["weekly", "acme", "logistics", "melbourne", "priya", "network upgrade", "firewall", "branch offices", "w"] {
            #expect(MeetingSearch.matches(text, terms: MeetingSearch.terms(query)), "\(query)")
        }
        // The rest of the notes are for Find inside the meeting.
        for query in ["sydney", "change window", "switch", "licences"] {
            #expect(!MeetingSearch.matches(text, terms: MeetingSearch.terms(query)), "\(query)")
        }
    }
}

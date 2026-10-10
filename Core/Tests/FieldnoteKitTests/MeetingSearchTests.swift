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

    @Test("Notes are indexed: topics, points, details, task owners and open questions")
    func indexesNotes() {
        let segment = UUID()
        let summary = MeetingSummary(
            overview: "",
            topics: [SummaryTopic(title: "Firewall rollout", summary: "Phased", points: [
                TopicPoint(text: "Start with the branch offices", details: ["Sydney first"], sourceSegmentID: segment),
            ])],
            decisions: [], actionItems: [ActionItem(task: "Order the switch", owner: "Dave", sourceSegmentID: segment)],
            openQuestions: [OpenQuestion(text: "Who owns the licences?", sourceSegmentID: segment)]
        )
        let text = MeetingSearch.indexText(title: "Weekly", placeName: "Melbourne", speakerNames: ["Priya"], segments: [], summary: summary)
        for query in ["firewall", "branch offices", "sydney", "licences", "melbourne", "priya", "dave"] {
            #expect(MeetingSearch.matches(text, terms: MeetingSearch.terms(query)), "\(query)")
        }
    }

    @Test("The snippet is the matching transcript line, trimmed around the match")
    func snippet() {
        let line = TranscriptSegment(start: 42, end: 45, text: String(repeating: "filler ", count: 30) + "the quarterly budget is tight " + String(repeating: "words ", count: 30))
        let meeting = MeetingSnapshot(title: "Budget", type: .general, startedAt: Date(), segments: [TranscriptSegment(start: 0, end: 2, text: "Hello"), line])
        let found = MeetingSearch.snippet(in: meeting, terms: MeetingSearch.terms("Budget"))
        #expect(found?.segmentID == line.id)
        #expect(found?.start == 42)
        #expect(found?.text.contains("quarterly budget") == true)
        #expect(found?.text.hasPrefix("…") == true)
        #expect(found?.text.hasSuffix("…") == true)
    }
}

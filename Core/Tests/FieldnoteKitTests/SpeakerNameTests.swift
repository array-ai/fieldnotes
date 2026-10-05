import FieldnoteKit
import Foundation
import Testing

@Suite("Speaker names in notes")
struct SpeakerNameTests {

    @Test("Given names replace the letter forms, whole words only")
    func replaces() {
        let names = ["S1": "Priya", "S2": "Speaker B", "S27": "Tom"]
        #expect(SpeakerLabel.applyNames(names, to: "Speaker A will send it to Speaker AA.") == "Priya will send it to Tom.")
        // No name given for S2: left alone.
        #expect(SpeakerLabel.applyNames(names, to: "Speaker B agreed.") == "Speaker B agreed.")
    }

    @Test("Owners and points pick up the names")
    func summary() {
        let segment = UUID()
        let summary = MeetingSummary(
            overview: "Speaker A led.",
            topics: [SummaryTopic(title: "Plan", summary: "", points: [TopicPoint(text: "Speaker A owns it", details: [], sourceSegmentID: segment)])],
            decisions: [],
            actionItems: [ActionItem(task: "Send the deck", owner: "Speaker A", sourceSegmentID: segment)],
            openQuestions: []
        ).applyingSpeakerNames(["S1": "Priya"])
        #expect(summary.overview == "Priya led.")
        #expect(summary.topics?.first?.points.first?.text == "Priya owns it")
        #expect(summary.actionItems.first?.owner == "Priya")
    }
}

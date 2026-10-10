@testable import FieldnoteKit
import Foundation
import Testing

@Suite("Plain notes from small models")
struct PlainNotesTests {

    let chunk = TranscriptChunk(
        index: 0,
        lineNumbers: [10, 11, 12, 13, 14],
        segments: [
            TranscriptSegment(start: 0, end: 4, text: "Thanks for joining, the commercial part is done.", speakerID: "S1"),
            TranscriptSegment(start: 4, end: 8, text: "Now we need to prove the technical side works.", speakerID: "S1"),
            TranscriptSegment(start: 8, end: 12, text: "My name is Alex, I run the integration team.", speakerID: "S2"),
            TranscriptSegment(start: 12, end: 16, text: "Can you send the firewall rules by Friday?", speakerID: "S1"),
            TranscriptSegment(start: 16, end: 20, text: "Yes, I'll send the firewall rules by Friday.", speakerID: "S2"),
        ],
        overlapCount: 0
    )

    @Test("The asked-for format parses into topics, tasks and names")
    func wellFormed() {
        let text = """
            TOPIC: Moving from commercial to technical
            - The commercial agreement is finished [10]
            - The team now has to prove the technical side [11]
            TASK: Send the firewall rules | Alex | Friday [13, 14]
            NAME: Alex [12]
            """
        let notes = PlainNotes.parse(text, chunk: chunk)
        #expect(notes.topics.count == 1)
        #expect(notes.topics[0].title == "Moving from commercial to technical")
        #expect(notes.topics[0].points.map(\.sourceLines) == [[10], [11]])
        #expect(notes.actionItems.first?.owner == "Alex")
        #expect(notes.actionItems.first?.dueDate == "Friday")
        #expect(notes.actionItems.first?.sourceLines == [13, 14])
        #expect(notes.speakerNames.first?.text == "Alex")
    }

    @Test("Labels in brackets, as LFM2.5 writes them, are accepted")
    func bracketedLabels() {
        let text = """
            [TOPIC] Moving from commercial to technical
            [Key Point 1] The commercial agreement is finished [10]
            [Number 11] The team now has to prove the technical side [11]
            [3] Alex runs the integration team [12]
            [Decision] Prove the technical side next [11]
            [Task] Send the firewall rules | Alex | Friday [13]
            [Potential unwanted software discussed]
            """
        let notes = PlainNotes.parse(text, chunk: chunk)
        #expect(notes.topics.map(\.title) == ["Moving from commercial to technical"])
        #expect(notes.topics.first?.points.map(\.sourceLines) == [[10], [11], [12]])
        #expect(notes.decisions.first?.sourceLines == [11])
        #expect(notes.actionItems.first?.owner == "Alex")
    }

    @Test("Notes with no overview and no topics count as empty")
    func emptySummary() {
        let segment = UUID()
        #expect(MeetingSummary(actionItems: [ActionItem(task: "Stray task", sourceSegmentID: segment)]).isEmpty)
        #expect(!MeetingSummary(overview: "A short call.").isEmpty)
        #expect(!MeetingSummary(topics: [SummaryTopic(title: "Budget", summary: "", points: [])]).isEmpty)
    }

    @Test("Markdown, other bullets and citation styles are accepted")
    func forgiving() {
        let text = """
            ## **Topic:** Technical proof
            * Need to prove the technical side (line 11)
            1. Commercial part done (L10)
            **Task** - send firewall rules | none | n/a [13-14]
            Open question: who signs off? [99]
            """
        let notes = PlainNotes.parse(text, chunk: chunk)
        #expect(notes.topics.first?.points.map(\.sourceLines) == [[11], [10]])
        #expect(notes.actionItems.first?.owner == "")
        #expect(notes.actionItems.first?.dueDate == "")
        #expect(notes.actionItems.first?.sourceLines == [13, 14])
        // Line 99 isn't in the excerpt, and no line shares two words with it.
        #expect(notes.openQuestions.isEmpty)
    }

    @Test("Citations written with the prompt's angle brackets still count")
    func angleBrackets() {
        let text = """
            TOPIC: Firewall rules [<13, 14>]
            - The firewall rules are due Friday [<13, 14>]
            TASK: Send the firewall rules | Alex | Friday [<14>]
            NAME: Alex [<12>]
            QUESTION: Who checks them? <13>
            """
        let notes = PlainNotes.parse(text, chunk: chunk)
        #expect(notes.topics.first?.title == "Firewall rules")
        #expect(notes.topics.first?.points.first?.sourceLines == [13, 14])
        #expect(notes.actionItems.first?.sourceLines == [14])
        #expect(notes.speakerNames.first?.sourceLines == [12])
        #expect(notes.openQuestions.first?.sourceLines == [13])
    }

    @Test("A point without a usable citation is matched to the line it repeats")
    func bestLineFallback() {
        let text = """
            TOPIC: Firewall
            - Speaker A: Can you send the firewall rules by Friday? [-1, -2, -3]
            - Something nobody said at all
            """
        let notes = PlainNotes.parse(text, chunk: chunk)
        let points = notes.topics.first?.points ?? []
        #expect(points.count == 1)
        #expect(points.first?.text == "Can you send the firewall rules by Friday?")
        #expect(points.first?.sourceLines == [13])
    }

    @Test("Points before any topic get one; empty topics and label names are dropped")
    func edges() {
        let text = """
            - The commercial part is done [10]
            TOPIC: Nothing under this one
            NAME: Speaker B [12]
            """
        let notes = PlainNotes.parse(text, chunk: chunk)
        #expect(notes.topics.map(\.title) == ["Discussion"])
        #expect(notes.speakerNames.isEmpty)
    }

    @Test("Echoed format labels are removed from points")
    func echoedLabels() {
        let notes = PlainNotes.parse("TOPIC: Firewall\n- Key point: The firewall rules are due Friday [13]", chunk: chunk)
        #expect(notes.topics.first?.points.first?.text == "The firewall rules are due Friday")
    }

    @Test("Empty citations are removed; only plausible names are kept")
    func emptyCitationsAndNames() {
        let text = """
            TOPIC: Antivirus
            - Evaluating VendorA against VendorD [, , ] [13]
            NAME: EDR team | E | C [12]
            NAME: Sam , Chris [12]
            NAME: Speaker G [, ] [12]
            NAME: Alex [12]
            """
        let notes = PlainNotes.parse(text, chunk: chunk)
        #expect(notes.topics.first?.points.first?.text == "Evaluating VendorA against VendorD")
        #expect(notes.speakerNames.map(\.text) == ["Alex"])
    }

    @Test("Bare speaker letters become Speaker labels")
    func speakerLetters() {
        let text = """
            TOPIC: Migration
            - F asks about migrating the agents [13]
            - A new console was shown [11]
            TASK: Show the exclusion list | E | Friday [14]
            """
        let notes = PlainNotes.parse(text, chunk: chunk)
        #expect(notes.topics.first?.points.map(\.text) == ["Speaker F asks about migrating the agents", "A new console was shown"])
        #expect(notes.actionItems.first?.owner == "Speaker E")
        #expect(notes.topics.first?.summary == "")
    }

    @Test("Labelled bullets go to their own lists; answers are dropped")
    func labelledBullets() {
        let text = """
            TOPIC: Firewall
            - The firewall rules are due Friday [13]
            - Decision: Send the firewall rules this week [13]
            - Task: Send the firewall rules | Alex | Friday [14]
            - Question: Who reviews the rules? [13]
            - Answer: Alex will [14]
            """
        let notes = PlainNotes.parse(text, chunk: chunk)
        #expect(notes.topics.first?.points.map(\.text) == ["The firewall rules are due Friday"])
        #expect(notes.decisions.count == 1)
        #expect(notes.actionItems.first?.owner == "Alex")
        #expect(notes.openQuestions.count == 1)
    }

    @Test("An overview loses its label and quotes")
    func overview() {
        #expect(PlainNotes.cleanOverview("**Overview:** \"The team moved to the technical phase.\"") == "The team moved to the technical phase.")
    }

    @Test("A think block is dropped, finished or not")
    func thinking() {
        #expect(PlainNotes.cleanOverview("<think>\n\n</think>\n\nThe team chose a backup tool.") == "The team chose a backup tool.")
        #expect(PlainNotes.cleanOverview("Done.<think>half a thought") == "Done.")
    }
}

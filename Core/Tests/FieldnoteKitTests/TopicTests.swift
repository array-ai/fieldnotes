import FieldnoteKit
import Foundation
import Testing

@Suite("Topic notes")
struct TopicTests {

    private let segments: [TranscriptSegment] = (0..<6).map { i in
        TranscriptSegment(start: Double(i) * 10, end: Double(i) * 10 + 9, text: "line \(i)", speakerID: "S1")
    }

    private var chunk: TranscriptChunk {
        TranscriptChunk(index: 0, lineNumbers: Array(1...6), segments: segments, overlapCount: 0)
    }

    private func time(_ id: UUID) -> TimeInterval {
        segments.first { $0.id == id }?.start ?? .greatestFiniteMagnitude
    }

    @Test("Topic points keep only cited lines; empty topics are dropped")
    func grounding() {
        let notes = ChunkNotes(topics: [
            NoteTopic(title: "Network", summary: "Too complex.", points: [
                NotePoint(text: "Three routers", details: ["Huawei and D-Link"], sourceLines: [2]),
                NotePoint(text: "Made up", sourceLines: [99])
            ]),
            NoteTopic(title: "Nothing real", points: [NotePoint(text: "Invented", sourceLines: [42])])
        ])
        let outcome = SummaryGrounder(meetingDate: Date()).ground([notes], chunks: [chunk])
        #expect(outcome.topics.map(\.title) == ["Network"])
        #expect(outcome.topics.first?.points.map(\.text) == ["Three routers"])
        #expect(outcome.topics.first?.points.first?.details == ["Huawei and D-Link"])
        #expect(outcome.topics.first?.points.first?.sourceSegmentID == segments[1].id)
        #expect(outcome.discardedClaims == 2)
    }

    @Test("Grouped topics merge, drop repeats and sort by time")
    func merge() {
        let a = SummaryTopic(title: "Net A", summary: "", points: [TopicPoint(text: "Later", sourceSegmentID: segments[4].id)])
        let b = SummaryTopic(title: "Net B", summary: "", points: [
            TopicPoint(text: "Earlier", sourceSegmentID: segments[1].id),
            TopicPoint(text: "later", sourceSegmentID: segments[4].id)
        ])
        let c = SummaryTopic(title: "Costs", summary: "Up", points: [TopicPoint(text: "Fees", sourceSegmentID: segments[0].id)])
        let merged = TopicMerger.merge(
            [a, b, c],
            sections: [TopicMerger.Section(title: "Network", summary: "Needs work", members: [0, 1, 7], emoji: "🔌")],
            time: time
        )
        #expect(merged.map(\.title) == ["Costs", "Network"])
        #expect(merged[1].points.map(\.text) == ["Earlier", "Later"])
        #expect(merged[1].emoji == "🔌")
    }

    @Test("A section of far-apart or too many topics is split into runs of neighbours")
    func runs() {
        let topics = (0..<12).map {
            SummaryTopic(title: "T\($0)", summary: "", points: [TopicPoint(text: "P\($0)", sourceSegmentID: segments[0].id)])
        }
        let merged = TopicMerger.merge(
            topics,
            sections: [TopicMerger.Section(title: "Everything", summary: "All", members: [0, 1, 2, 3, 4, 5, 9, 11])],
            time: time
        )
        // 0–3 (capped at four), 4–5, then 9 and 11 (one apart): all twelve accounted for.
        #expect(merged.filter { $0.title == "Everything" }.count == 1)
        #expect(merged.first { $0.title == "Everything" }?.points.count == 4)
        #expect(merged.contains { $0.title == "T4" && $0.points.count == 2 })
        #expect(merged.contains { $0.title == "T9" && $0.points.count == 2 })
        #expect(merged.reduce(0) { $0 + $1.points.count } == 12)
    }

    @Test("Without a grouping, same-titled topics join")
    func fallback() {
        let a = SummaryTopic(title: "Backups", summary: "s", points: [TopicPoint(text: "One", sourceSegmentID: segments[0].id)])
        let b = SummaryTopic(title: "backups", summary: "", points: [TopicPoint(text: "Two", sourceSegmentID: segments[2].id)])
        let merged = TopicMerger.mergeByTitle([a, b], time: time)
        #expect(merged.count == 1)
        #expect(merged.first?.points.count == 2)
    }

    @Test("Action items group by owner, unassigned last")
    func ownerGroups() {
        let id = segments[0].id
        let groups = ActionItem.groupedByOwner([
            ActionItem(task: "a", owner: nil, sourceSegmentID: id),
            ActionItem(task: "b", owner: "IT team", sourceSegmentID: id),
            ActionItem(task: "c", owner: "it team", sourceSegmentID: id),
            ActionItem(task: "d", owner: "Cheryl", sourceSegmentID: id)
        ])
        #expect(groups.map(\.owner) == ["IT team", "Cheryl", "Unassigned"])
        #expect(groups[0].items.map(\.task) == ["b", "c"])
    }

    @Test("Markdown notes show topic, summary, timed points and details")
    func markdownNotes() {
        let summary = MeetingSummary(topics: [
            SummaryTopic(title: "Network", summary: "Needs simplifying.", points: [
                TopicPoint(text: "Three routers", details: ["Layered NAT"], sourceSegmentID: segments[1].id)
            ])
        ])
        let meeting = MeetingSnapshot(title: "Visit", type: .general, startedAt: Date(), segments: segments, summary: summary)
        let markdown = MarkdownRenderer().renderSummary(meeting)
        #expect(markdown.contains("## Notes"))
        #expect(markdown.contains("### Network"))
        #expect(markdown.contains("_Needs simplifying._"))
        #expect(markdown.contains("- Three routers [0:10]"))
        #expect(markdown.contains("  - Layered NAT"))
    }

    @Test("Summaries stored before topics existed still decode")
    func oldSummaryDecodes() throws {
        let old = #"{"overview":"x","decisions":[],"actionItems":[],"openQuestions":[],"mentionedSystems":[],"degradedChunks":[],"speakerNames":{}}"#
        let decoded = try JSONDecoder().decode(MeetingSummary.self, from: Data(old.utf8))
        #expect(decoded.topics == nil)
    }
}

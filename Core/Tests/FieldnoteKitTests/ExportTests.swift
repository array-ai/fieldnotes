import FieldnoteKit
import Foundation
import Testing

@Suite("Export formats")
struct ExportTests {

    private var segments: [TranscriptSegment] {
        [
            TranscriptSegment(start: 0, end: 4, text: "Right, the switch in the comms room is the problem.", speakerID: "S1"),
            TranscriptSegment(start: 4, end: 9, text: "I will order a replacement tomorrow.", speakerID: "S2"),
            TranscriptSegment(start: 9, end: 12, text: "Who is paying for it?", speakerID: "S1")
        ]
    }

    private func meeting() -> MeetingSnapshot {
        let segments = segments
        let summary = MeetingSummary(
            overview: "The switch in the comms room has failed and is being replaced.",
            decisions: [Decision(statement: "Replace the comms room switch", sourceSegmentID: segments[0].id)],
            actionItems: [
                ActionItem(
                    task: "Order a replacement switch",
                    owner: "Dave",
                    dueDate: "tomorrow",
                    resolvedDueDate: nil,
                    sourceSegmentID: segments[1].id
                )
            ],
            openQuestions: [OpenQuestion(text: "Who is paying for the switch?", sourceSegmentID: segments[2].id)],
            mentionedSystems: ["UniFi"]
        )
        return MeetingSnapshot(
            title: "Harbour Motors - comms room",
            type: .siteVisit,
            startedAt: DateComponents(calendar: .current, year: 2026, month: 9, day: 8, hour: 9).date!,
            duration: 620,
            folderName: "Harbour Motors",
            segments: segments,
            speakerNames: ["S1": "Client", "S2": "Dave"],
            summary: summary
        )
    }

    @Test("Every decision and action in the Markdown carries the time it came from")
    func markdownCitesSources() {
        let markdown = MarkdownRenderer().renderSummary(meeting())
        #expect(markdown.contains("Replace the comms room switch [0:00]"))
        #expect(markdown.contains("Order a replacement switch"))
        #expect(markdown.contains("[0:04]"))
    }

    @Test("Tasks export is a checklist grouped by owner, with due date")
    func tasksAreAChecklist() {
        let markdown = MarkdownRenderer().renderTasks(meeting())
        #expect(markdown.contains("### Dave"))
        #expect(markdown.contains("- [ ] Order a replacement switch (due tomorrow"))
    }

    @Test("Transcript export uses speaker display names, not raw labels")
    func transcriptUsesNames() {
        let markdown = MarkdownRenderer().renderTranscript(meeting())
        #expect(markdown.contains("**[0:00] Client:**"))
        #expect(markdown.contains("**[0:04] Dave:**"))
        #expect(!markdown.contains("S1:"))
    }

    @Test("A folder export skips meetings that are still processing and says so")
    func folderExportSkipsUnfinished() {
        var pending = meeting()
        pending.state = .summarising
        let markdown = MarkdownRenderer().renderFolder(
            name: "Harbour Motors",
            meetings: [meeting(), pending]
        )
        #expect(markdown.contains("1 meeting(s) still processing were skipped."))
    }

    @Test("WebVTT and SRT carry speaker names and well-formed timecodes")
    func subtitleFormats() {
        let vtt = SubtitleRenderer.webVTT(segments: segments, speakerNames: ["S1": "Client", "S2": "Dave"])
        #expect(vtt.hasPrefix("WEBVTT"))
        #expect(vtt.contains("00:00:00.000 --> 00:00:04.000"))
        #expect(vtt.contains("<v Client>"))

        let srt = SubtitleRenderer.srt(segments: segments, speakerNames: ["S2": "Dave"])
        #expect(srt.contains("00:00:04,000 --> 00:00:09,000"))
        #expect(srt.contains("Dave: I will order a replacement tomorrow."))
        #expect(srt.hasPrefix("1\n"))
    }

    @Test("A zero-length segment still produces a visible cue")
    func zeroLengthCue() {
        let vtt = SubtitleRenderer.webVTT(segments: [TranscriptSegment(start: 5, end: 5, text: "Yep")])
        #expect(vtt.contains("00:00:05.000 --> 00:00:06.000"))
    }

    @Test("Filenames follow YYYY-MM-DD Folder - Title and survive hostile input")
    func filenames() {
        let date = DateComponents(calendar: .current, year: 2026, month: 9, day: 8).date!
        #expect(
            ExportFilename.base(date: date, folder: "Harbour Motors", title: "Comms room")
                == "2026-09-08 Harbour Motors - Comms room"
        )
        #expect(
            ExportFilename.name(date: date, folder: nil, title: "Site/visit: notes", suffix: "tasks", fileExtension: "md")
                == "2026-09-08 - Site visit notes tasks.md"
        )
    }

    @Test("Plain text drops Markdown that ticket fields would show literally")
    func plainTextIsPlain() {
        let plain = PlainTextRenderer.from(markdown: MarkdownRenderer().renderTasks(meeting()))
        #expect(!plain.contains("- [ ]"))
        #expect(!plain.contains("**"))
        #expect(plain.contains("☐ Order a replacement switch"))
    }

    @Test("A meeting with no summary renders without crashing or claiming one exists")
    func noSummaryYet() {
        var pending = meeting()
        pending.summary = nil
        pending.state = .transcribing
        let markdown = MarkdownRenderer().render(pending, sections: .summary)
        #expect(markdown.contains("_No summary yet._"))
    }
}

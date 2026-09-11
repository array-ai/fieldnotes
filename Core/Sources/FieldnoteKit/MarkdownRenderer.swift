import Foundation

/// Markdown is the canonical export; PDF and rich text are generated from it
/// (spec 6.4). Pure string work, no frameworks, so the formats are testable.
public struct MarkdownRenderer: Sendable {

    public struct Sections: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let overview = Sections(rawValue: 1 << 0)
        public static let decisions = Sections(rawValue: 1 << 1)
        public static let actions = Sections(rawValue: 1 << 2)
        public static let openQuestions = Sections(rawValue: 1 << 3)
        public static let mentionedSystems = Sections(rawValue: 1 << 4)
        public static let transcript = Sections(rawValue: 1 << 5)

        public static let summary: Sections = [.overview, .decisions, .actions, .openQuestions, .mentionedSystems]
        public static let everything: Sections = [.summary, .transcript]
    }

    public var includeTimestamps: Bool
    public var dateStyle: Date.FormatStyle

    public init(includeTimestamps: Bool = true, dateStyle: Date.FormatStyle = .dateTime.day().month(.wide).year().hour().minute()) {
        self.includeTimestamps = includeTimestamps
        self.dateStyle = dateStyle
    }

    // MARK: - Whole meeting

    public func render(_ meeting: MeetingSnapshot, sections: Sections = .summary) -> String {
        var out = ["# \(meeting.title)", ""]
        out.append(header(meeting))
        out.append("")

        if let summary = meeting.summary {
            if sections.contains(.overview), !summary.overview.isEmpty {
                out.append(contentsOf: ["## Overview", "", summary.overview, ""])
            }
            if sections.contains(.decisions), !summary.decisions.isEmpty {
                out.append(contentsOf: ["## Decisions", ""])
                for decision in summary.decisions {
                    out.append("- \(decision.statement)\(citation(decision.sourceSegmentID, in: meeting))")
                }
                out.append("")
            }
            if sections.contains(.actions), !summary.actionItems.isEmpty {
                out.append(contentsOf: ["## Action items", ""])
                out.append(contentsOf: summary.actionItems.map { taskLine($0, in: meeting) })
                out.append("")
            }
            if sections.contains(.openQuestions), !summary.openQuestions.isEmpty {
                out.append(contentsOf: ["## Open questions", ""])
                for question in summary.openQuestions {
                    out.append("- \(question.text)\(citation(question.sourceSegmentID, in: meeting))")
                }
                out.append("")
            }
            if sections.contains(.mentionedSystems), !summary.mentionedSystems.isEmpty {
                out.append(contentsOf: [
                    "## Systems mentioned",
                    "",
                    summary.mentionedSystems.joined(separator: ", "),
                    ""
                ])
            }
            if !summary.degradedChunks.isEmpty {
                out.append(contentsOf: [degradedNote(summary.degradedChunks), ""])
            }
        } else if sections.intersection(.summary).isEmpty == false {
            out.append(contentsOf: ["_No summary yet._", ""])
        }

        if sections.contains(.transcript) {
            out.append(contentsOf: ["## Transcript", "", transcriptBody(meeting)])
        }

        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    // MARK: - Individual payloads

    public func renderSummary(_ meeting: MeetingSnapshot) -> String {
        render(meeting, sections: .summary)
    }

    /// Tasks only, as a Markdown checklist (spec 6.1).
    public func renderTasks(_ meeting: MeetingSnapshot) -> String {
        guard let summary = meeting.summary, !summary.actionItems.isEmpty else {
            return "# \(meeting.title)\n\nNo action items.\n"
        }
        var out = ["# \(meeting.title) - action items", "", header(meeting), ""]
        out.append(contentsOf: summary.actionItems.map { taskLine($0, in: meeting) })
        return out.joined(separator: "\n") + "\n"
    }

    public func renderTranscript(_ meeting: MeetingSnapshot) -> String {
        """
        # \(meeting.title) - transcript

        \(header(meeting))

        \(transcriptBody(meeting))
        """
    }

    /// One file per meeting, concatenated for a folder export (spec 6.2).
    public func renderFolder(name: String, meetings: [MeetingSnapshot], sections: Sections = .summary) -> String {
        let ready = meetings.filter { $0.state == .complete }
        var out = ["# \(name)", ""]
        if ready.count != meetings.count {
            out.append("_\(meetings.count - ready.count) meeting(s) still processing were skipped._")
            out.append("")
        }
        for meeting in ready {
            out.append(render(meeting, sections: sections))
            out.append("---")
            out.append("")
        }
        return out.joined(separator: "\n")
    }

    // MARK: - Pieces

    private func header(_ meeting: MeetingSnapshot) -> String {
        var parts = [meeting.startedAt.formatted(dateStyle), meeting.type.displayName]
        if meeting.duration > 0 { parts.append(Timecode.short(meeting.duration)) }
        if let folder = meeting.folderName { parts.append(folder) }
        let speakers = meeting.speakerNames.values.sorted()
        if !speakers.isEmpty { parts.append(speakers.joined(separator: ", ")) }
        return "_\(parts.joined(separator: " · "))_"
    }

    private func taskLine(_ item: ActionItem, in meeting: MeetingSnapshot) -> String {
        var line = "- [ ] \(item.task)"
        if let owner = item.owner, !owner.isEmpty { line += " — \(owner)" }
        if let due = item.dueDate, !due.isEmpty {
            line += " (due \(due)"
            if let resolved = item.resolvedDueDate {
                line += ", \(resolved.formatted(.dateTime.day().month(.abbreviated)))"
            }
            line += ")"
        }
        return line + citation(item.sourceSegmentID, in: meeting)
    }

    /// Every claim points at the line it came from. Tapping it in the app jumps
    /// there; in an export it is at least a timestamp you can scrub to.
    private func citation(_ segmentID: UUID, in meeting: MeetingSnapshot) -> String {
        guard includeTimestamps, let segment = meeting.segments.first(where: { $0.id == segmentID }) else { return "" }
        return " [\(Timecode.short(segment.start))]"
    }

    private func transcriptBody(_ meeting: MeetingSnapshot) -> String {
        meeting.segments.map { segment in
            let speaker = segment.speakerID.map { meeting.speakerNames[$0] ?? $0 } ?? "Unknown"
            let stamp = includeTimestamps ? "[\(Timecode.short(segment.start))] " : ""
            return "**\(stamp)\(speaker):** \(segment.text)"
        }
        .joined(separator: "\n\n")
    }

    private func degradedNote(_ chunks: [DegradedChunk]) -> String {
        let recovered = chunks.filter(\.recovered).count
        let lost = chunks.count - recovered
        let ranges = chunks
            .map { "\(Timecode.short($0.startTime))–\(Timecode.short($0.endTime))" }
            .joined(separator: ", ")
        var note = "> Part of this meeting summarised with a reduced prompt (\(ranges))."
        if lost > 0 {
            note += " \(lost) section(s) could not be summarised at all; the transcript is complete."
        }
        return note
    }
}

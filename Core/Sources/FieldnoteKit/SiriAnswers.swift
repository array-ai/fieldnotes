import Foundation

/// What Fieldnote says when Siri asks about a meeting. Built from the notes only,
/// never from transcript lines, and kept short: Siri may process the answer off the
/// phone, so it gets no more than the question needs.
public enum SiriAnswers {
    /// "Let Siri read meeting notes" in Settings. Off by default; without it Siri
    /// gets no meeting titles or notes.
    public static let enabledKey = "siriReadsNotes"
    /// Action items read out before "and N more".
    public static let maxItems = 5
    /// The longest answer, in characters. Longer ones are cut at a word.
    public static let maxCharacters = 450

    /// The newest meeting whose notes are finished. A meeting still recording or
    /// being processed isn't the "last meeting" anyone means.
    public static func lastFinished(_ meetings: [MeetingSnapshot]) -> MeetingSnapshot? {
        meetings
            .filter { $0.state == .complete && $0.summary != nil }
            .max { $0.startedAt < $1.startedAt }
    }

    public static func actionItems(_ meeting: MeetingSnapshot) -> String {
        let items = meeting.summary?.actionItems ?? []
        guard !items.isEmpty else { return "\(meeting.title) has no action items." }

        let count = items.count == 1 ? "1 action item" : "\(items.count) action items"
        var sentences = ["\(meeting.title) has \(count)."]
        for item in items.prefix(maxItems) {
            var line = sentence(SpeakerLabel.applyNames(meeting.speakerNames, to: item.task.trimmed()))
            if let owner = item.owner?.trimmed().nilIfEmpty {
                line = "\(SpeakerLabel.name(owner, names: meeting.speakerNames)): \(line)"
            }
            sentences.append(line)
        }
        if items.count > maxItems {
            sentences.append("And \(items.count - maxItems) more in Fieldnote.")
        }
        return capped(sentences.joined(separator: " "))
    }

    public static func summary(_ meeting: MeetingSnapshot) -> String {
        let overview = meeting.summary.map { SpeakerLabel.applyNames(meeting.speakerNames, to: $0.overview.trimmed()) } ?? ""
        guard !overview.isEmpty else { return "\(meeting.title) has no overview." }
        return capped("\(meeting.title). \(sentence(overview))")
    }

    /// Where the newest meeting is up to. Names it only when `includeTitle`, as the
    /// title is meeting content.
    public static func status(_ meetings: [MeetingSnapshot], includeTitle: Bool, now: Date = .now) -> String {
        guard let latest = meetings.max(by: { $0.startedAt < $1.startedAt }) else {
            return "You have no meetings in Fieldnote yet."
        }
        let name = includeTitle ? latest.title : "your last meeting"
        switch latest.state {
        case .recording:
            return includeTitle ? "Fieldnote is recording \(latest.title)." : "Fieldnote is recording a meeting."
        case .queued, .transcribing, .diarizing, .summarising:
            var answer = "Fieldnote is still working on the notes for \(name)."
            if let finish = latest.estimatedCompletion, finish > now {
                let minutes = max(1, Int((finish.timeIntervalSince(now) / 60).rounded()))
                answer += minutes == 1 ? " About a minute left." : " About \(minutes) minutes left."
            }
            return answer
        case .complete:
            return "The notes for \(name) are ready."
        case .failed:
            return "Fieldnote couldn't finish the notes for \(name). Open the app to try again."
        }
    }

    /// Ends `text` with a full stop unless it already ends a sentence.
    static func sentence(_ text: String) -> String {
        guard let last = text.last, !".!?".contains(last) else { return text }
        return text + "."
    }

    static func capped(_ text: String) -> String {
        guard text.count > maxCharacters else { return text }
        let cut = text.prefix(maxCharacters)
        let atWord = cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut
        return atWord.trimmingCharacters(in: .punctuationCharacters.union(.whitespaces)) + "…"
    }
}

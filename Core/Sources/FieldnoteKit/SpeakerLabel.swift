import Foundation

/// How an unnamed speaker is shown to people: "Speaker A", "Speaker B", …
///
/// Diarization labels speakers "S1", "S2" in order of first appearance, and those
/// stay the stored IDs. This is display only: every screen, export and prompt shows
/// the letter form unless the speaker has been given a name.
public enum SpeakerLabel {

    /// "S1" → "Speaker A", "S26" → "Speaker Z", "S27" → "Speaker AA". Anything that
    /// isn't an `S<number>` label is returned unchanged; nil is "Unknown".
    public static func display(_ id: String?) -> String {
        guard let id else { return "Unknown" }
        guard id.hasPrefix("S"), let number = Int(id.dropFirst()), number > 0 else { return id }
        return "Speaker \(letters(number))"
    }

    /// The name to show: the speaker's given name if there is one, else the letter form.
    public static func name(_ id: String?, names: [String: String]) -> String {
        guard let id else { return "Unknown" }
        return names[id] ?? display(id)
    }

    /// Spreadsheet-style column letters: 1 → A, 26 → Z, 27 → AA.
    static func letters(_ number: Int) -> String {
        var n = number
        var result = ""
        while n > 0 {
            let remainder = (n - 1) % 26
            result = String(UnicodeScalar(UInt8(65 + remainder))) + result
            n = (n - 1) / 26
        }
        return result
    }
}

extension SpeakerLabel {
    /// Puts given names into text the model wrote with letter labels: "Speaker A
    /// will send the deck" becomes "Priya will send the deck". Whole words only, so
    /// "Speaker A" never matches inside "Speaker AB". Labels without a given name
    /// (`names[label]` missing or still the letter form) are left as they are.
    public static func applyNames(_ names: [String: String], to text: String) -> String {
        var result = text
        // Longest letter forms first, so "Speaker AA" is replaced before "Speaker A".
        for (label, name) in names.sorted(by: { display($0.key).count > display($1.key).count }) {
            let letterForm = display(label)
            guard name != letterForm, letterForm != label,
                  let pattern = try? NSRegularExpression(pattern: "\\b" + NSRegularExpression.escapedPattern(for: letterForm) + "\\b")
            else { continue }
            let range = NSRange(result.startIndex..., in: result)
            result = pattern.stringByReplacingMatches(
                in: result, range: range, withTemplate: NSRegularExpression.escapedTemplate(for: name)
            )
        }
        return result
    }
}

extension MeetingSummary {
    /// The notes with the speakers' given names in place of "Speaker A" and so on,
    /// for showing and sharing. The stored notes keep the letter forms, so a later
    /// rename still applies.
    public func applyingSpeakerNames(_ names: [String: String]) -> MeetingSummary {
        let apply = { (text: String) in SpeakerLabel.applyNames(names, to: text) }
        var copy = self
        copy.overview = apply(overview)
        copy.topics = topics?.map { topic in
            var topic = topic
            topic.title = apply(topic.title)
            topic.summary = apply(topic.summary)
            topic.points = topic.points.map { point in
                var point = point
                point.text = apply(point.text)
                point.details = point.details.map(apply)
                return point
            }
            return topic
        }
        copy.decisions = decisions.map { var item = $0; item.statement = apply(item.statement); return item }
        copy.actionItems = actionItems.map { item in
            var item = item
            item.task = apply(item.task)
            item.owner = item.owner.map(apply)
            return item
        }
        copy.openQuestions = openQuestions.map { var item = $0; item.text = apply(item.text); return item }
        return copy
    }
}

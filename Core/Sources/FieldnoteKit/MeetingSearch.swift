import Foundation

/// How meetings are searched: what text is indexed and how a query is matched.
///
/// Text and queries are folded the same way (case, accents, curly quotes), and a
/// query matches when every word in it appears somewhere in the meeting, in any
/// order: "budget review" finds "we'll review the budget".
public enum MeetingSearch {

    /// Bump when `indexText` changes, so stored meetings are re-indexed once.
    /// 3: re-index once more, as notes written by processing could be missed (the
    /// index was built before the new summary was linked to its meeting).
    /// 5: only the title, place, speaker names and the list's notes (no transcript or
    /// full notes).
    /// 6: the client.
    public static let indexVersion = 6

    /// Lowercased, accents removed, typographic quotes made plain.
    public static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{2018}", with: "'")
            .replacingOccurrences(of: "\u{201C}", with: "\"")
            .replacingOccurrences(of: "\u{201D}", with: "\"")
            .lowercased()
    }

    /// The query's words, normalized, longest first (the most selective goes to the
    /// database; the rest are checked in memory).
    public static func terms(_ query: String) -> [String] {
        normalize(query)
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .filter { !$0.isEmpty }
            .sorted { $0.count > $1.count }
    }

    public static func matches(_ normalizedText: String, terms: [String]) -> Bool {
        terms.allSatisfy { normalizedText.contains($0) }
    }

    /// What the meeting list's search looks at: the title, the client, the place, the
    /// speakers' names, and the notes shown under each meeting in the list (the overview and
    /// the topics' headlines and one-line summaries). Not the transcript or the rest
    /// of the notes: those are searched with Find inside a meeting.
    public static func indexText(
        title: String,
        client: String? = nil,
        placeName: String?,
        speakerNames: [String],
        summary: MeetingSummary?
    ) -> String {
        var parts = [title]
        if let client, !client.isEmpty { parts.append(client) }
        if let placeName, !placeName.isEmpty { parts.append(placeName) }
        parts.append(contentsOf: speakerNames)
        if let summary {
            parts.append(summary.overview)
            for topic in summary.topics ?? [] {
                parts.append(topic.title)
                parts.append(topic.summary)
            }
        }
        return normalize(parts.joined(separator: "\n"))
    }
}

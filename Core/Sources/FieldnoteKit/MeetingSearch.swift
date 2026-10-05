import Foundation

/// How meetings are searched: what text is indexed, how a query is matched, and the
/// snippet shown for a match.
///
/// Text and queries are folded the same way (case, accents, curly quotes), and a
/// query matches when every word in it appears somewhere in the meeting, in any
/// order: "budget review" finds "we'll review the budget".
public enum MeetingSearch {

    /// Bump when `indexText` changes, so stored meetings are re-indexed once.
    /// 3: re-index once more, as notes written by processing could be missed (the
    /// index was built before the new summary was linked to its meeting).
    public static let indexVersion = 3

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

    /// Everything a search should find: title, place, speaker names, the transcript,
    /// and every part of the notes.
    public static func indexText(
        title: String,
        placeName: String?,
        speakerNames: [String],
        segments: [String],
        summary: MeetingSummary?
    ) -> String {
        var parts = [title]
        if let placeName, !placeName.isEmpty { parts.append(placeName) }
        parts.append(contentsOf: speakerNames)
        parts.append(contentsOf: segments)
        if let summary {
            parts.append(summary.overview)
            for topic in summary.topics ?? [] {
                parts.append(topic.title)
                parts.append(topic.summary)
                for point in topic.points {
                    parts.append(point.text)
                    parts.append(contentsOf: point.details)
                }
            }
            parts.append(contentsOf: summary.decisions.map(\.statement))
            parts.append(contentsOf: summary.actionItems.map(\.task))
            parts.append(contentsOf: summary.openQuestions.map(\.text))
        }
        return normalize(parts.joined(separator: "\n"))
    }

    /// Where a match was found, for the result row.
    public struct Snippet: Equatable, Sendable {
        /// The matching line, trimmed around the first match.
        public var text: String
        /// The transcript line it came from, when it came from the transcript.
        public var segmentID: UUID?
        public var start: TimeInterval?
    }

    /// The first line holding every term: a transcript line if one does, else a
    /// line of the notes. Nil when the match is only in the title or place.
    public static func snippet(in meeting: MeetingSnapshot, terms: [String], radius: Int = 60) -> Snippet? {
        guard !terms.isEmpty else { return nil }
        for segment in meeting.segments where matches(normalize(segment.text), terms: terms) {
            return Snippet(text: trim(segment.text, around: terms[0], radius: radius), segmentID: segment.id, start: segment.start)
        }
        guard let summary = meeting.summary else { return nil }
        var lines = [summary.overview]
        for topic in summary.topics ?? [] {
            lines.append(topic.title)
            lines.append(topic.summary)
            lines.append(contentsOf: topic.points.flatMap { [$0.text] + $0.details })
        }
        lines += summary.decisions.map(\.statement) + summary.actionItems.map(\.task) + summary.openQuestions.map(\.text)
        for line in lines where matches(normalize(line), terms: terms) {
            return Snippet(text: trim(line, around: terms[0], radius: radius), segmentID: nil, start: nil)
        }
        return nil
    }

    /// The text around the first match, with "…" where it was cut.
    static func trim(_ text: String, around term: String, radius: Int) -> String {
        let folded = normalize(text)
        // Folding can change lengths (rare: ligatures); fall back to the start.
        guard folded.count == text.count, let range = folded.range(of: term) else {
            return text.count > radius * 2 ? String(text.prefix(radius * 2)) + "…" : text
        }
        let offset = folded.distance(from: folded.startIndex, to: range.lowerBound)
        let from = max(0, offset - radius)
        let to = min(text.count, offset + term.count + radius)
        let start = text.index(text.startIndex, offsetBy: from)
        let end = text.index(text.startIndex, offsetBy: to)
        return (from > 0 ? "…" : "") + text[start..<end].trimmingCharacters(in: .whitespaces) + (to < text.count ? "…" : "")
    }
}

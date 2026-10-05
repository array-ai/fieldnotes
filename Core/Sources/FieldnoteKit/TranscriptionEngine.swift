import Foundation

/// Which speech model writes the transcript after a recording stops.
///
/// Apple's model always produces the live transcript while recording. With Parakeet
/// selected (an optional download), the transcript is redone after stop with NVIDIA's
/// Parakeet TDT v3, which is generally more accurate on meetings; the live text is
/// what you see until then.
public enum TranscriptionEngine: String, Codable, CaseIterable, Sendable {
    case apple
    case parakeet

    public static let defaultsKey = "transcriptionEngine"

    public init(storedValue: String?) {
        self = storedValue.flatMap(TranscriptionEngine.init(rawValue:)) ?? .apple
    }

    public var displayName: String {
        switch self {
        case .apple: "Apple (built in)"
        case .parakeet: "Parakeet v3 (NVIDIA)"
        }
    }

    /// Languages Parakeet v3 handles (its language hint values, BCP-47 primary tags).
    public static let parakeetLanguages: Set<String> = [
        "en", "es", "fr", "de", "it", "pt", "ro", "nl", "da", "sv", "fi", "hu", "et", "lv",
        "lt", "mt", "pl", "cs", "sk", "sl", "hr", "bs", "ru", "uk", "be", "bg", "sr", "el",
    ]

    /// Whether Parakeet can transcribe a locale; Apple's model is used otherwise.
    public static func parakeetSupports(_ localeIdentifier: String) -> Bool {
        let language = localeIdentifier.split(whereSeparator: { $0 == "_" || $0 == "-" }).first.map(String.init) ?? ""
        return parakeetLanguages.contains(language.lowercased())
    }
}

/// Groups timed words into transcript lines, for speech models (Parakeet) that return
/// one long run of words rather than Apple's sentence-like results.
///
/// A line ends at sentence punctuation once it has a few words, at a pause, or at a
/// maximum length — short enough to read and to cite, long enough to carry a thought.
public enum WordLines {

    public static func lines(
        from words: [TranscriptWord],
        pause: TimeInterval = 0.8,
        maxWords: Int = 40,
        minWordsBeforeSentenceBreak: Int = 4
    ) -> [TranscriptSegment] {
        var lines: [TranscriptSegment] = []
        var current: [TranscriptWord] = []

        func flush() {
            guard let first = current.first, let last = current.last else { return }
            let text = current.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                lines.append(TranscriptSegment(start: first.start, end: last.end, text: text, words: current))
            }
            current = []
        }

        for word in words {
            if let last = current.last, word.start - last.end > pause { flush() }
            current.append(word)
            let ending = word.text.trimmingCharacters(in: .whitespaces)
            let endsSentence = ending.hasSuffix(".") || ending.hasSuffix("?") || ending.hasSuffix("!")
            if (endsSentence && current.count >= minWordsBeforeSentenceBreak) || current.count >= maxWords {
                flush()
            }
        }
        flush()
        return lines
    }
}

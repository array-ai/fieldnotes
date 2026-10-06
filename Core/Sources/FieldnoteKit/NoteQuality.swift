import Foundation

/// Keeps transcript fragments out of the notes.
///
/// Read off a real 68-minute meeting summarised by Apple's model: of 40 "open
/// questions" most were fragments copied from the transcript ("VendorC.", "Sorry.
/// Back up.", "So if you're using..."), the same question appeared three times in
/// slightly different words, decisions included "I agree as well.", and tasks had
/// owners like "None" and "Unassigned". These rules apply to every model.
public enum NoteQuality {

    /// A question someone actually asked: a question mark, or a question word up
    /// front, and enough words to stand on its own. Not a cut-off line.
    public static func isQuestion(_ text: String) -> Bool {
        let words = self.words(text)
        guard words.count >= 4, !isCutOff(text) else { return false }
        if text.contains("?") { return true }
        return questionWords.contains(words[0])
    }

    /// A decision is a statement of what was agreed, not a reaction ("I agree as
    /// well.") or a fragment.
    public static func isDecision(_ text: String) -> Bool {
        let words = self.words(text)
        guard words.count >= 2, !isCutOff(text), !text.trimmed().hasSuffix("?") else { return false }
        return !["i", "i'm", "i'd", "i've", "yeah", "yes", "okay", "ok", "so", "um", "uh"].contains(words[0])
    }

    /// A task needs a verb and an object at least: three words.
    public static func isTask(_ text: String) -> Bool {
        words(text).count >= 3 && !isCutOff(text)
    }

    /// An owner, or nil for the placeholders models write when there isn't one.
    public static func owner(_ text: String) -> String? {
        let owner = text.trimmed()
        let placeholders: Set<String> = [
            "", "none", "unknown", "unassigned", "n/a", "na", "nobody", "no one", "tbd", "-", "everyone", "all",
        ]
        return placeholders.contains(owner.lowercased()) ? nil : owner
    }

    /// False when the text says nearly the same as one already kept (most of the
    /// words shared); otherwise remembers it and returns true.
    public static func isNew(_ text: String, among seen: inout [Set<String>]) -> Bool {
        let key = Set(words(text))
        guard !key.isEmpty else { return false }
        for earlier in seen {
            let shared = Double(key.intersection(earlier).count)
            let union = Double(key.union(earlier).count)
            if shared / union >= 0.7 { return false }
        }
        seen.append(key)
        return true
    }

    // MARK: -

    static let questionWords: Set<String> = [
        "what", "how", "why", "who", "whom", "whose", "when", "where", "which",
        "is", "are", "was", "were", "can", "could", "do", "does", "did",
        "should", "will", "would", "have", "has",
    ]

    /// Lower-cased words, apostrophes kept ("don't").
    static func words(_ text: String) -> [String] {
        text.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'")).inverted)
            .filter { !$0.isEmpty }
    }

    /// "So if you're using..." – a line cut off mid-thought.
    static func isCutOff(_ text: String) -> Bool {
        let trimmed = text.trimmed()
        return trimmed.hasSuffix("...") || trimmed.hasSuffix("…") || trimmed.hasSuffix(",")
    }
}

extension NoteQuality {
    /// A line with nothing to summarise: a few words that are all filler ("Okay.",
    /// "Yeah, yeah.", "Morning.", "Give us a second."). Dropping these before the
    /// notes model sees the transcript leaves less to copy and shorter prompts.
    public static func isFiller(_ text: String) -> Bool {
        let words = self.words(text)
        guard !words.isEmpty else { return true }
        guard words.count <= 6 else { return false }
        return words.allSatisfy { fillerWords.contains($0) }
    }

    static let fillerWords: Set<String> = [
        "ok", "okay", "yeah", "yep", "yes", "no", "nope", "um", "uh", "ah", "oh", "hmm", "mm",
        "right", "sure", "cool", "great", "nice", "good", "fine", "alright", "so", "and", "but",
        "well", "like", "just", "thanks", "thank", "you", "cheers", "hi", "hello", "hey",
        "morning", "afternoon", "bye", "see", "ya", "a", "the", "it", "is", "that", "i", "we",
        "us", "give", "second", "sec", "moment", "one", "sorry", "pardon", "exactly", "true",
        "correct", "agreed", "indeed", "totally", "absolutely", "got", "makes", "sense",
    ]
}

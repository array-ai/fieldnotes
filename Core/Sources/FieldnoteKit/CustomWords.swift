import Foundation

/// Words the speech models should know: product names, people, places. The user's
/// own list (Settings → Transcription → Custom words) extends the built-in one.
///
/// Apple's model takes them as contextual strings. Parakeet can't be told words in
/// advance, so after it has written the transcript a small CTC model listens to the
/// audio again and swaps a word only when the sound supports the custom one
/// ("Grafina" → "Grafana").
public enum CustomWords {

    public static let defaultsKey = "customWords"

    /// The user's list as typed: one word or name per line or comma. Blank entries
    /// and repeats (ignoring case) are dropped; the first spelling wins.
    public static func parse(_ text: String) -> [String] {
        unique(text.split(whereSeparator: { $0 == "\n" || $0 == "," }).map(String.init))
    }

    /// The built-in words followed by the user's, without repeats (ignoring case).
    /// The user's spelling wins over a built-in one.
    public static func merged(user: [String], builtIn: [String]) -> [String] {
        let users = unique(user)
        let taken = Set(users.map { $0.lowercased() })
        return unique(builtIn).filter { !taken.contains($0.lowercased()) } + users
    }

    static func unique(_ words: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for word in words {
            let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted else { continue }
            out.append(trimmed)
        }
        return out
    }
}

/// Puts a corrected word sequence back onto the timed words it came from.
///
/// The word fixer returns plain text (words joined by spaces), not timings. The
/// unchanged words line up with the originals; each changed run takes the time span
/// of the words it replaced: "Data Dog" → "Datadog" spans both, and
/// "Hudu" → "Halo PSA" splits the one word's span in two.
public enum WordRevision {

    public static func apply(_ revised: [String], to words: [TranscriptWord]) -> [TranscriptWord] {
        let old = words.map { key($0.text) }
        let new = revised.map { key($0) }
        guard old != new else { return words }

        // Longest common subsequence, by the words' letters and digits.
        let n = old.count, m = new.count
        var table = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                table[i][j] = old[i] == new[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }

        var out: [TranscriptWord] = []
        var i = 0, j = 0
        var pendingOld: [TranscriptWord] = []
        var pendingNew: [String] = []

        func flush() {
            defer { pendingOld = []; pendingNew = [] }
            guard !pendingNew.isEmpty else { return }  // Words dropped: nothing to place.
            guard let first = pendingOld.first, let last = pendingOld.last else {
                // Inserted with nothing replaced: a zero-length word at the previous end.
                let at = out.last?.end ?? words.first?.start ?? 0
                out += pendingNew.map { TranscriptWord(text: $0 + " ", start: at, end: at) }
                return
            }
            let step = (last.end - first.start) / Double(pendingNew.count)
            let trailing = String(last.text.trimmingCharacters(in: .whitespaces).reversed()
                .prefix { $0.isPunctuation }.reversed())
            for (index, word) in pendingNew.enumerated() {
                let start = first.start + step * Double(index)
                let isLast = index == pendingNew.count - 1
                // The model's punctuation after the replaced words stays.
                let text = isLast && word.last?.isPunctuation != true ? word + trailing : word
                out.append(TranscriptWord(text: text + " ", start: start, end: isLast ? last.end : start + step))
            }
        }

        while i < n || j < m {
            if i < n, j < m, old[i] == new[j] {
                flush()
                out.append(words[i])
                i += 1; j += 1
            } else if j < m, i == n || table[i][j + 1] >= table[i + 1][j] {
                pendingNew.append(revised[j]); j += 1
            } else {
                pendingOld.append(words[i]); i += 1
            }
        }
        flush()
        return out
    }

    /// How words are compared: letters and digits, ignoring case and punctuation.
    static func key(_ word: String) -> String {
        String(word.lowercased().filter { $0.isLetter || $0.isNumber })
    }
}

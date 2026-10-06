import Foundation

/// The optional clean-up step (Settings → Custom words): the notes model reads the
/// lines that hold something close to a custom word and says which ones mean it.
/// Unlike the word checker it judges by context, so a real word can be fixed too:
/// "sync row" in a line about tickets becomes Syncro, "the team" stays a team.
///
/// Only those lines go to the model, and it answers with short fix lines, not the
/// transcript rewritten: a 68-minute meeting has ~900 lines and rewriting them all
/// would take a small model longer than the notes.
public enum TranscriptCleanup {

    public static let defaultsKey = "cleanUpCustomWords"

    public static let instructions = """
        You fix misheard product and company names in a meeting transcript. \
        Change a word only when the line clearly means one of the custom words.
        """

    // MARK: - Which lines to ask about

    /// Indices of segments with a word, or a run of up to three, that may be a
    /// misheard custom word. Edited lines are left alone. `isWord` is the system
    /// dictionary; without one, every word counts as real.
    public static func candidates(
        _ segments: [TranscriptSegment],
        terms: [String],
        isWord: (String) -> Bool = { _ in true }
    ) -> [Int] {
        let keys = searchKeys(terms)
        return segments.indices.filter { index in
            let segment = segments[index]
            guard !segment.editedByUser else { return false }
            return !nearMatches(in: segment.text, keys: keys, isWord: isWord).isEmpty
        }
    }

    static func searchKeys(_ terms: [String]) -> [String] {
        terms.map(WordRevision.key).filter { $0.count >= 4 }
    }

    /// The custom words a line may hold misheard. Loose matching flagged 785 of a
    /// 68-minute meeting's 939 lines ("have" for HPE, "okay" for Okta), so a run
    /// counts only when it is:
    /// - the custom word split up ("data dog" for Datadog),
    /// - near it (half the letters or more) with a word the dictionary doesn't know,
    /// - or all real words, but very near (0.7) and starting with the same letter.
    /// That flagged 157 lines.
    static func nearMatches(in text: String, keys: [String], isWord: (String) -> Bool) -> Set<String> {
        let words = text.split(separator: " ").map { WordRevision.key(String($0)) }.filter { !$0.isEmpty }
        var found = Set<String>()
        for start in words.indices {
            var run = ""
            for end in start..<min(start + 3, words.count) {
                run += words[end]
                let parts = words[start...end]
                let real = parts.allSatisfy(isWord)
                for key in keys where abs(key.count - run.count) <= 3 && !parts.contains(key) {
                    if key == run {
                        if parts.count > 1 { found.insert(key) }
                        continue
                    }
                    let close = similarity(run, key)
                    if real ? (key.count >= 5 && run.first == key.first && close >= 0.7) : close >= 0.5 {
                        found.insert(key)
                    }
                }
            }
        }
        return found
    }

    /// 1 for the same letters, 0 for nothing in common (edit distance over length).
    static func similarity(_ a: String, _ b: String) -> Double {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var row = Array(0...b.count)
        for i in 1...a.count {
            var previous = row[0]
            row[0] = i
            for j in 1...b.count {
                let current = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, previous + (a[i - 1] == b[j - 1] ? 0 : 1))
                previous = current
            }
        }
        return 1 - Double(row[b.count]) / Double(max(a.count, b.count))
    }

    // MARK: - Asking

    /// The custom words worth listing for these lines: the ones they come close to.
    public static func relevantTerms(
        _ lines: [String],
        terms: [String],
        isWord: (String) -> Bool = { _ in true }
    ) -> [String] {
        let keys = searchKeys(terms)
        let near = lines.reduce(into: Set<String>()) { $0.formUnion(nearMatches(in: $1, keys: keys, isWord: isWord)) }
        return terms.filter { near.contains(WordRevision.key($0)) }
    }

    /// `lines` are numbered as given (1-based within this prompt).
    public static func prompt(lines: [String], terms: [String]) -> String {
        """
        Custom words: \(terms.joined(separator: ", "))

        The speech model may have misheard these words, for example "sync row" for \
        "Syncro", or "who do" for "Hudu". For each line \
        where words clearly mean one of the custom words, write one fix:
        <line number> | <the words as written> | <custom word>
        Only fix a name the line is really about. Leave ordinary words alone. If \
        nothing needs fixing, write NONE.

        Lines:
        \(lines.enumerated().map { "[\($0.offset + 1)] \($0.element)" }.joined(separator: "\n"))
        """
    }

    // MARK: - Reading the answer

    public struct Fix: Equatable, Sendable {
        /// 1-based, within the prompt.
        public var line: Int
        public var heard: String
        public var term: String

        public init(line: Int, heard: String, term: String) {
            self.line = line
            self.heard = heard
            self.term = term
        }
    }

    /// Fix lines the answer gives, checked against the lines and the custom words:
    /// the words must be in that line and close to the custom word, so a model
    /// swapping in a product for an unrelated word changes nothing.
    public static func parse(_ answer: String, lines: [String], terms: [String]) -> [Fix] {
        var fixes: [Fix] = []
        for row in PlainNotes.withoutThinking(answer).split(separator: "\n") {
            let parts = row.split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "[]\"'`*-"))) }
            guard parts.count == 3, let number = Int(parts[0]), lines.indices.contains(number - 1),
                  let term = terms.first(where: { $0.caseInsensitiveCompare(parts[2]) == .orderedSame }),
                  !parts[1].isEmpty else { continue }
            let heard = parts[1]
            let heardKey = WordRevision.key(heard), termKey = WordRevision.key(term)
            // A respelling ("tail scale") is a fix too; otherwise the words must be near.
            guard heard != term, heardKey == termKey || similarity(heardKey, termKey) >= 0.4,
                  run(of: heard, in: lines[number - 1].split(separator: " ").map(String.init)) != nil else { continue }
            fixes.append(Fix(line: number, heard: heard, term: term))
        }
        return fixes
    }

    /// Where `heard` sits in a line's words, compared by letters.
    static func run(of heard: String, in words: [String]) -> Range<Int>? {
        let target = WordRevision.key(heard)
        guard !target.isEmpty else { return nil }
        for start in words.indices {
            var joined = ""
            for end in start..<words.count {
                joined += WordRevision.key(words[end])
                if joined == target { return start..<(end + 1) }
                if joined.count >= target.count { break }
            }
        }
        return nil
    }

    // MARK: - Applying

    /// The segment with the fix made, keeping word timings; nil if the words aren't
    /// there (any more).
    public static func apply(_ fix: Fix, to segment: TranscriptSegment) -> TranscriptSegment? {
        var segment = segment
        let termWords = fix.term.split(separator: " ").map(String.init)
        if let words = segment.words, !words.isEmpty {
            let texts = words.map { $0.text.trimmingCharacters(in: .whitespaces) }
            guard let range = run(of: fix.heard, in: texts) else { return nil }
            // Punctuation after the replaced words stays.
            let trailing = String(texts[range.upperBound - 1].reversed().prefix { $0.isPunctuation }.reversed())
            var revised = texts
            revised.replaceSubrange(range, with: termWords.dropLast() + [termWords.last! + trailing])
            let fixed = WordRevision.apply(revised, to: words)
            segment.words = fixed
            segment.text = fixed.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            let texts = segment.text.split(separator: " ").map(String.init)
            guard let range = run(of: fix.heard, in: texts) else { return nil }
            let trailing = String(texts[range.upperBound - 1].reversed().prefix { $0.isPunctuation }.reversed())
            var revised = texts
            revised.replaceSubrange(range, with: termWords.dropLast() + [termWords.last! + trailing])
            segment.text = revised.joined(separator: " ")
        }
        return segment
    }
}

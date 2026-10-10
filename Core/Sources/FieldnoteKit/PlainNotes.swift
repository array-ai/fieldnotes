import Foundation

/// A plain-text notes format for small local models (MiniCPM5 on Core AI).
///
/// Apple's model fills a structured schema reliably. A 1B model run through Core AI
/// didn't: it skipped required fields, copied transcript lines as "points" and cited
/// lines that don't exist (build 39 benchmark), so every claim failed grounding. Plain
/// labelled lines are what small models follow best, so they're asked for this:
///
/// ```
/// TOPIC: headline
/// - key point [12, 14]
/// DECISION: what was decided [18]
/// TASK: what to do | who | when [20]
/// QUESTION: open question [22]
/// NAME: the speaker's own name, from a self-introduction [3]
/// ```
///
/// and the parser is forgiving: any case, markdown around the labels, bullets of any
/// kind, citations as `[12]`, `(12-14)` or `line 12`. A point without a usable
/// citation is matched to the transcript line it shares the most words with; one
/// that matches none is dropped, as the grounder would drop it anyway.
public enum PlainNotes {

    /// Session instructions: the grounding rules, minus the structured-output wording.
    public static let instructions = """
        You write short meeting notes from a numbered transcript.
        Only write what was said. Copy names exactly. "Speaker A" is not a name.
        Put the line numbers each item comes from in square brackets.
        Skip greetings and small talk. QUESTION is only for questions nobody answered.
        """

    public static func prompt(chunk: TranscriptChunk, chunkIndex: Int, chunkCount: Int) -> String {
        let topics = PromptTemplates.topicLimit(forLines: chunk.segments.count)
        return """
            Transcript, part \(chunkIndex + 1) of \(chunkCount). Lines are "N | Speaker: text".

            \(chunk.promptText())

            Write notes on this transcript in exactly this format, using your own words:
            TOPIC: <three to seven word headline>
            - <one key point> [<line numbers>]
            - <another key point> [<line numbers>]
            DECISION: <what was decided> [<line numbers>]
            TASK: <what to do> | <who> | <when> [<line numbers>]
            QUESTION: <question left open> [<line numbers>]
            NAME: <the speaker's own name, when they introduce themselves> [<line number>]

            Write one TOPIC for each subject this part covers, at most \(topics), each with \
            every key point it has: up to six. Leave out any line type with nothing to report. \
            Don't copy lines; summarise them.
            """
    }

    /// The overview, from the notes so far.
    public static func overviewPrompt(points: [String], meetingTitle: String) -> String {
        """
        Notes from the meeting "\(meetingTitle)":
        \(points.map { "- \($0)" }.joined(separator: "\n"))

        Write one to three sentences summarising the whole meeting. Write only the sentences.
        """
    }

    /// Cleans a free-text overview: drops a leading label and surrounding quotes.
    /// The answer without a `<think>…</think>` block: Qwen3 can still open with an
    /// empty one when told not to think, or an unfinished one if cut off.
    static func withoutThinking(_ text: String) -> String {
        guard let open = text.range(of: "<think>") else { return text }
        guard let close = text.range(of: "</think>", range: open.upperBound..<text.endIndex) else {
            return String(text[..<open.lowerBound])
        }
        return String(text[..<open.lowerBound] + text[close.upperBound...])
    }

    public static func cleanOverview(_ text: String) -> String {
        var result = withoutThinking(text).trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = result.range(of: #"^[*#\s]*(overview|summary)[*\s]*[:\-][*\s]*"#, options: [.regularExpression, .caseInsensitive]) {
            result.removeSubrange(range)
        }
        return result.trimmingCharacters(in: CharacterSet(charactersIn: "\"“” \n"))
    }

    // MARK: - Parsing

    public static func parse(_ text: String, chunk: TranscriptChunk) -> ChunkNotes {
        let text = withoutThinking(text)
        var topics: [NoteTopic] = []
        var decisions: [NoteDecision] = []
        var actions: [NoteActionItem] = []
        var questions: [NoteClaim] = []
        var names: [NoteClaim] = []

        for rawLine in text.components(separatedBy: .newlines) {
            let line = stripMarkup(rawLine)
            guard !line.isEmpty else { continue }

            // "- Decision: …" under a topic is a decision, not a point (MiniCPM5 1B
            // wrote its decisions and tasks that way, build 44).
            let content = bullet(line) ?? line
            if let (label, rest) = labelled(content) ?? bracketLabelled(content) {
                let (body, cited) = citations(in: rest)
                switch label {
                case "point":
                    addPoint(rest)
                case "topic":
                    let title = body.trimmingCharacters(in: .whitespaces)
                    guard !title.isEmpty else { continue }
                    topics.append(NoteTopic(title: title))
                case "decision":
                    guard let lines = cite(cited, body, chunk), !body.isEmpty else { continue }
                    decisions.append(NoteDecision(statement: speakerLetters(body), sourceLines: lines))
                case "task", "action":
                    let parts = body.split(separator: "|", omittingEmptySubsequences: false)
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                    let task = parts.first ?? ""
                    guard !task.isEmpty, let lines = cite(cited, task, chunk) else { continue }
                    actions.append(NoteActionItem(
                        task: speakerLetters(task),
                        owner: parts.count > 1 ? speakerLetters(blankIfNone(parts[1])) : "",
                        dueDate: parts.count > 2 ? blankIfNone(parts[2]) : "",
                        sourceLines: lines
                    ))
                case "question":
                    guard let lines = cite(cited, body, chunk), !body.isEmpty else { continue }
                    questions.append(NoteClaim(text: speakerLetters(body), sourceLines: lines))
                case "name":
                    // A name must be cited where it was said: no guessing by overlap.
                    let lines = cited.filter(chunk.lineNumbers.contains)
                    guard !lines.isEmpty, isPlausibleName(body) else { continue }
                    names.append(NoteClaim(text: body, sourceLines: lines))
                default:
                    continue
                }
            } else if let pointText = bullet(line), !isAnswerLine(pointText) {
                addPoint(pointText)
            }
        }

        func addPoint(_ text: String) {
            let (body, cited) = citations(in: text)
            let point = speakerLetters(dropSpeakerPrefix(body))
            guard point.count > 2, let lines = cite(cited, point, chunk) else { return }
            if topics.isEmpty { topics.append(NoteTopic(title: "Discussion")) }
            guard !topics[topics.count - 1].points.contains(where: { $0.text == point }) else { return }
            topics[topics.count - 1].points.append(NotePoint(text: point, sourceLines: lines))
        }

        // A topic with no points has nothing to show; its headline alone isn't a note.
        topics.removeAll { $0.points.isEmpty }
        return ChunkNotes(
            topics: topics,
            points: topics.map { topic in "\(topic.title): \(topic.points.first?.text ?? "")" },
            decisions: decisions,
            actionItems: actions,
            openQuestions: questions,
            speakerNames: names
        )
    }

    /// "Answer: …" bullets: the model answering its own question, not a note.
    static func isAnswerLine(_ text: String) -> Bool {
        text.range(of: #"^\**\s*answer\s*\**\s*[:\-–]"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// "**TOPIC:** x", "### Task - x", "1. QUESTION: x" → ("topic", "x").
    static func labelled(_ line: String) -> (String, String)? {
        let pattern = #"^(topic|decision|task|action item|action|question|open question|name)s?\s*[:\-–]\s*(.*)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let labelRange = Range(match.range(at: 1), in: line),
              let restRange = Range(match.range(at: 2), in: line) else { return nil }
        var label = line[labelRange].lowercased()
        if label.hasSuffix("question") { label = "question" }
        if label.hasPrefix("action") { label = "action" }
        return (label, String(line[restRange]))
    }

    /// LFM2.5 1.2B's own format, the label in brackets: "[TOPIC] x", "[Decision] x",
    /// "[Key Point 1] x", "[Number 259] x", "[3] x" (build 57: all ten parts of a
    /// 68-minute meeting were written this way, and none parsed). Points come back
    /// labelled "point".
    static func bracketLabelled(_ line: String) -> (String, String)? {
        let pattern = #"^\[\s*(topic|decision|task|action item|action|question|open question|name|key\s*point(?:\s*\d+)?|point(?:\s*\d+)?|number\s*\d+|\d+)\s*\]\s*[:\-–]?\s*(.+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let labelRange = Range(match.range(at: 1), in: line),
              let restRange = Range(match.range(at: 2), in: line) else { return nil }
        var label = line[labelRange].lowercased()
        if label.hasSuffix("question") { label = "question" }
        if label.hasPrefix("action") { label = "action" }
        if label.contains("point") || label.hasPrefix("number") || label.first?.isNumber == true { label = "point" }
        return (label, String(line[restRange]))
    }

    /// The text of a bullet or numbered item, or nil if the line isn't one.
    static func bullet(_ line: String) -> String? {
        guard let range = line.range(of: #"^([-*•·]|\d+[.)])\s+"#, options: .regularExpression) else { return nil }
        return String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
    }

    /// Removes markdown emphasis and heading marks around a line.
    static func stripMarkup(_ line: String) -> String {
        var result = line.trimmingCharacters(in: .whitespaces)
        while result.hasPrefix("#") { result.removeFirst() }
        result = result.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "")
        return result.trimmingCharacters(in: .whitespaces)
    }

    /// Splits citations off an item: "[12, 14-16]", "(line 12)", "L12". Ranges are
    /// expanded up to ten lines.
    static func citations(in text: String) -> (String, [Int]) {
        var body = text
        var lines: [Int] = []
        let patterns = [
            // "[<1, 6>]": the prompt's "<line numbers>" placeholder, copied (MiniCPM5 2B).
            #"\[\s*<?\s*(?:lines?\s*|L)?([\-–0-9][0-9,\s\-–Ll]*)>?\s*\]"#,
            #"<\s*(?:lines?\s*|L)?([0-9][0-9,\s\-–Ll]*)>"#,
            #"\(\s*(?:lines?\s*|L)?([0-9][0-9,\s\-–Ll]*)\)"#,
            #"\b(?:lines?|L)\s*([0-9]+(?:\s*[-–,]\s*[0-9]+)*)"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let matches = regex.matches(in: body, range: NSRange(body.startIndex..., in: body)).reversed()
            for match in matches {
                guard let whole = Range(match.range, in: body), let inner = Range(match.range(at: 1), in: body) else { continue }
                lines += numbers(in: String(body[inner]))
                body.removeSubrange(whole)
            }
        }
        // Empty citations the model left: "[, , ]", "[]", "[<>]".
        body = body.replacingOccurrences(of: #"\[[\s,<>]*\]"#, with: "", options: .regularExpression)
        body = body.trimmingCharacters(in: CharacterSet(charactersIn: " .;,:–-")).trimmingCharacters(in: .whitespaces)
        return (body, Array(Set(lines)).sorted())
    }

    static func numbers(in text: String) -> [Int] {
        var result: [Int] = []
        let cleaned = text.replacingOccurrences(of: "L", with: "").replacingOccurrences(of: "l", with: "")
        for part in cleaned.split(whereSeparator: { $0 == "," || $0 == " " }) {
            // "-3": a negative number, not a range. Never a line.
            if part.hasPrefix("-") || part.hasPrefix("–") { continue }
            let bounds = part.split(whereSeparator: { $0 == "-" || $0 == "–" }).compactMap { Int($0) }
            if bounds.count == 2, bounds[0] <= bounds[1], bounds[1] - bounds[0] < 10 {
                result += Array(bounds[0]...bounds[1])
            } else if let first = bounds.first {
                result.append(first)
            }
        }
        return result
    }

    /// The item's citations that are lines of this chunk; failing that, the line it
    /// shares the most words with (at least two). Nil if nothing fits.
    static func cite(_ cited: [Int], _ text: String, _ chunk: TranscriptChunk) -> [Int]? {
        let valid = cited.filter(chunk.lineNumbers.contains)
        if !valid.isEmpty { return valid }
        return bestLine(for: text, in: chunk).map { [$0] }
    }

    static func bestLine(for text: String, in chunk: TranscriptChunk) -> Int? {
        let wanted = contentWords(text)
        guard !wanted.isEmpty else { return nil }
        var best: (line: Int, score: Int)?
        for (number, segment) in zip(chunk.lineNumbers, chunk.segments) {
            let score = wanted.intersection(contentWords(segment.text)).count
            if score >= 2, score > (best?.score ?? 0) { best = (number, score) }
        }
        return best?.line
    }

    static func contentWords(_ text: String) -> Set<String> {
        Set(
            text.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count > 3 }
        )
    }

    /// "Speaker A: we'll ship Friday" → "we'll ship Friday"; also the format's own
    /// labels echoed back ("Key point: …", "Point: …").
    static func dropSpeakerPrefix(_ text: String) -> String {
        var result = text
        for pattern in [#"^speaker\s+[A-Z0-9]+\s*:\s*"#, #"^(key\s+)?points?\s*[:\-–]\s*"#, #"^(note|summary)\s*:\s*"#] {
            if let range = result.range(of: pattern, options: [.regularExpression, .caseInsensitive]) {
                result = String(result[range.upperBound...])
            }
        }
        return result
    }

    /// "E" as an owner, "F asks about…": the model shortened "Speaker F". Put the
    /// label back, so the names given to speakers replace it like anywhere else.
    static func speakerLetters(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.range(of: #"^[A-Z]{1,2}$"#, options: .regularExpression) != nil {
            return "Speaker \(trimmed)"
        }
        let verbs = "asks|asked|explains|explained|confirms|confirmed|says|said|suggests|suggested|shows|showed|"
            + "mentions|mentioned|agrees|agreed|proposes|proposed|notes|noted|states|stated|wants|will|would|"
            + "offers|offered|describes|described|presents|presented|raises|raised|requests|requested|shares|shared|"
            + "demonstrates|demonstrated|recommends|recommended|questions|questioned|clarifies|clarified|and"
        guard let range = trimmed.range(of: "^([A-Z]{1,2}) (\(verbs))\\b", options: .regularExpression) else { return trimmed }
        let letter = trimmed[range].split(separator: " ").first.map(String.init) ?? ""
        return "Speaker \(letter)" + trimmed[trimmed.index(trimmed.startIndex, offsetBy: letter.count)...]
    }

    /// One person's name: up to four words, no lists or separators, not a label
    /// ("EDR team | E | C", "Sam, Chris" and "Speaker G" aren't).
    static func isPlausibleName(_ text: String) -> Bool {
        let name = text.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name.count <= 40, !isSpeakerLabel(name) else { return false }
        guard name.rangeOfCharacter(from: CharacterSet(charactersIn: "|,;/[]<>()0123456789")) == nil else { return false }
        let words = name.split(separator: " ")
        guard words.count <= 4, words.allSatisfy({ $0.first?.isUppercase == true }) else { return false }
        return !["team", "everyone", "speaker", "participants", "unknown"].contains { name.lowercased().contains($0) }
    }

    /// "Speaker A", "speaker 2": a label, not a name.
    static func isSpeakerLabel(_ text: String) -> Bool {
        text.range(of: #"^speaker\s+[A-Z0-9]+$"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func blankIfNone(_ text: String) -> String {
        ["none", "n/a", "-", "unknown", "nobody", "no one"].contains(text.lowercased()) ? "" : text
    }
}

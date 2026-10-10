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

    /// Instructions for the Markdown format (`NotesProfile.Format.markdown`).
    public static let markdownInstructions = """
        You write meeting notes from a numbered transcript.
        Only write what was said, in your own words. Copy names exactly.
        """

    /// For a model that won't follow the labels: ordinary Markdown notes, which
    /// LFM2.5 writes well when simply asked (it wrote TOPIC headlines with no points
    /// otherwise). Read by `parse` like the labelled format: headings become topics,
    /// bullets their points, and uncited points are matched to the line they repeat.
    public static func markdownPrompt(chunk: TranscriptChunk, chunkIndex: Int, chunkCount: Int) -> String {
        """
        Here is part \(chunkIndex + 1) of \(chunkCount) of a meeting transcript. Lines are "N | Speaker: text".

        \(chunk.promptText())

        Write concise meeting notes in Markdown: a ### heading for each main topic, with its key \
        points as bullets. Then ### Decisions, ### Action items (who will do what) and \
        ### Open questions, only if there are any. End each bullet with the transcript line \
        numbers it comes from, like [12, 15].
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
        // "[1] The meeting… [2] Users…": sentence numbers or line citations, which
        // MiniCPM5 2B and Qwen3.5 2B put in the overview (build 62).
        result = result.replacingOccurrences(of: #"\s*\[[\d,\s\-–]+\]"#, with: "", options: .regularExpression)
        // "1. The meeting…\n2. It was…": a numbered list instead of sentences
        // (MiniCPM5 1B, build 63). One paragraph.
        result = result.replacingOccurrences(of: #"(?m)^\s*\d+[.)]\s+"#, with: "", options: .regularExpression)
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
        // Markdown notes: which list a bullet belongs to, from the heading above it.
        var section = Section.topics

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
                    // "x | DECISION: y": a second line run into the first (MiniCPM5 2B).
                    let statement = body.components(separatedBy: "|").first?.trimmingCharacters(in: .whitespaces) ?? ""
                    guard !isNothing(statement), let lines = cite(cited, statement, chunk), !statement.isEmpty else { continue }
                    decisions.append(NoteDecision(statement: speakerLetters(statement), sourceLines: lines))
                case "task", "action":
                    let parts = body.split(separator: "|", omittingEmptySubsequences: false)
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                    let task = parts.first ?? ""
                    guard !task.isEmpty, !isNothing(task), let lines = cite(cited, task, chunk) else { continue }
                    actions.append(NoteActionItem(
                        task: speakerLetters(task),
                        owner: parts.count > 1 ? speakerLetters(blankIfNone(parts[1])) : "",
                        dueDate: parts.count > 2 ? blankIfNone(parts[2]) : "",
                        sourceLines: lines
                    ))
                case "question":
                    guard !isNothing(body), let lines = cite(cited, body, chunk), !body.isEmpty else { continue }
                    questions.append(NoteClaim(text: speakerLetters(body), sourceLines: lines))
                case "name":
                    // A name must be cited where it was said: no guessing by overlap.
                    let lines = cited.filter(chunk.lineNumbers.contains)
                    guard !lines.isEmpty, isPlausibleName(body) else { continue }
                    names.append(NoteClaim(text: body, sourceLines: lines))
                default:
                    continue
                }
            } else if let heading = markdownHeading(rawLine) {
                section = Section(heading: heading)
                if section == .topics { topics.append(NoteTopic(title: heading)) }
            } else if let pointText = bullet(line), !isAnswerLine(pointText), !isEchoedLine(pointText) {
                switch section {
                case .topics, .overview: addPoint(pointText)
                case .decisions: addDecision(pointText)
                case .actions: addAction(pointText)
                case .questions: addQuestion(pointText)
                case .ignored: continue
                }
            }
        }

        func addDecision(_ text: String) {
            let (body, cited) = citations(in: text)
            guard !body.isEmpty, !isNothing(body), let lines = cite(cited, body, chunk) else { return }
            decisions.append(NoteDecision(statement: speakerLetters(body), sourceLines: lines))
        }

        /// "Rod: send the quote", "Send the quote (Rod)", or just the task.
        func addAction(_ text: String) {
            let (body, cited) = citations(in: text)
            var task = body, owner = ""
            if let colon = body.firstIndex(of: ":"), body[..<colon].split(separator: " ").count <= 3 {
                owner = String(body[..<colon]).trimmingCharacters(in: .whitespaces)
                task = String(body[body.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            } else if let range = body.range(of: #"\s*\(([^()]{1,40})\)$"#, options: .regularExpression) {
                owner = String(body[range]).trimmingCharacters(in: CharacterSet(charactersIn: " ()"))
                task = String(body[..<range.lowerBound])
            }
            guard !task.isEmpty, let lines = cite(cited, task, chunk) else { return }
            actions.append(NoteActionItem(task: speakerLetters(task), owner: speakerLetters(blankIfNone(owner)), dueDate: "", sourceLines: lines))
        }

        func addQuestion(_ text: String) {
            let (body, cited) = citations(in: text)
            guard !body.isEmpty, !isNothing(body), let lines = cite(cited, body, chunk) else { return }
            questions.append(NoteClaim(text: speakerLetters(body), sourceLines: lines))
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

    /// "No decisions were made in this part", "None": the model saying there's
    /// nothing, not an item (MiniCPM5 2B, build 63).
    static func isNothing(_ text: String) -> Bool {
        let t = text.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: " .:-–"))
        if ["none", "n/a", "nothing", "no", "none mentioned", "none noted"].contains(t) { return true }
        return t.range(of: #"^(no|none|nothing|there (were|was|are|is) no)\b.{0,40}\b(decisions?|tasks?|action items?|questions?)\b.{0,40}(made|given|raised|assigned|mentioned|discussed|noted|identified|in this part|here|yet)?\.?$"#, options: .regularExpression) != nil
            && t.count < 80
    }

    /// "64 | Speaker A: printer people": a transcript line copied back as it was
    /// sent, not a note.
    static func isEchoedLine(_ text: String) -> Bool {
        text.range(of: #"^\d+\s*\|\s*(Speaker [A-Z]+|[A-Z][\w'’.-]*)( [A-Z][\w'’.-]*)?\s*:"#, options: .regularExpression) != nil
    }

    /// Where a Markdown heading puts the bullets under it.
    enum Section: Equatable {
        case topics, overview, decisions, actions, questions, ignored

        init(heading: String) {
            let h = heading.lowercased()
            func has(_ pattern: String) -> Bool { h.range(of: pattern, options: .regularExpression) != nil }
            // Anywhere in the heading: "Key Decisions", "Action items and owners".
            if has(#"\b(action items?|actions|tasks?|next steps|to-?dos?|follow[- ]ups?)\b"#) { self = .actions }
            else if has(#"\bdecisions?\b"#) { self = .decisions }
            else if has(#"\b(open )?questions?\b"#) { self = .questions }
            else if has(#"^(participants|attendees|date|time|location|agenda)\b"#) { self = .ignored }
            // A heading over the whole answer, not a topic: its bullets still count.
            else if has(#"^(meeting (notes|summary|overview|headings|topics)|headings|notes|summary|overview|key (topics|points)|main topics|discussion points|summary of key topics)\b"#) || has(#"part \d+ of \d+"#) { self = .overview }
            else { self = .topics }
        }
    }

    /// The text of a Markdown heading ("### Backups", "**Backups**", "2. **Backups:**"),
    /// or nil. A bold label followed by text ("**TOPIC:** x") isn't one.
    static func markdownHeading(_ rawLine: String) -> String? {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        let patterns = [#"^(?:#{1,6}\s+)+(.+)$"#, #"^(?:\d+[.)]\s+)?\*\*([^*]+)\*\*:?$"#]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let range = Range(match.range(at: 1), in: line) else { continue }
            let title = String(line[range])
                .replacingOccurrences(of: "**", with: "")
                .replacingOccurrences(of: #"\s*\[[^\]]*\]\s*$"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet(charactersIn: " :"))
            return title.isEmpty ? nil : title
        }
        return nil
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
        // Empty citations the model left: "[, , ]", "[]", "[<>]", and the prompt's
        // placeholder copied as is: "[<line numbers>]" (Qwen3.5 2B).
        body = body.replacingOccurrences(of: #"\[[\s,<>]*\]"#, with: "", options: .regularExpression)
        body = body.replacingOccurrences(of: #"\[\s*<[^\]]*>\s*\]"#, with: "", options: .regularExpression)
        // Other debris small models leave: a line range after a bar ("| 1-33"),
        // HTML comments ("<!-- 247, 248 -->") and stray citation pieces (", , ]").
        body = body.replacingOccurrences(of: #"\s*\|\s*\d+\s*[-–]\s*\d+(?=\s*$)"#, with: "", options: .regularExpression)
        body = body.replacingOccurrences(of: #"<!--.*?-->"#, with: "", options: .regularExpression)
        body = body.replacingOccurrences(of: #"(\s*,)+\s*\]"#, with: "", options: .regularExpression)
        body = body.replacingOccurrences(of: #"(\s*,\s*\d+)+\s*$"#, with: "", options: .regularExpression)
        // Who said it, in brackets: "[Dan]", "[Speaker A]" (LFM2.5 1.2B, build 62).
        // The citation already says who; the tag only clutters the point.
        body = body.replacingOccurrences(
            of: #"\s*\[(?:Speaker\s+)?[A-Z][A-Za-z.'’\-]*(?:\s+[A-Z][A-Za-z.'’\-]*){0,2}\]"#,
            with: "",
            options: .regularExpression
        )
        // "point | [9:23]": the separator left behind once the citation is gone.
        body = body.trimmingCharacters(in: CharacterSet(charactersIn: " .;,:–-|")).trimmingCharacters(in: .whitespaces)
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
        // "Ongoing" as a due date (MiniCPM5 2B, build 62) says there isn't one.
        ["none", "n/a", "na", "-", "unknown", "nobody", "no one", "ongoing", "not specified", "unspecified", "not mentioned"]
            .contains(text.lowercased()) ? "" : text
    }
}

import Foundation

/// The prompts that turn a transcript into minutes and notes. One set for every
/// meeting: there are no per-type templates.
///
/// Prompt edits are code changes with no compiler. Re-run a fixed set of real
/// recordings after every change here and read the output yourself.
public enum PromptTemplates {

    /// The rules that keep output honest.
    public static let groundingRules = """
        Rules:
        - Only what was said. No inference or advice.
        - Cite line numbers for every item; leave out what you can't cite.
        - Copy names exactly as written.
        - Don't describe people.
        - Labels like "Speaker A" are not names.
        - Nothing of substance: return empty lists.
        """

    /// Session instructions for every summarisation call, with the built-in prompt.
    public static let instructions = SummaryPrompt.builtIn.instructions

    /// The map-phase prompt. One chunk of numbered transcript in, structured notes out.
    public static func chunkPrompt(
        chunk: TranscriptChunk,
        chunkIndex: Int,
        chunkCount: Int,
        request: String = SummaryPrompt.builtIn.request
    ) -> String {
        """
        Meeting transcript, part \(chunkIndex + 1) of \(chunkCount). Lines are \
        "N | Speaker: text".

        \(request) \(topicLimitSentence(forLines: chunk.segments.count))

        Transcript:
        \(chunk.promptText())
        """
    }

    /// Short excerpts get fewer topics: asking a few lines for three topics invites
    /// padding, and every extra topic costs answer tokens.
    public static func topicLimit(forLines lines: Int) -> Int {
        switch lines {
        case ..<15: 1
        case ..<40: 2
        default: 3
        }
    }

    static func topicLimitSentence(forLines lines: Int) -> String {
        let limit = topicLimit(forLines: lines)
        return limit == 1 ? "Use one topic." : "Use at most \(limit) topics."
    }

    /// The shorter, neutral retry after a guardrail trip or a refusal. Same excerpt,
    /// less framing, no words that read as loaded. Better a thin section than a
    /// silently missing one.
    public static func neutralChunkPrompt(chunk: TranscriptChunk, chunkIndex: Int, chunkCount: Int) -> String {
        """
        Excerpt \(chunkIndex + 1) of \(chunkCount) from a work meeting transcript. \
        Lines are numbered.

        List the topics covered, any tasks people agreed to do, and any questions left \
        open. Cite line numbers. Report only what is written.

        Transcript:
        \(chunk.promptText())
        """
    }

    /// The final pass: overview plus grouping of the excerpt topics into sections.
    /// Sees topic titles and summaries only, numbered so the model can refer to them.
    public static func outlinePrompt(topics: [(title: String, summary: String)], meetingTitle: String) -> String {
        """
        Below are the topics found in consecutive excerpts of one meeting titled \
        "\(meetingTitle)". The same subject can appear in several excerpts.

        Write an overview of the whole meeting, then group the numbered topics into \
        the meeting's main sections. Use only what is written below.

        Topics:
        \(topics.enumerated().map { "\($0.offset + 1). \($0.element.title) — \($0.element.summary)" }.joined(separator: "\n"))
        """
    }

    /// The reduce phase. Runs over chunk notes, never over raw transcript.
    public static func rollupPrompt(points: [String], meetingTitle: String) -> String {
        """
        Below are notes taken from consecutive excerpts of one meeting titled \
        "\(meetingTitle)".

        Write an overview of the meeting as a whole, using only what is in the notes \
        below. State what was discussed and what came of it. If the notes are thin, a \
        short one- or two-sentence overview is correct — do not pad it out. Do not \
        open with "In this meeting" or similar. Do not add anything the notes do not \
        contain.

        Notes:
        \(points.map { "- \($0)" }.joined(separator: "\n"))
        """
    }
}

/// How many tokens one prompt may spend on transcript, given the model's context.
///
/// Everything sent to the model shares one context window: the session
/// instructions, the output schema (included in the prompt), the prompt framing, the
/// transcript, and the response being generated. Pure arithmetic so it is tested off
/// device; the numbers come from the framework's own token counter.
public struct PromptBudget: Sendable, Equatable {
    public var contextSize: Int
    /// Session instructions + output schema: the cost of every call before the
    /// prompt itself.
    public var fixedCost: Int
    /// Room left for the model's answer.
    public var outputReserve: Int
    /// Whether the numbers came from the framework or are a fallback guess.
    public var isMeasured: Bool

    /// Used when the framework can't be asked. Sized for a 4,096-token context.
    public static let fallback = PromptBudget(contextSize: 4_096, fixedCost: 1_300, outputReserve: 1_800, isMeasured: false)

    public init(contextSize: Int, fixedCost: Int, outputReserve: Int, isMeasured: Bool) {
        self.contextSize = contextSize
        self.fixedCost = fixedCost
        self.outputReserve = outputReserve
        self.isMeasured = isMeasured
    }

    /// The most a full prompt (framing + transcript) may cost, before instructions,
    /// schema and the answer.
    public var promptLimit: Int {
        max(256, contextSize - fixedCost - outputReserve)
    }

    /// The target for the chunker's transcript text, which it counts approximately:
    /// a margin under `promptLimit` leaves room for the prompt framing and the
    /// estimate's error, so most chunks fit first time. Chunks that still don't are
    /// caught by an exact count before sending, and split.
    public var chunkBudget: Int {
        max(256, Int(Double(promptLimit) * 0.8))
    }

    public var overlap: Int { chunkBudget / 10 }

    /// Whether a prompt that costs `promptTokens` (framing + transcript) fits.
    public func fits(promptTokens: Int) -> Bool {
        promptTokens <= promptLimit
    }
}

/// The editable part of the summary prompt (debug mode). Two pieces:
///
/// - `preamble`: the session instructions — who the model is and what it's for.
/// - `request`: what to pull out of each excerpt of transcript.
///
/// `PromptTemplates.groundingRules` is always appended to the instructions and can't
/// be edited away: citing line numbers is how points get timestamps, and how made-up
/// points are caught and dropped.
public struct SummaryPrompt: Codable, Sendable, Equatable {
    public var preamble: String
    public var request: String

    public init(preamble: String, request: String) {
        self.preamble = preamble
        self.request = request
    }

    public static let builtIn = SummaryPrompt(
        preamble: "You write meeting notes.",
        request: "List topics with key points, plus decisions, tasks and open questions."
    )

    public var isBuiltIn: Bool { self == .builtIn }

    /// The session instructions actually sent: the preamble, then the rules.
    public var instructions: String {
        let preamble = self.preamble.trimmed().nilIfEmpty ?? Self.builtIn.preamble
        return "\(preamble)\n\n\(PromptTemplates.groundingRules)"
    }

    /// The request actually sent, falling back to the built-in one if left empty.
    public var effectiveRequest: String {
        request.trimmed().nilIfEmpty ?? Self.builtIn.request
    }
}

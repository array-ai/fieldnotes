import Foundation

/// The prompts that turn a transcript into minutes and notes. One set for every
/// meeting: there are no per-type templates.
///
/// Prompt edits are code changes with no compiler. Re-run a fixed set of real
/// recordings after every change here and read the output yourself.
public enum PromptTemplates {

    /// The rules that keep output honest.
    public static let groundingRules = """
        Rules that always apply:
        - Report only what was said. Do not infer, do not fill gaps, do not add advice.
        - Every decision, action and open question must cite the line numbers it came \
        from. A point you cannot cite must be left out.
        - Copy names of people, products and places exactly as they appear, even when \
        they look misspelt. They were transcribed from speech and the spelling is the \
        user's to fix.
        - Do not describe people. No traits, no tone, no judgements about anyone.
        - Speaker labels (like "Speaker A" or "Unknown") are line formatting, not something \
        anyone said. Never report one as a name or a point of its own.
        - If the excerpt contains nothing of substance, return empty lists rather than \
        padding with detail the transcript does not contain.
        """

    /// Session instructions for every summarisation call.
    public static let instructions = """
        You write minutes and notes from a recorded meeting.

        \(groundingRules)
        """

    /// The map-phase prompt. One chunk of numbered transcript in, structured notes out.
    public static func chunkPrompt(chunk: TranscriptChunk, chunkIndex: Int, chunkCount: Int) -> String {
        """
        Excerpt \(chunkIndex + 1) of \(chunkCount) from a meeting transcript. Each \
        line is numbered and prefixed with the speaker label, as "N | Speaker: text". \
        Cite these line numbers.

        Pull out what was discussed, decisions made, tasks people agreed to do, and \
        questions left open.

        Transcript:
        \(chunk.promptText())
        """
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
    public static let fallback = PromptBudget(contextSize: 4_096, fixedCost: 1_200, outputReserve: 1_024, isMeasured: false)

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

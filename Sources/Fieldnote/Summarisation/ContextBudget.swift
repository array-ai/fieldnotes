import FieldnoteKit
import Foundation
import FoundationModels

/// How many transcript tokens fit in one prompt on *this* device.
///
/// The ceiling differs by hardware, and iOS 26.4 / 27 expose the APIs to ask rather
/// than guess (spec 4.5). Hardcoding a budget means either wasting context on a
/// capable phone or overflowing on a modest one, and overflow shows up as a summary
/// section that silently went missing.
public struct ContextBudget: Sendable {
    /// Tokens available for transcript text in a chunk prompt.
    public var chunkBudget: Int
    /// Tokens of trailing context repeated at the head of the next chunk.
    public var overlap: Int
    /// Whether the numbers came from the framework or from the fallback below.
    public var isMeasured: Bool

    /// Used when the framework cannot be asked. Deliberately conservative: a chunk
    /// that fits is worth more than a chunk that uses every last token.
    public static let fallback = ContextBudget(chunkBudget: 2_800, overlap: 280, isMeasured: false)

    public init(chunkBudget: Int, overlap: Int, isMeasured: Bool) {
        self.chunkBudget = max(256, chunkBudget)
        self.overlap = max(0, overlap)
        self.isMeasured = isMeasured
    }

    /// SPEC-API — the one place the context-size and token-count APIs are called.
    ///
    /// Fill in the measured branch against the Xcode 27 SDK: read the session's
    /// context size, subtract the instruction tokens and a reserve for the structured
    /// output, and give the rest to the transcript. If the call fails or is
    /// unavailable, the fallback above applies and `isMeasured` records that it did.
    public static func measure(
        session: LanguageModelSession,
        instructions: String,
        outputReserve: Int = 900
    ) -> ContextBudget {
        guard let contextSize = contextWindowSize(of: session) else { return .fallback }
        let instructionCost = tokenCount(of: instructions, session: session)
            ?? TranscriptChunker.approximateTokenCount(instructions)
        let available = contextSize - instructionCost - outputReserve
        guard available > 512 else { return .fallback }
        return ContextBudget(
            chunkBudget: available,
            overlap: max(200, available / 10),
            isMeasured: true
        )
    }

    /// Returns nil until wired to the SDK symbol, which puts every caller on the
    /// documented fallback rather than on a wrong guess.
    private static func contextWindowSize(of session: LanguageModelSession) -> Int? {
        _ = session
        return nil
    }

    private static func tokenCount(of text: String, session: LanguageModelSession) -> Int? {
        _ = (text, session)
        return nil
    }

    /// The counter handed to `TranscriptChunker`. Uses the framework's tokeniser when
    /// available, the 4-characters-per-token approximation otherwise.
    public func tokenCounter(session: LanguageModelSession) -> @Sendable (String) -> Int {
        TranscriptChunker.approximateTokenCount
    }
}

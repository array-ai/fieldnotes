import FieldnoteKit
import Foundation
import FoundationModels
import OSLog

/// Map-reduce summarisation over a finished transcript.
///
/// Map: each chunk gets its own session. A single continuous session would carry
/// every previous chunk in its transcript and walk into the context ceiling around
/// the point a meeting gets long enough to need summarising.
///
/// Reduce: one pass over the chunk notes, never over raw transcript.
///
/// # Fitting the context
///
/// Instructions, the output schema, the prompt and the answer all share one context
/// window (4,096 tokens on current hardware). The budget is measured with the model's
/// own tokenizer, and every prompt is counted exactly before it is sent: one that
/// doesn't fit is split in half rather than sent to fail.
public actor SummarizationService {

    public struct MeetingContext: Sendable {
        public var id: UUID
        public var title: String
        public var date: Date

        public init(id: UUID, title: String, date: Date) {
            self.id = id
            self.title = title
            self.date = date
        }
    }

    private let log = Logger(subsystem: "com.publicarray.fieldnotes", category: "summarisation")
    private let debug = DebugLog.shared
    private let tier = ModelTier.coreAdvanced
    /// Splits per chunk before giving up: 2^4 = 16 pieces.
    private let maxSplitDepth = 4

    public init() {}

    /// - Parameter progress: called with 0...1 as chunks complete. Called often and
    ///   honestly: the system kills continued-processing tasks that report minimal
    ///   progress first.
    public func summarise(
        segments: [TranscriptSegment],
        meeting: MeetingContext,
        progress: @Sendable (Double) -> Void = { _ in }
    ) async throws -> MeetingSummary {
        let finalized = segments.filter { $0.isFinalized && !$0.text.trimmed().isEmpty }
        guard !finalized.isEmpty else {
            debug.log("summary", "\(DebugLog.short(meeting.id)): no finalized transcript, nothing to summarise")
            return MeetingSummary()
        }

        // Fails early, with a clear reason, if the on-device model isn't available.
        _ = try OnDeviceModel.session(tier: tier, instructions: PromptTemplates.instructions)

        let budget = await measureBudget()
        debug.log(
            "summary",
            "\(DebugLog.short(meeting.id)): context \(budget.contextSize), fixed \(budget.fixedCost), answer reserve \(budget.outputReserve), prompt limit \(budget.promptLimit), chunk target \(budget.chunkBudget)\(budget.isMeasured ? "" : " (fallback, not measured)")"
        )

        let chunker = TranscriptChunker(budget: budget.chunkBudget, overlap: budget.overlap)
        let chunks = chunker.chunks(from: finalized)
        guard !chunks.isEmpty else { return MeetingSummary() }
        debug.log("summary", "\(DebugLog.short(meeting.id)): \(finalized.count) lines in \(chunks.count) chunk(s)")

        var notes: [ChunkNotes] = []
        var degraded: [DegradedChunk] = []
        notes.reserveCapacity(chunks.count)
        progress(0.02)

        for chunk in chunks {
            try Task.checkCancellation()
            let started = ContinuousClock.now
            var chunkDegraded: [DegradedChunk] = []
            let chunkNotes = await summarisePiece(
                chunk, of: chunks.count, budget: budget, depth: 0, degraded: &chunkDegraded
            )
            notes.append(chunkNotes)
            degraded.append(contentsOf: chunkDegraded)
            debug.log(
                "summary",
                "chunk \(chunk.index + 1)/\(chunks.count): \(chunk.segments.count) lines, \(chunkNotes.points.count) points, \(chunkDegraded.isEmpty ? "ok" : "\(chunkDegraded.count) degraded piece(s)") in \(DebugLog.elapsed(since: started))"
            )
            // Chunks are the map phase; the roll-up is the last 10%.
            progress(0.9 * Double(chunk.index + 1) / Double(chunks.count))
        }

        let grounder = SummaryGrounder(meetingDate: meeting.date)
        let grounded = grounder.ground(notes, chunks: chunks)
        if grounded.discardedClaims > 0 {
            log.notice("Discarded \(grounded.discardedClaims, privacy: .public) claims with unresolvable citations")
            debug.log("summary", "discarded \(grounded.discardedClaims) claim(s) with citations that didn't resolve")
        }

        let rollupStarted = ContinuousClock.now
        let overview = await rollup(points: notes.flatMap(\.points), meeting: meeting, budget: budget)
        debug.log("summary", "overview written in \(DebugLog.elapsed(since: rollupStarted))")
        progress(1.0)

        // Deterministic self-introduction detection ("My name is X") runs regardless
        // of whether the model's own speakerNames extraction caught it, and takes
        // priority over the model's claims.
        var speakerNames = SpeakerNameHeuristics.selfIntroductions(in: finalized)
        for (speakerID, name) in grounded.speakerNames where speakerNames[speakerID] == nil {
            speakerNames[speakerID] = name
        }

        return MeetingSummary(
            overview: overview,
            decisions: grounded.decisions,
            actionItems: grounded.actionItems,
            openQuestions: grounded.openQuestions,
            mentionedSystems: grounded.mentionedSystems,
            degradedChunks: degraded,
            speakerNames: speakerNames
        )
    }

    // MARK: - Budget

    private func measureBudget() async -> PromptBudget {
        let instructions = await OnDeviceModel.tokenCount(instructions: PromptTemplates.instructions, tier: tier)
        let schema = await OnDeviceModel.tokenCount(schema: DraftChunkNotes.generationSchema, tier: tier)
        guard let instructions, let schema else { return .fallback }
        return PromptBudget(
            contextSize: OnDeviceModel.contextSize(tier: tier),
            fixedCost: instructions + schema,
            outputReserve: 1_024,
            isMeasured: true
        )
    }

    /// Exact cost of a prompt, or the 4-characters-per-token estimate if the
    /// tokenizer can't answer.
    private func cost(of prompt: String) async -> Int {
        await OnDeviceModel.tokenCount(prompt: prompt, tier: tier)
            ?? TranscriptChunker.approximateTokenCount(prompt)
    }

    // MARK: - Map

    /// Summarises a chunk, or a piece of one. Splits pieces that don't fit, and
    /// merges the halves' notes back so the grounder still sees one entry per chunk.
    private func summarisePiece(
        _ piece: TranscriptChunk,
        of total: Int,
        budget: PromptBudget,
        depth: Int,
        degraded: inout [DegradedChunk]
    ) async -> ChunkNotes {
        let prompt = PromptTemplates.chunkPrompt(chunk: piece, chunkIndex: piece.index, chunkCount: total)
        let tokens = await cost(of: prompt)

        if !budget.fits(promptTokens: tokens), depth < maxSplitDepth, let halves = piece.halves() {
            debug.log("summary", "chunk \(piece.index + 1): prompt is \(tokens) tokens, over the \(budget.promptLimit) limit; splitting \(piece.segments.count) lines in two")
            return await splitAndMerge(halves, of: total, budget: budget, depth: depth, degraded: &degraded)
        }

        do {
            let session = try OnDeviceModel.session(tier: tier, instructions: PromptTemplates.instructions)
            let response = try await session.respond(to: prompt, generating: DraftChunkNotes.self)
            return response.content.notes
        } catch {
            let failure = Failure(error)
            debug.log("summary", "chunk \(piece.index + 1): \(failure.reason.rawValue) with a \(tokens)-token prompt: \(failure.detail)")
            log.warning("Chunk \(piece.index, privacy: .public) failed: \(failure.reason.rawValue, privacy: .public)")

            switch failure.reason {
            case .contextOverflow:
                if depth < maxSplitDepth, let halves = piece.halves() {
                    return await splitAndMerge(halves, of: total, budget: budget, depth: depth, degraded: &degraded)
                }
                degraded.append(failure.degraded(piece, recovered: false))
                return ChunkNotes()

            case .guardrail, .refusal:
                return await retryNeutral(piece, of: total, failure: failure, degraded: &degraded)

            case .rateLimited:
                try? await Task.sleep(for: .seconds(failure.retryAfter ?? 5))
                if let notes = try? await respond(to: prompt) { return notes }
                degraded.append(failure.degraded(piece, recovered: false))
                return ChunkNotes()

            case .timeout, .modelError:
                degraded.append(failure.degraded(piece, recovered: false))
                return ChunkNotes()
            }
        }
    }

    private func splitAndMerge(
        _ halves: (TranscriptChunk, TranscriptChunk),
        of total: Int,
        budget: PromptBudget,
        depth: Int,
        degraded: inout [DegradedChunk]
    ) async -> ChunkNotes {
        let first = await summarisePiece(halves.0, of: total, budget: budget, depth: depth + 1, degraded: &degraded)
        let second = await summarisePiece(halves.1, of: total, budget: budget, depth: depth + 1, degraded: &degraded)
        return first.merged(with: second)
    }

    private func respond(to prompt: String) async throws -> ChunkNotes {
        let session = try OnDeviceModel.session(tier: tier, instructions: PromptTemplates.instructions)
        return try await session.respond(to: prompt, generating: DraftChunkNotes.self).content.notes
    }

    /// The fallback after a guardrail trip or refusal: same excerpt, neutral framing.
    /// A thinner section beats one that vanished without telling anyone.
    private func retryNeutral(
        _ piece: TranscriptChunk,
        of total: Int,
        failure: Failure,
        degraded: inout [DegradedChunk]
    ) async -> ChunkNotes {
        let prompt = PromptTemplates.neutralChunkPrompt(chunk: piece, chunkIndex: piece.index, chunkCount: total)
        do {
            let session = try OnDeviceModel.session(tier: tier, instructions: PromptTemplates.groundingRules)
            let response = try await session.respond(to: prompt, generating: DraftChunkNotes.self)
            debug.log("summary", "chunk \(piece.index + 1): neutral retry succeeded")
            degraded.append(failure.degraded(piece, recovered: true))
            return response.content.notes
        } catch {
            debug.log("summary", "chunk \(piece.index + 1): neutral retry failed too: \(Failure(error).detail)")
            degraded.append(failure.degraded(piece, recovered: false))
            return ChunkNotes()
        }
    }

    // MARK: - Reduce

    private func rollup(points: [String], meeting: MeetingContext, budget: PromptBudget) async -> String {
        guard !points.isEmpty else { return "" }
        // A long meeting can produce more points than one prompt holds. Keep the
        // earliest ones that fit rather than overflowing.
        var kept = points
        var prompt = PromptTemplates.rollupPrompt(points: kept, meetingTitle: meeting.title)
        while kept.count > 1, !budget.fits(promptTokens: await cost(of: prompt)) {
            kept = Array(kept.prefix(kept.count * 3 / 4))
            prompt = PromptTemplates.rollupPrompt(points: kept, meetingTitle: meeting.title)
        }
        if kept.count < points.count {
            debug.log("summary", "overview uses \(kept.count) of \(points.count) points to fit the context")
        }
        do {
            let session = try OnDeviceModel.session(tier: tier, instructions: PromptTemplates.instructions)
            let response = try await session.respond(to: prompt, generating: DraftRollup.self)
            return response.content.overview.trimmed()
        } catch {
            debug.log("summary", "overview failed (\(Failure(error).detail)); using the first points instead")
            // Better a plain list of what was said than an empty overview.
            return points.prefix(6).joined(separator: " ")
        }
    }

    // MARK: - Errors

    /// A model error, sorted into what to do about it.
    struct Failure {
        var reason: DegradedChunk.Reason
        var detail: String
        var retryAfter: Double?

        init(_ error: Error) {
            detail = String(describing: error)
            retryAfter = nil
            guard let modelError = error as? LanguageModelError else {
                reason = .modelError
                return
            }
            switch modelError {
            case .contextSizeExceeded(let info):
                reason = .contextOverflow
                detail = "needed \(info.tokenCount) of \(info.contextSize) tokens. \(info.debugDescription)"
            case .guardrailViolation(let info):
                reason = .guardrail
                detail = info.debugDescription
            case .refusal(let info):
                reason = .refusal
                detail = info.debugDescription
            case .rateLimited(let info):
                reason = .rateLimited
                detail = info.debugDescription
                retryAfter = info.resetDate.map { max(1, min(30, $0.timeIntervalSinceNow)) }
            case .timeout:
                reason = .timeout
            default:
                reason = .modelError
            }
        }

        func degraded(_ piece: TranscriptChunk, recovered: Bool) -> DegradedChunk {
            DegradedChunk(
                chunkIndex: piece.index,
                reason: reason,
                recovered: recovered,
                startTime: piece.startTime,
                endTime: piece.endTime,
                detail: detail
            )
        }
    }
}

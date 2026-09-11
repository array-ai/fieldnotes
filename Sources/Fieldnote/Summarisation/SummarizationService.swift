import FieldnoteKit
import Foundation
import FoundationModels
import OSLog

/// Map-reduce summarisation over a finished transcript.
///
/// Map: each chunk gets its own session. A single continuous session would carry
/// every previous chunk in its transcript and walk into the context ceiling around
/// the point a meeting gets long enough to need summarising. Dynamic Profiles are the
/// right tool if a continuous session is ever wanted — for swapping the instruction
/// set, never the provider (spec 4.5, constraint 7).
///
/// Reduce: one pass over the chunk notes, never over raw transcript.
public actor SummarizationService {

    public struct MeetingContext: Sendable {
        public var id: UUID
        public var title: String
        public var type: MeetingType
        public var date: Date

        public init(id: UUID, title: String, type: MeetingType, date: Date) {
            self.id = id
            self.title = title
            self.type = type
            self.date = date
        }
    }

    private let log = Logger(subsystem: "com.publicarray.fieldnotes", category: "summarisation")
    private let templates: TemplateStore

    public init(templates: TemplateStore = .shared) {
        self.templates = templates
    }

    /// - Parameter progress: called with 0...1 as chunks complete. Called often and
    ///   honestly: the system kills continued-processing tasks that report minimal
    ///   progress first (spec 4.7).
    public func summarise(
        segments: [TranscriptSegment],
        meeting: MeetingContext,
        progress: @Sendable (Double) -> Void = { _ in }
    ) async throws -> MeetingSummary {
        let finalized = segments.filter { $0.isFinalized && !$0.text.trimmed().isEmpty }
        guard !finalized.isEmpty else { return MeetingSummary() }

        let template = await templates.template(for: meeting.type)
        let probe = try OnDeviceModel.session(tier: .coreAdvanced, instructions: template.instructions)
        let budget = ContextBudget.measure(session: probe, instructions: template.instructions)
        if !budget.isMeasured {
            log.notice("Context size unavailable; using fallback budget \(budget.chunkBudget, privacy: .public) tokens")
        }

        let chunker = TranscriptChunker(
            budget: budget.chunkBudget,
            overlap: budget.overlap,
            countTokens: budget.tokenCounter(session: probe)
        )
        let chunks = chunker.chunks(from: finalized)
        guard !chunks.isEmpty else { return MeetingSummary() }

        var notes: [ChunkNotes] = []
        var degraded: [DegradedChunk] = []
        notes.reserveCapacity(chunks.count)

        for chunk in chunks {
            try Task.checkCancellation()
            let outcome = await summariseChunk(chunk, of: chunks.count, template: template)
            notes.append(outcome.draft.notes)
            if let failure = outcome.degraded { degraded.append(failure) }
            // Chunks are the map phase; the roll-up is the last 10%.
            progress(0.9 * Double(chunk.index + 1) / Double(chunks.count))
        }

        let grounder = SummaryGrounder(meetingDate: meeting.date)
        let grounded = grounder.ground(notes, chunks: chunks)
        if grounded.discardedClaims > 0 {
            log.notice("Discarded \(grounded.discardedClaims, privacy: .public) claims with unresolvable citations")
        }

        let overview = await rollup(
            points: notes.flatMap(\.points),
            meeting: meeting,
            instructions: template.instructions
        )
        progress(1.0)

        return MeetingSummary(
            overview: overview,
            decisions: grounded.decisions,
            actionItems: grounded.actionItems,
            openQuestions: grounded.openQuestions,
            mentionedSystems: grounded.mentionedSystems,
            degradedChunks: degraded
        )
    }

    // MARK: - Map

    private struct ChunkOutcome {
        var draft: DraftChunkNotes
        var degraded: DegradedChunk?
    }

    private func summariseChunk(
        _ chunk: TranscriptChunk,
        of total: Int,
        template: SummaryTemplate
    ) async -> ChunkOutcome {
        let prompt = PromptTemplates.chunkPrompt(
            template: template,
            chunk: chunk,
            chunkIndex: chunk.index,
            chunkCount: total
        )

        do {
            let session = try OnDeviceModel.session(tier: .coreAdvanced, instructions: template.instructions)
            let response = try await session.respond(to: prompt, generating: DraftChunkNotes.self)
            return ChunkOutcome(draft: response.content, degraded: nil)
        } catch {
            let reason = Self.classify(error)
            log.warning("Chunk \(chunk.index, privacy: .public) failed (\(reason.rawValue, privacy: .public)); retrying with neutral prompt")
            return await retryNeutral(chunk, of: total, reason: reason)
        }
    }

    /// The fallback path. Heated meetings and security-incident language still trip
    /// guardrails occasionally; a thinner section beats a section that vanished
    /// without telling anyone (spec 4.5).
    private func retryNeutral(
        _ chunk: TranscriptChunk,
        of total: Int,
        reason: DegradedChunk.Reason
    ) async -> ChunkOutcome {
        let prompt = PromptTemplates.neutralChunkPrompt(chunk: chunk, chunkIndex: chunk.index, chunkCount: total)
        do {
            let session = try OnDeviceModel.session(
                tier: .coreAdvanced,
                instructions: PromptTemplates.groundingRules
            )
            let response = try await session.respond(to: prompt, generating: DraftChunkNotes.self)
            return ChunkOutcome(
                draft: response.content,
                degraded: DegradedChunk(
                    chunkIndex: chunk.index,
                    reason: reason,
                    recovered: true,
                    startTime: chunk.startTime,
                    endTime: chunk.endTime
                )
            )
        } catch {
            log.error("Chunk \(chunk.index, privacy: .public) failed on the neutral prompt as well")
            return ChunkOutcome(
                draft: DraftChunkNotes(points: [], decisions: [], actionItems: [], openQuestions: [], mentionedSystems: []),
                degraded: DegradedChunk(
                    chunkIndex: chunk.index,
                    reason: reason,
                    recovered: false,
                    startTime: chunk.startTime,
                    endTime: chunk.endTime
                )
            )
        }
    }

    // MARK: - Reduce

    private func rollup(points: [String], meeting: MeetingContext, instructions: String) async -> String {
        guard !points.isEmpty else { return "" }
        let prompt = PromptTemplates.rollupPrompt(
            points: points,
            meetingTitle: meeting.title,
            type: meeting.type
        )
        do {
            let session = try OnDeviceModel.session(tier: .coreAdvanced, instructions: instructions)
            let response = try await session.respond(to: prompt, generating: DraftRollup.self)
            return response.content.overview.trimmed()
        } catch {
            log.warning("Roll-up failed; falling back to the first chunk's points")
            // Better a plain list of what was said than an empty overview.
            return points.prefix(6).joined(separator: " ")
        }
    }

    static func classify(_ error: Error) -> DegradedChunk.Reason {
        if let generation = error as? LanguageModelSession.GenerationError {
            switch generation {
            case .guardrailViolation: return .guardrail
            case .exceededContextWindowSize: return .contextOverflow
            default: return .modelError
            }
        }
        return .modelError
    }
}

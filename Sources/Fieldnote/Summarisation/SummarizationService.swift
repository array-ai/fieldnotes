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
    /// Longest answer a part may produce: the room the budget reserved for it, so an
    /// answer can never run past the context window (answers of ~1,750 tokens were
    /// seen before this cap).
    private var answerCap = 1_800

    /// The prompt for the current run: built-in, or the user's edit (debug mode).
    private var prompt = SummaryPrompt.builtIn
    /// Splits per chunk before giving up: 2^4 = 16 pieces.
    private let maxSplitDepth = 4

    public init() {}

    /// The model won't summarise right now: rate limited, or refused by the system
    /// (Apple throttles the on-device model for apps in the background). The
    /// meeting waits and is summarised the next time the app is open, rather than
    /// ending up with empty notes.
    public struct Deferred: Error, LocalizedError {
        public var detail: String
        /// Deferred without trying: the run was in a background task, where Apple's
        /// model rate-limits every request. Doesn't count against the retry limit.
        public var withoutAttempt = false
        public var errorDescription: String? {
            "Waiting to summarise. Open Fieldnote to finish the notes."
        }
    }

    /// The model wouldn't write the notes after the one automatic retry. The meeting
    /// stops with Try again, rather than saving empty notes or retrying forever.
    public struct NotWritten: Error, LocalizedError {
        public var detail: String
        public var errorDescription: String? {
            "Couldn't write the notes: the on-device model is busy or limited right now. Tap Try again."
        }
    }

    public static let skipSmallTalkKey = "skipSmallTalk"

    /// The local model writes plain labelled lines (`PlainNotes`) instead of filling
    /// the structured schema, which it doesn't follow. Set per run.
    private var plain = false

    /// Session instructions for this run.
    private var instructions: String {
        plain ? PlainNotes.instructions : prompt.instructions
    }

    /// Whether this run may defer (the pipeline allows it a few times per meeting,
    /// then accepts thinner notes rather than waiting forever).
    private var allowDeferral = true

    /// - Parameter progress: called with 0...1 as chunks complete. Called often and
    ///   honestly: the system kills continued-processing tasks that report minimal
    ///   progress first.
    public func summarise(
        segments: [TranscriptSegment],
        meeting: MeetingContext,
        allowDeferral: Bool = true,
        savedParts: [String: ChunkNotes] = [:],
        savePart: @Sendable (String, ChunkNotes) async -> Void = { _, _ in },
        cleaned: @Sendable ([TranscriptSegment]) async -> Void = { _ in },
        progress: @Sendable (Double) -> Void = { _ in }
    ) async throws -> MeetingSummary {
        self.allowDeferral = allowDeferral
        var segments = segments
        var spoken = segments.filter { $0.isFinalized && !$0.text.trimmed().isEmpty }
        // "Skip small talk" (Settings, on by default): lines like "Okay." and "Give
        // us a second." are left out of what the model reads. On a 68-minute meeting
        // this cut 10% of the lines.
        let skipSmallTalk = UserDefaults.standard.object(forKey: Self.skipSmallTalkKey) as? Bool ?? true
        var finalized = skipSmallTalk ? spoken.filter { !NoteQuality.isFiller($0.text) } : spoken
        if skipSmallTalk, finalized.count < spoken.count {
            debug.log("summary", "\(DebugLog.short(meeting.id)): skipping \(spoken.count - finalized.count) small-talk line(s) of \(spoken.count)")
        }
        guard !finalized.isEmpty else {
            debug.log("summary", "\(DebugLog.short(meeting.id)): no finalized transcript, nothing to summarise")
            return MeetingSummary()
        }

        prompt = SummaryPromptStore.load()
        try await OnDeviceModel.prepareSummaryModel()
        defer { OnDeviceModel.releaseSummaryModel() }
        plain = OnDeviceModel.usesLocalModel
        debug.log("summary", "\(DebugLog.short(meeting.id)): writing notes with \(plain ? "\(OnDeviceModel.selectedEngine.card.title) (Core AI), plain-text notes" : "Apple's model")")
        if !prompt.isBuiltIn {
            debug.log("summary", "\(DebugLog.short(meeting.id)): using an edited summary prompt")
        }

        // Fails early, with a clear reason, if the on-device model isn't available.
        _ = try OnDeviceModel.session(tier: tier, instructions: instructions)

        // The optional clean-up (Settings → Custom words): fixes custom words in the
        // transcript itself, so the notes read the right names too.
        if UserDefaults.standard.bool(forKey: TranscriptCleanup.defaultsKey) {
            let fixed = await cleanUp(segments, meetingID: meeting.id)
            if fixed != segments {
                segments = fixed
                let ids = Set(finalized.map(\.id))
                spoken = segments.filter { $0.isFinalized && !$0.text.trimmed().isEmpty }
                finalized = spoken.filter { ids.contains($0.id) }
                await cleaned(segments)
            }
        }

        let budget = await measureBudget()
        answerCap = budget.outputReserve
        debug.log(
            "summary",
            "\(DebugLog.short(meeting.id)): context \(budget.contextSize), fixed \(budget.fixedCost), answer reserve \(budget.outputReserve), prompt limit \(budget.promptLimit), chunk target \(budget.chunkBudget)\(budget.isMeasured ? "" : " (fallback, not measured)")"
        )

        let chunker = TranscriptChunker(budget: budget.chunkBudget, overlap: budget.overlap)
        let chunks = chunker.chunks(from: finalized)
        guard !chunks.isEmpty else { return MeetingSummary() }
        debug.log("summary", "\(DebugLog.short(meeting.id)): \(finalized.count) lines in \(chunks.count) chunk(s)")

        var notes: [ChunkNotes] = []
        // Parts in a row where the model produced nothing and failed: two means it
        // isn't working, and the rest would fail the same way. For a downloaded model
        // a meeting of one part gets one: its only part failing is the same signal,
        // and the recovery (clearing its prepared copy) has to run (build 59:
        // MiniCPM5 2B failed at once, twice, on a short meeting, and the check never
        // ran). Apple's model keeps two.
        var failedInARow = 0
        let failuresToStop = plain ? min(2, chunks.count) : 2
        var anyProduced = false
        var degraded: [DegradedChunk] = []
        notes.reserveCapacity(chunks.count)
        progress(0.02)

        for chunk in chunks {
            try Task.checkCancellation()
            if let saved = savedParts[chunk.partKey] {
                notes.append(saved)
                debug.log("summary", "chunk \(chunk.index + 1)/\(chunks.count): already written, reusing it")
                progress(0.9 * Double(chunk.index + 1) / Double(chunks.count))
                continue
            }
            let started = ContinuousClock.now
            var chunkDegraded: [DegradedChunk] = []
            let chunkNotes = try await summarisePiece(
                chunk, of: chunks.count, budget: budget, depth: 0, degraded: &chunkDegraded
            )
            notes.append(chunkNotes)
            degraded.append(contentsOf: chunkDegraded)
            let produced = !chunkNotes.topics.isEmpty || !chunkNotes.actionItems.isEmpty || !chunkNotes.decisions.isEmpty
            failedInARow = (!produced && !chunkDegraded.isEmpty) ? failedInARow + 1 : 0
            if produced { anyProduced = true }
            if failedInARow >= failuresToStop {
                let detail = chunkDegraded.first?.detail ?? "no answer"
                debug.log("summary", "\(DebugLog.short(meeting.id)): the model failed on \(failedInARow) parts in a row; stopping (\(detail.prefix(120)))")
                // Most likely a broken prepared copy: clear it so Try again prepares
                // the model afresh.
                var gaveUp = false
                if plain, let pack = OnDeviceModel.selectedEngine.modelPack, let bundle = OnDeviceModel.bundle(for: pack) {
                    OnDeviceModel.releaseSummaryModel()
                    OnDeviceModel.clearPreparedCopy(in: bundle)
                    // A build compiled for this chip failing twice: use the portable one.
                    gaveUp = CompiledFallback.recordFailure(pack)
                    if gaveUp {
                        debug.log("summary", "\(DebugLog.short(meeting.id)): \(pack.rawValue) failed twice; the portable model will be used instead")
                    }
                }
                throw NotWritten(detail: !plain
                    ? "Apple's model isn't answering (\(detail.prefix(80))). Tap Try again later."
                    : gaveUp
                    ? "\(OnDeviceModel.selectedEngine.card.title) isn't answering (\(detail.prefix(80))). Its build for this iPhone keeps failing, so download it again in Settings → Processing: this phone will prepare its own copy."
                    : "\(OnDeviceModel.selectedEngine.card.title) isn't answering (\(detail.prefix(80))). Its prepared copy was cleared: tap Try again to prepare it afresh. That takes a few minutes (6½ for MiniCPM5 2B on an iPhone 16); leave it running.")
            }
            // Only clean parts are kept for a resume; a degraded one gets another go.
            if chunkDegraded.isEmpty { await savePart(chunk.partKey, chunkNotes) }
            debug.log(
                "summary",
                "chunk \(chunk.index + 1)/\(chunks.count): \(chunk.segments.count) lines, \(chunkNotes.topics.count) topic(s), \(chunkNotes.topics.reduce(0) { $0 + $1.points.count }) point(s), \(chunkDegraded.isEmpty ? "ok" : "\(chunkDegraded.count) degraded piece(s)") in \(DebugLog.elapsed(since: started))"
            )
            // Chunks are the map phase; the roll-up is the last 10%.
            progress(0.9 * Double(chunk.index + 1) / Double(chunks.count))
        }

        // Only a run that produced something counts as the model working; recording a
        // success for a run where every part failed reset the fallback count.
        if plain, anyProduced, let pack = OnDeviceModel.selectedEngine.modelPack { CompiledFallback.recordSuccess(pack) }
        let grounder = SummaryGrounder(meetingDate: meeting.date)
        let grounded = grounder.ground(notes, chunks: chunks)
        if grounded.discardedClaims > 0 {
            log.notice("Discarded \(grounded.discardedClaims, privacy: .public) claims with unresolvable citations")
            debug.log("summary", "discarded \(grounded.discardedClaims) claim(s) with citations that didn't resolve")
        }
        if grounded.droppedAsNoise > 0 {
            debug.log("summary", "dropped \(grounded.droppedAsNoise) item(s) as noise: fragments, non-questions, repeats")
        }

        let starts = Dictionary(finalized.map { ($0.id, $0.start) }, uniquingKeysWith: { first, _ in first })
        let outlineStarted = ContinuousClock.now
        let (overview, topics) = await outline(
            candidates: grounded.topics,
            fallbackPoints: notes.flatMap(\.points),
            meeting: meeting,
            budget: budget,
            time: { starts[$0] ?? .greatestFiniteMagnitude }
        )
        debug.log("summary", "overview and \(topics.count) section(s) from \(grounded.topics.count) excerpt topic(s) in \(DebugLog.elapsed(since: outlineStarted))")
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
            topics: topics,
            decisions: grounded.decisions,
            actionItems: grounded.actionItems,
            openQuestions: grounded.openQuestions,
            mentionedSystems: grounded.mentionedSystems,
            degradedChunks: degraded,
            speakerNames: speakerNames
        )
    }

    // MARK: - Clean-up

    /// Asks the notes model about the lines close to a custom word, 30 at a time, and
    /// makes the fixes it gives that check out (`TranscriptCleanup.parse`). A part
    /// that fails is skipped: the clean-up never stops the notes.
    private func cleanUp(_ segments: [TranscriptSegment], meetingID: UUID) async -> [TranscriptSegment] {
        let id = DebugLog.short(meetingID)
        let terms = MSPVocabulary.current
        let keys = Set(segments.flatMap { $0.text.split(separator: " ").map { WordRevision.key(String($0)) } })
        let real = await SpellingDictionary.realWords(keys, language: SpellingDictionary.transcriptLanguage)
        let isWord: (String) -> Bool = { real.contains($0) }
        let candidates = TranscriptCleanup.candidates(segments, terms: terms, isWord: isWord)
        guard !candidates.isEmpty else {
            debug.log("summary", "\(id): clean-up: no lines near a custom word")
            return segments
        }
        let started = ContinuousClock.now
        let instructions = TranscriptCleanup.instructions
        var result = segments
        var applied = 0, failed = 0
        for batch in stride(from: 0, to: candidates.count, by: 30) {
            guard !Task.isCancelled else { break }
            let indices = Array(candidates[batch..<min(batch + 30, candidates.count)])
            let lines = indices.map { result[$0].text }
            let prompt = TranscriptCleanup.prompt(lines: lines, terms: TranscriptCleanup.relevantTerms(lines, terms: terms, isWord: isWord))
            do {
                let session = try OnDeviceModel.session(tier: tier, instructions: instructions)
                let response = try await session.respond(
                    to: prompt, options: GenerationOptions(maximumResponseTokens: 400),
                    contextOptions: OnDeviceModel.contextOptions
                )
                for fix in TranscriptCleanup.parse(response.content, lines: lines, terms: terms) {
                    let index = indices[fix.line - 1]
                    if let fixed = TranscriptCleanup.apply(fix, to: result[index]) {
                        result[index] = fixed
                        applied += 1
                    }
                }
            } catch {
                failed += 1
                debug.log("summary", "\(id): clean-up part \(batch / 30 + 1) failed: \(Failure(error).detail.prefix(160))")
            }
        }
        // Counts only: the words are meeting content.
        debug.log("summary", "\(id): clean-up: \(candidates.count) line(s) near a custom word, \(applied) fix(es), \(failed) part(s) failed, in \(DebugLog.elapsed(since: started))")
        return result
    }

    // MARK: - Budget

    private func measureBudget() async -> PromptBudget {
        if plain {
            // MiniCPM5's own tokenizer isn't exposed; Apple's counts are a close proxy and
            // the margins absorb the difference. No schema in the prompt; the format
            // lines of the plain prompt cost about 200 tokens; plain notes are short.
            let instructions = await OnDeviceModel.tokenCount(instructions: PlainNotes.instructions, tier: tier) ?? 80
            return PromptBudget(
                contextSize: OnDeviceModel.localContextSize,
                fixedCost: Int(Double(instructions + 200) * 1.2),
                outputReserve: 1_000,
                isMeasured: false
            )
        }
        let instructions = await OnDeviceModel.tokenCount(instructions: self.prompt.instructions, tier: tier)
        let schema = await OnDeviceModel.tokenCount(schema: DraftChunkNotes.generationSchema, tier: tier)
        guard let instructions, let schema else { return .fallback }
        return PromptBudget(
            contextSize: OnDeviceModel.contextSize(tier: tier),
            fixedCost: instructions + schema,
            // Answers of up to ~1,750 tokens were measured on device; less than this
            // overflows the 4,096-token context mid-answer.
            outputReserve: 1_800,
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
    ) async throws -> ChunkNotes {
        let prompt = plain
            ? PlainNotes.prompt(chunk: piece, chunkIndex: piece.index, chunkCount: total)
            : PromptTemplates.chunkPrompt(chunk: piece, chunkIndex: piece.index, chunkCount: total, request: self.prompt.effectiveRequest)
        let tokens = await cost(of: prompt)

        if !budget.fits(promptTokens: tokens), depth < maxSplitDepth, let halves = piece.halves() {
            debug.log("summary", "chunk \(piece.index + 1): prompt is \(tokens) tokens, over the \(budget.promptLimit) limit; splitting \(piece.segments.count) lines in two")
            return try await splitAndMerge(halves, of: total, budget: budget, depth: depth, degraded: &degraded)
        }

        do {
            let session = try OnDeviceModel.session(tier: tier, instructions: instructions)
            let started = ContinuousClock.now
            if plain {
                // Plain notes are short; a small model given more room rambles (1,000
                // tokens for eight lines of transcript, build 40).
                let response = try await session.respond(to: prompt, options: GenerationOptions(maximumResponseTokens: min(answerCap, 600)), contextOptions: OnDeviceModel.contextOptions)
                let notes = PlainNotes.parse(response.content, chunk: piece)
                debug.log(
                    "summary",
                    "chunk \(piece.index + 1): \(response.usage.input.totalTokenCount) tokens in, \(response.usage.output.totalTokenCount) out, \(DebugLog.elapsed(since: started)), \(notes.topics.flatMap(\.points).count) usable point(s)"
                )
                if notes.topics.isEmpty, notes.actionItems.isEmpty, notes.decisions.isEmpty {
                    debug.log("summary", "chunk \(piece.index + 1): nothing usable in the answer: \(response.content.prefix(300))")
                }
                return notes
            }
            let response = try await session.respond(to: prompt, generating: DraftChunkNotes.self, options: GenerationOptions(maximumResponseTokens: answerCap), contextOptions: OnDeviceModel.contextOptions)
            debug.log(
                "summary",
                "chunk \(piece.index + 1): \(response.usage.input.totalTokenCount) tokens in, \(response.usage.output.totalTokenCount) out, \(DebugLog.elapsed(since: started))"
            )
            return response.content.notes
        } catch {
            // An expired background task cancels the run; that's a pause, not a
            // model failure. The checkpoint resumes it.
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            let failure = Failure(error)
            debug.log("summary", "chunk \(piece.index + 1): \(failure.reason.rawValue) with a \(tokens)-token prompt: \(failure.detail)")
            log.warning("Chunk \(piece.index, privacy: .public) failed: \(failure.reason.rawValue, privacy: .public)")

            switch failure.reason {
            case .contextOverflow:
                if depth < maxSplitDepth, let halves = piece.halves() {
                    return try await splitAndMerge(halves, of: total, budget: budget, depth: depth, degraded: &degraded)
                }
                degraded.append(failure.degraded(piece, recovered: false))
                return ChunkNotes()

            case .guardrail, .refusal:
                return try await retryNeutral(piece, of: total, failure: failure, degraded: &degraded)

            case .rateLimited:
                try await Task.sleep(for: .seconds(failure.retryAfter ?? 15))
                do {
                    return try await respond(to: prompt, piece: piece)
                } catch {
                    if error is CancellationError || Task.isCancelled { throw CancellationError() }
                    let again = Failure(error)
                    debug.log("summary", "chunk \(piece.index + 1): retry after rate limit failed: \(again.reason.rawValue)")
                    if again.isTemporary { throw allowDeferral ? Deferred(detail: again.detail) : NotWritten(detail: again.detail) }
                    degraded.append(again.degraded(piece, recovered: false))
                    return ChunkNotes()
                }

            case .timeout, .modelError:
                // An answer cut off at the length cap fails as a model error. Half the
                // excerpt means a shorter answer, so split before giving up.
                // Splitting helps only a structured answer cut off at the length cap.
                // A plain-text answer is never cut off that way, so a failure there is
                // the model itself; splitting just repeats it 16 times (build 42).
                if !plain, failure.reason == .modelError, !failure.isTemporary,
                   depth < maxSplitDepth, piece.segments.count >= 8, let halves = piece.halves() {
                    debug.log("summary", "chunk \(piece.index + 1): answer may have hit the \(answerCap)-token cap; splitting \(piece.segments.count) lines in two")
                    return try await splitAndMerge(halves, of: total, budget: budget, depth: depth, degraded: &degraded)
                }
                if failure.isTemporary { throw allowDeferral ? Deferred(detail: failure.detail) : NotWritten(detail: failure.detail) }
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
    ) async throws -> ChunkNotes {
        let first = try await summarisePiece(halves.0, of: total, budget: budget, depth: depth + 1, degraded: &degraded)
        let second = try await summarisePiece(halves.1, of: total, budget: budget, depth: depth + 1, degraded: &degraded)
        return first.merged(with: second)
    }

    private func respond(to prompt: String, piece: TranscriptChunk) async throws -> ChunkNotes {
        let session = try OnDeviceModel.session(tier: tier, instructions: instructions)
        if plain {
            let text = try await session.respond(to: prompt, options: GenerationOptions(maximumResponseTokens: min(answerCap, 600)), contextOptions: OnDeviceModel.contextOptions).content
            return PlainNotes.parse(text, chunk: piece)
        }
        return try await session.respond(to: prompt, generating: DraftChunkNotes.self, options: GenerationOptions(maximumResponseTokens: answerCap), contextOptions: OnDeviceModel.contextOptions).content.notes
    }

    /// The fallback after a guardrail trip or refusal: same excerpt, neutral framing.
    /// A thinner section beats one that vanished without telling anyone.
    private func retryNeutral(
        _ piece: TranscriptChunk,
        of total: Int,
        failure: Failure,
        degraded: inout [DegradedChunk]
    ) async throws -> ChunkNotes {
        if plain {
            // Apple's content guardrails don't apply to the local model; a refusal
            // here is the model's own, and the same prompt again won't change it.
            degraded.append(failure.degraded(piece, recovered: false))
            return ChunkNotes()
        }
        let prompt = PromptTemplates.neutralChunkPrompt(chunk: piece, chunkIndex: piece.index, chunkCount: total)
        do {
            let session = try OnDeviceModel.session(tier: tier, instructions: PromptTemplates.groundingRules)
            let response = try await session.respond(to: prompt, generating: DraftChunkNotes.self, options: GenerationOptions(maximumResponseTokens: answerCap), contextOptions: OnDeviceModel.contextOptions)
            debug.log("summary", "chunk \(piece.index + 1): neutral retry succeeded")
            degraded.append(failure.degraded(piece, recovered: true))
            return response.content.notes
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            debug.log("summary", "chunk \(piece.index + 1): neutral retry failed too: \(Failure(error).detail)")
            degraded.append(failure.degraded(piece, recovered: false))
            return ChunkNotes()
        }
    }

    // MARK: - Reduce

    /// The overview, and the excerpt topics joined into the meeting's sections.
    private func outline(
        candidates: [SummaryTopic],
        fallbackPoints: [String],
        meeting: MeetingContext,
        budget: PromptBudget,
        time: (UUID) -> TimeInterval
    ) async -> (overview: String, topics: [SummaryTopic]) {
        guard !candidates.isEmpty else {
            return (await rollup(points: fallbackPoints, meeting: meeting, budget: budget), [])
        }
        if plain {
            // No structured outline from the local model: join topics by title, and
            // ask only for the overview, in plain text.
            let merged = TopicMerger.mergeByTitle(candidates, time: time)
            let overview = await rollup(
                points: merged.map { "\($0.title): \($0.summary.isEmpty ? ($0.points.first?.text ?? "") : $0.summary)" },
                meeting: meeting, budget: budget
            )
            return (overview, merged)
        }

        // Full summaries first; if that's too long, just the start of each.
        var listing = candidates.map { (title: $0.title, summary: $0.summary) }
        var prompt = PromptTemplates.outlinePrompt(topics: listing, meetingTitle: meeting.title)
        if !budget.fits(promptTokens: await cost(of: prompt)) {
            listing = candidates.map { (title: $0.title, summary: String($0.summary.prefix(80))) }
            prompt = PromptTemplates.outlinePrompt(topics: listing, meetingTitle: meeting.title)
        }

        if budget.fits(promptTokens: await cost(of: prompt)) {
            do {
                let session = try OnDeviceModel.session(tier: tier, instructions: instructions)
                let response = try await session.respond(to: prompt, generating: DraftOutline.self, options: GenerationOptions(maximumResponseTokens: 800), contextOptions: OnDeviceModel.contextOptions)
                let sections = response.content.sections.map {
                    TopicMerger.Section(
                        title: $0.title,
                        summary: $0.summary,
                        members: $0.topicNumbers.map { $0 - 1 },
                        emoji: $0.emoji
                    )
                }
                let merged = TopicMerger.merge(candidates, sections: sections, time: time)
                return (response.content.overview.trimmed(), merged)
            } catch {
                debug.log("summary", "outline failed (\(Failure(error).detail)); joining topics by title instead")
            }
        } else {
            debug.log("summary", "\(candidates.count) excerpt topics are too many for one outline prompt; joining by title instead")
        }

        let merged = TopicMerger.mergeByTitle(candidates, time: time)
        let overview = await rollup(points: merged.map { "\($0.title): \($0.summary)" }, meeting: meeting, budget: budget)
        return (overview, merged)
    }

    private func rollup(points: [String], meeting: MeetingContext, budget: PromptBudget) async -> String {
        guard !points.isEmpty else { return "" }
        // A long meeting can produce more points than one prompt holds. Keep the
        // earliest ones that fit rather than overflowing.
        var kept = points
        let makePrompt: ([String]) -> String = { [plain] points in
            plain
                ? PlainNotes.overviewPrompt(points: points, meetingTitle: meeting.title)
                : PromptTemplates.rollupPrompt(points: points, meetingTitle: meeting.title)
        }
        var prompt = makePrompt(kept)
        while kept.count > 1, !budget.fits(promptTokens: await cost(of: prompt)) {
            kept = Array(kept.prefix(kept.count * 3 / 4))
            prompt = makePrompt(kept)
        }
        if kept.count < points.count {
            debug.log("summary", "overview uses \(kept.count) of \(points.count) points to fit the context")
        }
        do {
            let session = try OnDeviceModel.session(tier: tier, instructions: instructions)
            if plain {
                let response = try await session.respond(to: prompt, options: GenerationOptions(maximumResponseTokens: 300), contextOptions: OnDeviceModel.contextOptions)
                return PlainNotes.cleanOverview(response.content)
            }
            let response = try await session.respond(to: prompt, generating: DraftRollup.self, options: GenerationOptions(maximumResponseTokens: 800), contextOptions: OnDeviceModel.contextOptions)
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
        /// The error's own text, for the debug log: it can quote the meeting, which is
        /// accepted there for debugging.
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

        /// Worth waiting for rather than giving up on: rate limits, timeouts, and the
        /// system's model service refusing work (it does this to background apps).
        var isTemporary: Bool {
            switch reason {
            case .rateLimited, .timeout: true
            case .modelError: detail.contains("ModelManager") || detail.contains("SensitiveContentAnalysis")
            default: false
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

/// The user's edit of the summary prompt (debug mode), kept in UserDefaults.
public enum SummaryPromptStore {
    private static let key = "summaryPrompt"

    public static func load() -> SummaryPrompt {
        guard let data = UserDefaults.standard.data(forKey: key),
              let stored = try? JSONDecoder().decode(SummaryPrompt.self, from: data) else { return .builtIn }
        return stored
    }

    public static func save(_ prompt: SummaryPrompt) {
        if prompt.isBuiltIn {
            UserDefaults.standard.removeObject(forKey: key)
        } else if let data = try? JSONEncoder().encode(prompt) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

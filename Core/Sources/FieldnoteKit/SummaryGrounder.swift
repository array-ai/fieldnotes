import Foundation

/// Turns model drafts into persisted summary items, and enforces the rule that makes
/// the output trustworthy: **every decision, action and open question cites a real
/// transcript segment, or it does not get saved** (spec 4.5).
///
/// Also deduplicates. Chunks overlap on purpose, so the same commitment is genuinely
/// seen twice and would otherwise appear twice in the action list.
///
/// Pure — no frameworks, no model, fully testable.
public struct SummaryGrounder: Sendable {
    public var dateResolver: RelativeDateResolver
    /// The meeting's own date. Relative phrases resolve against this.
    public var meetingDate: Date

    public init(meetingDate: Date, dateResolver: RelativeDateResolver = RelativeDateResolver()) {
        self.meetingDate = meetingDate
        self.dateResolver = dateResolver
    }

    public struct Outcome: Sendable {
        /// Topics per excerpt, in transcript order, each point cited. Several of these
        /// can be the same subject seen in different excerpts; `TopicMerger` joins them.
        public var topics: [SummaryTopic] = []
        public var decisions: [Decision] = []
        public var actionItems: [ActionItem] = []
        public var openQuestions: [OpenQuestion] = []
        public var mentionedSystems: [String] = []
        /// Speaker label ("S1") to a name grounded in the real speaker of the cited
        /// line, not whatever label the model itself claimed. First name claimed for a
        /// given label wins -- a self-introduction early on outranks a mis-hearing
        /// later.
        public var speakerNames: [String: String] = [:]
        /// Claims thrown away because their citations did not resolve. Counted so the
        /// eval corpus (spec 11.4) has something to measure, and so a prompt change
        /// that wrecks grounding is visible rather than quiet.
        public var discardedClaims: Int = 0
        /// Items dropped as noise: fragments, non-questions as questions, near
        /// repeats (`NoteQuality`).
        public var droppedAsNoise: Int = 0
    }

    public func ground(_ notes: [ChunkNotes], chunks: [TranscriptChunk]) -> Outcome {
        var outcome = Outcome()
        var seenPoints: [Set<String>] = []
        var seenDecisions: [Set<String>] = []
        var seenActions: [Set<String>] = []
        var seenQuestions: [Set<String>] = []
        var seenSystems = Set<String>()

        for (draft, chunk) in zip(notes, chunks) {
            for topic in draft.topics {
                var points: [TopicPoint] = []
                for point in topic.points {
                    let text = point.text.trimmed()
                    guard !text.isEmpty else { continue }
                    guard let citations = resolve(point.sourceLines, in: chunk) else {
                        outcome.discardedClaims += 1
                        continue
                    }
                    // A transcript line repeated isn't a note; nor is a point the
                    // meeting already has.
                    let cited = chunk.segments.first { $0.id == citations.primary }?.text ?? ""
                    guard !NoteQuality.isQuote(text, of: cited),
                          NoteQuality.isNew(text, among: &seenPoints) else {
                        outcome.droppedAsNoise += 1
                        continue
                    }
                    points.append(
                        TopicPoint(
                            text: text,
                            details: point.details.map { $0.trimmed() }.filter { !$0.isEmpty },
                            sourceSegmentID: citations.primary
                        )
                    )
                }
                let title = topic.title.trimmed()
                guard !points.isEmpty, !title.isEmpty else { continue }
                outcome.topics.append(SummaryTopic(title: title, summary: topic.summary.trimmed(), points: points))
            }

            for decision in draft.decisions {
                guard let citations = resolve(decision.sourceLines, in: chunk) else {
                    outcome.discardedClaims += 1
                    continue
                }
                guard NoteQuality.isDecision(decision.statement),
                      NoteQuality.isNew(decision.statement, among: &seenDecisions) else {
                    outcome.droppedAsNoise += 1
                    continue
                }
                outcome.decisions.append(
                    Decision(
                        statement: decision.statement.trimmed(),
                        sourceSegmentID: citations.primary,
                        supportingSegmentIDs: citations.supporting
                    )
                )
            }

            for action in draft.actionItems {
                guard let citations = resolve(action.sourceLines, in: chunk) else {
                    outcome.discardedClaims += 1
                    continue
                }
                guard NoteQuality.isTask(action.task),
                      NoteQuality.isNew(action.task, among: &seenActions) else {
                    outcome.droppedAsNoise += 1
                    continue
                }
                let spoken = action.dueDate.trimmed().nilIfEmpty
                outcome.actionItems.append(
                    ActionItem(
                        task: action.task.trimmed(),
                        owner: NoteQuality.owner(action.owner),
                        dueDate: spoken,
                        resolvedDueDate: dateResolver.resolve(spoken, relativeTo: meetingDate),
                        sourceSegmentID: citations.primary,
                        supportingSegmentIDs: citations.supporting
                    )
                )
            }

            for question in draft.openQuestions {
                guard let citations = resolve(question.sourceLines, in: chunk) else {
                    outcome.discardedClaims += 1
                    continue
                }
                guard NoteQuality.isQuestion(question.text),
                      NoteQuality.isNew(question.text, among: &seenQuestions) else {
                    outcome.droppedAsNoise += 1
                    continue
                }
                outcome.openQuestions.append(
                    OpenQuestion(text: question.text.trimmed(), sourceSegmentID: citations.primary)
                )
            }

            for system in draft.mentionedSystems {
                let name = system.trimmed()
                guard !name.isEmpty, seenSystems.insert(name.lowercased()).inserted else { continue }
                outcome.mentionedSystems.append(name)
            }

            for claim in draft.speakerNames {
                let name = claim.text.trimmed()
                guard !name.isEmpty else { continue }
                guard let citations = resolve(claim.sourceLines, in: chunk),
                      let segment = chunk.segments.first(where: { $0.id == citations.primary }),
                      let label = segment.speakerID else {
                    outcome.discardedClaims += 1
                    continue
                }
                if outcome.speakerNames[label] == nil {
                    outcome.speakerNames[label] = name
                }
            }
        }

        outcome.decisions.sort { sortKey(for: $0.sourceSegmentID, chunks: chunks) < sortKey(for: $1.sourceSegmentID, chunks: chunks) }
        outcome.actionItems.sort { sortKey(for: $0.sourceSegmentID, chunks: chunks) < sortKey(for: $1.sourceSegmentID, chunks: chunks) }
        return outcome
    }

    // MARK: - Citation resolution

    struct Citations {
        var primary: UUID
        var supporting: [UUID]
    }

    /// A line number the model made up resolves to nothing, and the claim goes with
    /// it. This is the check that stops fluent invention from reaching the summary.
    func resolve(_ lines: [Int], in chunk: TranscriptChunk) -> Citations? {
        var resolved: [UUID] = []
        for line in lines {
            if let id = chunk.segmentID(forLine: line), !resolved.contains(id) {
                resolved.append(id)
            }
        }
        guard let primary = resolved.first else { return nil }
        return Citations(primary: primary, supporting: Array(resolved.dropFirst()))
    }

    private func sortKey(for segmentID: UUID, chunks: [TranscriptChunk]) -> TimeInterval {
        for chunk in chunks {
            if let segment = chunk.segments.first(where: { $0.id == segmentID }) {
                return segment.start
            }
        }
        return .greatestFiniteMagnitude
    }
}

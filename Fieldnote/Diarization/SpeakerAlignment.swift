import Foundation

/// Aligns diarized spans onto transcript segments by time overlap (spec 4.4).
///
/// Pure arithmetic, no frameworks, so it is testable off-device — which matters
/// because this is where speaker labels get quietly wrong and nobody notices until a
/// four-person meeting reads like a monologue.
public enum SpeakerAlignment {

    /// Each segment takes the speaker ID with the greatest overlap against it.
    ///
    /// - A segment with no overlap at all keeps `speakerID == nil`. It is shown as
    ///   "Unknown" and is one long-press away from being fixed by hand. Guessing here
    ///   would be worse: a confident wrong label does not invite correction.
    /// - A segment the user has already relabelled is left alone. Re-running
    ///   diarization must not silently undo manual work.
    /// - Ties break on the lower speaker ID so re-running on the same input gives the
    ///   same answer.
    public static func apply(
        spans: [DiarizedSpan],
        to segments: [TranscriptSegment]
    ) -> [TranscriptSegment] {
        guard !spans.isEmpty else { return segments }
        let sortedSpans = spans.sorted { $0.start < $1.start }

        return segments.map { segment in
            guard !segment.editedByUser else { return segment }
            var updated = segment
            let assignment = bestSpeaker(for: segment, in: sortedSpans)
            updated.speakerID = assignment?.speakerID
            if let assignment {
                updated.confidence = min(segment.confidence, assignment.share)
            }
            return updated
        }
    }

    struct Assignment {
        var speakerID: String
        /// Share of the segment's duration covered by this speaker, 0...1.
        var share: Double
    }

    static func bestSpeaker(for segment: TranscriptSegment, in spans: [DiarizedSpan]) -> Assignment? {
        var totals: [String: TimeInterval] = [:]
        for span in spans {
            // Spans are sorted by start, so once a span starts after the segment ends
            // no later span can overlap it.
            if span.start >= segment.end { break }
            let overlap = overlapDuration(segment.start, segment.end, span.start, span.end)
            if overlap > 0 {
                totals[span.speakerID, default: 0] += overlap
            }
        }
        guard let best = totals.max(by: { lhs, rhs in
            lhs.value == rhs.value ? lhs.key > rhs.key : lhs.value < rhs.value
        }) else { return nil }

        let denominator = segment.duration > 0 ? segment.duration : best.value
        let share = denominator > 0 ? min(1.0, best.value / denominator) : 0
        return Assignment(speakerID: best.key, share: share)
    }

    static func overlapDuration(_ aStart: TimeInterval, _ aEnd: TimeInterval,
                                _ bStart: TimeInterval, _ bEnd: TimeInterval) -> TimeInterval {
        max(0, min(aEnd, bEnd) - max(aStart, bStart))
    }

    /// Renames one segment's speaker without touching its neighbours, and marks it so
    /// a re-run of diarization will not overwrite the correction.
    public static func relabel(
        segmentID: UUID,
        to speakerID: String?,
        in segments: [TranscriptSegment]
    ) -> [TranscriptSegment] {
        segments.map { segment in
            guard segment.id == segmentID else { return segment }
            var updated = segment
            updated.speakerID = speakerID
            updated.editedByUser = true
            return updated
        }
    }
}

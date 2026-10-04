import Foundation

/// Turns per-frame speaker-activity probabilities into `DiarizedSpan`s.
///
/// End-to-end diarizers (Nemotron 3 / Sortformer) emit a `[frames, speakers]`
/// probability matrix rather than labelled segments. Thresholding it is pure
/// arithmetic, so it lives here and is tested off-device.
///
/// Spans for different speakers may overlap — that is the point of an end-to-end
/// model. `SpeakerAlignment` already resolves each transcript segment to the speaker
/// with the most overlap, so overlap needs no special handling downstream.
public enum SpeakerActivity {

    /// - Parameters:
    ///   - probabilities: Row-major `[frameCount * speakerCount]`.
    ///   - frameSeconds: Duration of one frame.
    ///   - threshold: A speaker is active in a frame when its probability exceeds this.
    ///   - minDuration: Runs shorter than this are dropped as blips.
    ///   - maxGap: Two runs of the same speaker separated by no more than this are
    ///     joined, so a breath does not split a sentence into two spans.
    /// - Returns: Spans sorted by start, labelled `S1`…`Sn` by speaker slot (slots are
    ///   arrival-ordered, so S1 is whoever spoke first). Confidence is the mean
    ///   probability across the span's active frames.
    public static func spans(
        probabilities: [Float],
        frameCount: Int,
        speakerCount: Int,
        frameSeconds: Double,
        threshold: Float = 0.5,
        minDuration: TimeInterval = 0.2,
        maxGap: TimeInterval = 0.15
    ) -> [DiarizedSpan] {
        guard frameCount > 0, speakerCount > 0,
              probabilities.count >= frameCount * speakerCount else { return [] }
        let maxGapFrames = Int((maxGap / frameSeconds).rounded())

        var result: [DiarizedSpan] = []
        for speaker in 0..<speakerCount {
            // Runs as (start frame, end frame exclusive, probability sum, active frames).
            var runs: [(start: Int, end: Int, sum: Double, active: Int)] = []
            var frame = 0
            while frame < frameCount {
                let p = probabilities[frame * speakerCount + speaker]
                guard p > threshold else { frame += 1; continue }
                let start = frame
                var sum = 0.0
                while frame < frameCount {
                    let q = probabilities[frame * speakerCount + speaker]
                    guard q > threshold else { break }
                    sum += Double(q)
                    frame += 1
                }
                if let last = runs.last, start - last.end <= maxGapFrames {
                    runs[runs.count - 1] = (last.start, frame, last.sum + sum, last.active + frame - start)
                } else {
                    runs.append((start, frame, sum, frame - start))
                }
            }
            for run in runs {
                let start = Double(run.start) * frameSeconds
                let end = Double(run.end) * frameSeconds
                guard end - start >= minDuration else { continue }
                result.append(
                    DiarizedSpan(
                        start: start,
                        end: end,
                        speakerID: "S\(speaker + 1)",
                        confidence: run.sum / Double(run.active)
                    )
                )
            }
        }
        return result.sorted { ($0.start, $0.speakerID) < ($1.start, $1.speakerID) }
    }
}

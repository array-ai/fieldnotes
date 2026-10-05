import Foundation

/// Gives each word the speaker who was talking at its midpoint, then cuts lines
/// where the speaker changes — the "midpoint rule" NVIDIA recommends for pairing
/// Nemotron's speaker timeline with a speech model's word timings.
///
/// Why the midpoint: word edges are where the two models disagree most, and the
/// middle of a word is where both are most sure. When two speakers are active at a
/// word's midpoint (overlapping speech), the more confident span wins; the rule
/// can't tell who actually said an overlapped word, and doesn't pretend to.
///
/// Lines without word timings, and lines the user edited, go through the
/// whole-line `SpeakerAlignment` instead. Pure, so it's tested off device.
public enum WordSpeakerSplit {

    /// A run of words this short (seconds, and at most one word) that differs from
    /// its neighbours is treated as noise and joins them. Stops "Speaker B: um" lines
    /// appearing from a blip in the speaker timeline.
    public static let minimumRun: TimeInterval = 0.6

    public static func apply(spans: [DiarizedSpan], to segments: [TranscriptSegment]) -> [TranscriptSegment] {
        guard !spans.isEmpty else { return segments }
        let sorted = spans.sorted { $0.start < $1.start }
        let distinct = Set(spans.map(\.speakerID))
        let sole = distinct.count == 1 ? distinct.first : nil

        var result: [TranscriptSegment] = []
        for segment in segments {
            guard !segment.editedByUser, let words = segment.words, !words.isEmpty else {
                result.append(contentsOf: SpeakerAlignment.apply(spans: spans, to: [segment]))
                continue
            }
            result.append(contentsOf: split(segment, words: words, spans: sorted, sole: sole))
        }
        return result
    }

    static func split(
        _ segment: TranscriptSegment,
        words: [TranscriptWord],
        spans: [DiarizedSpan],
        sole: String?
    ) -> [TranscriptSegment] {
        var speakers = words.map { speaker(at: $0.midpoint, in: spans) ?? sole }
        fillGaps(&speakers)

        var runs = groups(words: words, speakers: speakers)
        smooth(&runs)

        if runs.count <= 1 {
            var single = segment
            single.speakerID = runs.first?.speaker ?? speakers.compactMap { $0 }.first
            return [single]
        }
        return runs.enumerated().map { index, run in
            TranscriptSegment(
                // The first piece keeps the line's identity; the rest are new lines.
                id: index == 0 ? segment.id : UUID(),
                start: run.words.first?.start ?? segment.start,
                end: run.words.last?.end ?? segment.end,
                text: run.words.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines),
                speakerID: run.speaker,
                confidence: segment.confidence,
                isFinalized: segment.isFinalized,
                editedByUser: false,
                words: run.words
            )
        }
    }

    /// The active span at `time`; the most confident one where speakers overlap.
    static func speaker(at time: TimeInterval, in spans: [DiarizedSpan]) -> String? {
        var best: DiarizedSpan?
        for span in spans {
            if span.start > time { break }
            guard span.end >= time else { continue }
            if best == nil || span.confidence > best!.confidence { best = span }
        }
        return best?.speakerID
    }

    /// A word nobody was detected speaking (a pause in the timeline) takes the
    /// speaker before it, or after it at the start of a line.
    static func fillGaps(_ speakers: inout [String?]) {
        var last: String?
        for i in speakers.indices {
            if let speaker = speakers[i] { last = speaker } else { speakers[i] = last }
        }
        var next: String?
        for i in speakers.indices.reversed() {
            if let speaker = speakers[i] { next = speaker } else { speakers[i] = next }
        }
    }

    struct Run {
        var speaker: String?
        var words: [TranscriptWord]
        var duration: TimeInterval {
            guard let first = words.first, let last = words.last else { return 0 }
            return last.end - first.start
        }
    }

    static func groups(words: [TranscriptWord], speakers: [String?]) -> [Run] {
        var runs: [Run] = []
        for (word, speaker) in zip(words, speakers) {
            if let last = runs.last, last.speaker == speaker {
                runs[runs.count - 1].words.append(word)
            } else {
                runs.append(Run(speaker: speaker, words: [word]))
            }
        }
        return runs
    }

    /// Folds one-word blips into a neighbour, then re-joins neighbours that now match.
    static func smooth(_ runs: inout [Run]) {
        guard runs.count > 1 else { return }
        var i = 0
        while i < runs.count {
            let run = runs[i]
            if runs.count > 1, run.words.count <= 1, run.duration < minimumRun {
                if i > 0 {
                    runs[i - 1].words.append(contentsOf: run.words)
                } else {
                    runs[i + 1].words.insert(contentsOf: run.words, at: 0)
                }
                runs.remove(at: i)
                i = max(0, i - 1)
                continue
            }
            i += 1
        }
        var merged: [Run] = []
        for run in runs {
            if let last = merged.last, last.speaker == run.speaker {
                merged[merged.count - 1].words.append(contentsOf: run.words)
            } else {
                merged.append(run)
            }
        }
        runs = merged
    }
}

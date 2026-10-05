import Foundation

/// One map-phase unit: a run of transcript segments small enough to summarise in a
/// single prompt, plus the overlap carried from the previous chunk so a decision made
/// across a chunk boundary is not cut in half.
public struct TranscriptChunk: Sendable, Identifiable {
    public var id: Int { index }
    public var index: Int
    /// Global 1-based line numbers of `segments`, in order. These are what the model
    /// cites, and what `SummaryGrounder` maps back to segment IDs.
    public var lineNumbers: [Int]
    public var segments: [TranscriptSegment]
    /// How many leading segments are overlap carried from the previous chunk.
    public var overlapCount: Int

    public var startTime: TimeInterval { segments.first?.start ?? 0 }
    public var endTime: TimeInterval { segments.last?.end ?? 0 }

    public init(index: Int, lineNumbers: [Int], segments: [TranscriptSegment], overlapCount: Int) {
        self.index = index
        self.lineNumbers = lineNumbers
        self.segments = segments
        self.overlapCount = overlapCount
    }

    /// The numbered transcript the model sees. Numbers are global, so a citation is
    /// unambiguous even though the model only ever sees one chunk at a time.
    public func promptText(speakerNames: [String: String] = [:]) -> String {
        zip(lineNumbers, segments).map { number, segment in
            let speaker = segment.speakerID.map { speakerNames[$0] ?? $0 } ?? "Unknown"
            return "\(number) | \(speaker): \(segment.text)"
        }
        .joined(separator: "\n")
    }

    /// Splits the chunk in two by line count, for a prompt that turned out too big
    /// for the model's context. Both halves keep this chunk's index, so their notes
    /// merge back into one entry for the grounder. Nil when there is only one line.
    public func halves() -> (TranscriptChunk, TranscriptChunk)? {
        guard segments.count > 1 else { return nil }
        let middle = segments.count / 2
        let first = TranscriptChunk(
            index: index,
            lineNumbers: Array(lineNumbers[..<middle]),
            segments: Array(segments[..<middle]),
            overlapCount: min(overlapCount, middle)
        )
        let second = TranscriptChunk(
            index: index,
            lineNumbers: Array(lineNumbers[middle...]),
            segments: Array(segments[middle...]),
            overlapCount: 0
        )
        return (first, second)
    }

    public func segmentID(forLine line: Int) -> UUID? {
        guard let position = lineNumbers.firstIndex(of: line) else { return nil }
        return segments[position].id
    }
}

/// Splits a transcript into chunks against a real token budget.
///
/// The budget is measured, not hardcoded: the context ceiling differs by device, and
/// iOS 26.4 / 27 expose the APIs to ask (spec 4.5). The caller supplies a token
/// counter, which keeps this type pure and testable and keeps the framework call in
/// one place.
public struct TranscriptChunker: Sendable {
    /// Tokens available for transcript text in one prompt, after instructions and
    /// expected output have been subtracted.
    public var budget: Int
    /// Tokens of trailing context to repeat at the head of the next chunk.
    public var overlap: Int
    public var countTokens: @Sendable (String) -> Int

    public init(
        budget: Int,
        overlap: Int,
        countTokens: @escaping @Sendable (String) -> Int = TranscriptChunker.approximateTokenCount
    ) {
        self.budget = max(1, budget)
        self.overlap = max(0, min(overlap, max(1, budget) / 2))
        self.countTokens = countTokens
    }

    /// Rough fallback when no counter is available: ~4 characters per token, floor 1.
    /// Only used in tests and as a last resort — production sizes against the model.
    public static let approximateTokenCount: @Sendable (String) -> Int = { text in
        max(1, Int((Double(text.count) / 4.0).rounded(.up)))
    }

    public func chunks(from segments: [TranscriptSegment]) -> [TranscriptChunk] {
        guard !segments.isEmpty else { return [] }

        // Cost each line once, including its line-number and speaker prefix.
        let costs = segments.enumerated().map { index, segment -> Int in
            let speaker = segment.speakerID ?? "Unknown"
            return countTokens("\(index + 1) | \(speaker): \(segment.text)\n")
        }

        var result: [TranscriptChunk] = []
        var start = 0

        while start < segments.count {
            var end = start
            var used = 0
            while end < segments.count {
                let next = used + costs[end]
                // Always take at least one segment, even if it alone blows the budget.
                if next > budget && end > start { break }
                used = next
                end += 1
            }

            let range = start..<end
            result.append(
                TranscriptChunk(
                    index: result.count,
                    lineNumbers: range.map { $0 + 1 },
                    segments: Array(segments[range]),
                    overlapCount: 0 // filled in by stampOverlapCounts once neighbours are known
                )
            )

            if end >= segments.count { break }

            // Walk back from the chunk end until the overlap budget is spent.
            var back = end
            var overlapUsed = 0
            while back > start + 1 {
                let candidate = overlapUsed + costs[back - 1]
                if candidate > overlap { break }
                overlapUsed = candidate
                back -= 1
            }
            start = max(back, start + 1)
        }

        return stampOverlapCounts(result)
    }

    /// `overlapCount` is only knowable once the following chunk's start is known, so
    /// fill it in afterwards from the line numbers themselves.
    private func stampOverlapCounts(_ chunks: [TranscriptChunk]) -> [TranscriptChunk] {
        var result = chunks
        for index in 1..<max(1, result.count) {
            let previousLines = Set(result[index - 1].lineNumbers)
            result[index].overlapCount = result[index].lineNumbers.prefix { previousLines.contains($0) }.count
        }
        return result
    }
}

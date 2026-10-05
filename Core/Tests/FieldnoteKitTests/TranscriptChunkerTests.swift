import FieldnoteKit
import Foundation
import Testing

@Suite("Transcript chunking")
struct TranscriptChunkerTests {

    private func transcript(lines: Int, words: Int = 10) -> [TranscriptSegment] {
        (0..<lines).map { index in
            TranscriptSegment(
                start: Double(index) * 5,
                end: Double(index) * 5 + 5,
                text: Array(repeating: "word", count: words).joined(separator: " "),
                speakerID: "S\(index % 2 + 1)"
            )
        }
    }

    /// One token per word keeps the arithmetic in these tests obvious.
    private let wordCounter: @Sendable (String) -> Int = { text in
        max(1, text.split(separator: " ").count)
    }

    @Test("Every segment appears in at least one chunk")
    func nothingIsDropped() {
        let segments = transcript(lines: 50)
        let chunker = TranscriptChunker(budget: 60, overlap: 12, countTokens: wordCounter)
        let chunks = chunker.chunks(from: segments)

        let covered = Set(chunks.flatMap(\.lineNumbers))
        #expect(covered.count == segments.count)
        #expect(covered == Set(1...segments.count))
    }

    @Test("Chunks overlap so a point spanning a boundary is seen whole")
    func chunksOverlap() {
        let segments = transcript(lines: 40)
        let chunker = TranscriptChunker(budget: 60, overlap: 24, countTokens: wordCounter)
        let chunks = chunker.chunks(from: segments)

        #expect(chunks.count > 1)
        for index in 1..<chunks.count {
            #expect(chunks[index].overlapCount > 0)
            let previous = Set(chunks[index - 1].lineNumbers)
            #expect(chunks[index].lineNumbers.contains { previous.contains($0) })
        }
    }

    @Test("A single oversized segment becomes its own chunk instead of hanging")
    func oversizedSegmentMakesProgress() {
        let long = TranscriptSegment(
            start: 0,
            end: 60,
            text: Array(repeating: "word", count: 500).joined(separator: " ")
        )
        let chunker = TranscriptChunker(budget: 50, overlap: 10, countTokens: wordCounter)
        let chunks = chunker.chunks(from: [long, TranscriptSegment(start: 60, end: 65, text: "short line")])

        #expect(chunks.count == 2)
        #expect(chunks[0].segments.count == 1)
    }

    @Test("Line numbers are global, so a citation is unambiguous across chunks")
    func lineNumbersAreGlobal() {
        let segments = transcript(lines: 30)
        let chunker = TranscriptChunker(budget: 60, overlap: 12, countTokens: wordCounter)
        let chunks = chunker.chunks(from: segments)

        for chunk in chunks {
            for (number, segment) in zip(chunk.lineNumbers, chunk.segments) {
                #expect(segments[number - 1].id == segment.id)
                #expect(chunk.segmentID(forLine: number) == segment.id)
            }
        }
    }

    @Test("An empty transcript produces no chunks")
    func emptyTranscript() {
        #expect(TranscriptChunker(budget: 100, overlap: 10).chunks(from: []).isEmpty)
    }

    @Test("Prompt text carries the line number and speaker for each line")
    func promptTextIsNumbered() {
        let segments = transcript(lines: 3, words: 2)
        let chunks = TranscriptChunker(budget: 1000, overlap: 0, countTokens: wordCounter).chunks(from: segments)
        let text = chunks[0].promptText(speakerNames: ["S1": "Dave"])

        #expect(text.contains("1 | Dave: word word"))
        #expect(text.contains("2 | Speaker B: word word"))
    }
}

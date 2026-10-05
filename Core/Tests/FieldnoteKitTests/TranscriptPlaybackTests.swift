import FieldnoteKit
import Foundation
import Testing

@Suite("Transcript playback")
struct TranscriptPlaybackTests {

    private let lines = [
        TranscriptSegment(start: 0, end: 4, text: "a"),
        TranscriptSegment(start: 5, end: 9, text: "b"),
        TranscriptSegment(start: 30, end: 35, text: "c"),
    ]

    @Test("The line that has started is current")
    func current() {
        #expect(TranscriptPlayback.currentIndex(at: 2, in: lines) == 0)
        #expect(TranscriptPlayback.currentIndex(at: 5, in: lines) == 1)
        #expect(TranscriptPlayback.currentIndex(at: 31, in: lines) == 2)
    }

    @Test("A short pause keeps the previous line; a long silence clears it")
    func pauses() {
        #expect(TranscriptPlayback.currentIndex(at: 4.5, in: lines) == 0)
        #expect(TranscriptPlayback.currentIndex(at: 11, in: lines) == 1)
        #expect(TranscriptPlayback.currentIndex(at: 20, in: lines) == nil)
    }

    @Test("Before the first line, or with no lines, nothing is current")
    func edges() {
        #expect(TranscriptPlayback.currentIndex(at: 1, in: [TranscriptSegment(start: 2, end: 3, text: "x")]) == nil)
        #expect(TranscriptPlayback.currentIndex(at: 1, in: []) == nil)
    }
}

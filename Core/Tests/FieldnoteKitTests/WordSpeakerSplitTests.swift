import FieldnoteKit
import Foundation
import Testing

@Suite("Per-word speaker split")
struct WordSpeakerSplitTests {

    /// Words one second apart, each 0.8 s long: word i covers i...i+0.8.
    private func line(_ text: String, start: TimeInterval = 0) -> TranscriptSegment {
        let tokens = text.split(separator: " ").map(String.init)
        let words = tokens.enumerated().map { i, token in
            TranscriptWord(text: token + (i < tokens.count - 1 ? " " : ""), start: start + Double(i), end: start + Double(i) + 0.8)
        }
        return TranscriptSegment(start: start, end: start + Double(tokens.count), text: text, words: words)
    }

    @Test("A line where the speaker changes is cut at the change")
    func splitsAtChange() {
        let spans = [
            DiarizedSpan(start: 0, end: 2.5, speakerID: "S1"),
            DiarizedSpan(start: 2.5, end: 6, speakerID: "S2"),
        ]
        let original = line("so that's settled okay thanks Dave")
        let result = WordSpeakerSplit.apply(spans: spans, to: [original])
        #expect(result.map(\.text) == ["so that's settled", "okay thanks Dave"])
        #expect(result.map(\.speakerID) == ["S1", "S2"])
        #expect(result.first?.id == original.id)
        #expect(result[1].start == 3)
    }

    @Test("A short one-word blip doesn't make its own line")
    func smoothsBlips() {
        // "a" is 0.2 s long and its midpoint (2.1) is the only one in S2.
        var segment = line("one two a four five")
        segment.words?[2] = TranscriptWord(text: "a ", start: 2.0, end: 2.2)
        let spans = [
            DiarizedSpan(start: 0, end: 2.05, speakerID: "S1"),
            DiarizedSpan(start: 2.05, end: 2.15, speakerID: "S2"),
            DiarizedSpan(start: 2.15, end: 6, speakerID: "S1"),
        ]
        let result = WordSpeakerSplit.apply(spans: spans, to: [segment])
        #expect(result.count == 1)
        #expect(result.first?.speakerID == "S1")
    }

    @Test("A real one-word reply keeps its own line")
    func keepsShortReplies() {
        let spans = [
            DiarizedSpan(start: 0, end: 2, speakerID: "S1"),
            DiarizedSpan(start: 2, end: 2.9, speakerID: "S2"),
            DiarizedSpan(start: 2.9, end: 6, speakerID: "S1"),
        ]
        let result = WordSpeakerSplit.apply(spans: spans, to: [line("did you agree yes good")])
        #expect(result.map(\.speakerID) == ["S1", "S2", "S1"])
        #expect(result[1].text == "agree")
    }

    @Test("Overlapping speech goes to the more confident speaker")
    func overlap() {
        let spans = [
            DiarizedSpan(start: 0, end: 5, speakerID: "S1", confidence: 0.6),
            DiarizedSpan(start: 0, end: 5, speakerID: "S2", confidence: 0.9),
        ]
        #expect(WordSpeakerSplit.apply(spans: spans, to: [line("both talking here")]).first?.speakerID == "S2")
    }

    @Test("Words in a pause take the speaker before them")
    func gaps() {
        let spans = [DiarizedSpan(start: 0, end: 1.5, speakerID: "S1"), DiarizedSpan(start: 10, end: 12, speakerID: "S2")]
        let result = WordSpeakerSplit.apply(spans: spans, to: [line("one two three")])
        #expect(result.count == 1)
        #expect(result.first?.speakerID == "S1")
    }

    @Test("Edited lines and lines without words use whole-line alignment")
    func fallbacks() {
        let spans = [DiarizedSpan(start: 0, end: 10, speakerID: "S2")]
        var edited = line("keep me whole")
        edited.editedByUser = true
        edited.speakerID = "S1"
        let plain = TranscriptSegment(start: 0, end: 3, text: "no words here")
        let result = WordSpeakerSplit.apply(spans: spans, to: [edited, plain])
        #expect(result.count == 2)
        #expect(result[0].speakerID == "S1")
        #expect(result[1].speakerID == "S2")
    }

    @Test("Running it twice changes nothing")
    func idempotent() {
        let spans = [DiarizedSpan(start: 0, end: 2.5, speakerID: "S1"), DiarizedSpan(start: 2.5, end: 6, speakerID: "S2")]
        let once = WordSpeakerSplit.apply(spans: spans, to: [line("so that's settled okay thanks Dave")])
        let twice = WordSpeakerSplit.apply(spans: spans, to: once)
        #expect(twice.map(\.text) == once.map(\.text))
        #expect(twice.map(\.speakerID) == once.map(\.speakerID))
    }

    @Test("Transcripts stored before words existed still decode")
    func oldSegmentsDecode() throws {
        let old = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","start":0,"end":1,"text":"hi","confidence":1,"isFinalized":true,"editedByUser":false}"#
        let decoded = try JSONDecoder().decode(TranscriptSegment.self, from: Data(old.utf8))
        #expect(decoded.words == nil)
    }
}

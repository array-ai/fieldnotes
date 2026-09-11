import FieldnoteKit
import Foundation
import Testing

@Suite("Speaker alignment")
struct SpeakerAlignmentTests {

    private func segment(_ start: TimeInterval, _ end: TimeInterval, _ text: String = "line") -> TranscriptSegment {
        TranscriptSegment(start: start, end: end, text: text)
    }

    @Test("Each segment takes the speaker with the most overlap")
    func greatestOverlapWins() {
        let segments = [segment(0, 10)]
        let spans = [
            DiarizedSpan(start: 0, end: 3, speakerID: "S1"),
            DiarizedSpan(start: 3, end: 10, speakerID: "S2")
        ]
        let result = SpeakerAlignment.apply(spans: spans, to: segments)
        #expect(result[0].speakerID == "S2")
    }

    @Test("A segment with no overlapping span stays unknown rather than being guessed")
    func noOverlapStaysNil() {
        let segments = [segment(100, 105)]
        let spans = [DiarizedSpan(start: 0, end: 10, speakerID: "S1")]
        let result = SpeakerAlignment.apply(spans: spans, to: segments)
        #expect(result[0].speakerID == nil)
    }

    @Test("Ties resolve the same way every run")
    func tiesAreDeterministic() {
        let segments = [segment(0, 10)]
        let spans = [
            DiarizedSpan(start: 0, end: 5, speakerID: "S2"),
            DiarizedSpan(start: 5, end: 10, speakerID: "S1")
        ]
        let first = SpeakerAlignment.apply(spans: spans, to: segments)
        let second = SpeakerAlignment.apply(spans: spans.reversed(), to: segments)
        #expect(first[0].speakerID == second[0].speakerID)
        #expect(first[0].speakerID == "S1")
    }

    @Test("A manually relabelled line survives a re-run of diarization")
    func manualEditsSurvive() {
        var manual = segment(0, 10)
        manual.speakerID = "S3"
        manual.editedByUser = true
        let spans = [DiarizedSpan(start: 0, end: 10, speakerID: "S1")]
        let result = SpeakerAlignment.apply(spans: spans, to: [manual])
        #expect(result[0].speakerID == "S3")
    }

    @Test("Relabelling one line does not disturb its neighbours")
    func relabelIsLocal() {
        let segments = [segment(0, 5, "a"), segment(5, 10, "b"), segment(10, 15, "c")]
        let laid = SpeakerAlignment.apply(
            spans: [DiarizedSpan(start: 0, end: 15, speakerID: "S1")],
            to: segments
        )
        let changed = SpeakerAlignment.relabel(segmentID: laid[1].id, to: "S2", in: laid)

        #expect(changed[0].speakerID == "S1")
        #expect(changed[1].speakerID == "S2")
        #expect(changed[2].speakerID == "S1")
        #expect(changed[1].editedByUser)
        #expect(!changed[0].editedByUser)
    }

    @Test("Partial overlap lowers the segment's confidence")
    func partialOverlapLowersConfidence() {
        let segments = [segment(0, 10)]
        let spans = [DiarizedSpan(start: 0, end: 4, speakerID: "S1")]
        let result = SpeakerAlignment.apply(spans: spans, to: segments)
        #expect(result[0].speakerID == "S1")
        #expect(result[0].confidence < 0.5)
    }
}

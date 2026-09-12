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

    @Test("A segment with no overlapping span stays unknown when more than one speaker is genuinely possible")
    func noOverlapStaysNilWhenAmbiguous() {
        let segments = [segment(100, 105)]
        let spans = [
            DiarizedSpan(start: 0, end: 10, speakerID: "S1"),
            DiarizedSpan(start: 20, end: 30, speakerID: "S2")
        ]
        let result = SpeakerAlignment.apply(spans: spans, to: segments)
        #expect(result[0].speakerID == nil)
    }

    @Test("A segment with no overlapping span falls back to the sole speaker when only one was ever detected")
    func noOverlapFallsBackToSoleSpeaker() {
        // Matches a real report: a solo test recording where a short, quiet utterance
        // after a gap (starting with "Um,") wasn't covered by any diarized span, and
        // came back "Unknown" even though the whole rest of the recording was one
        // person. There is no second candidate to guess wrong about.
        let segments = [segment(100, 105)]
        let spans = [DiarizedSpan(start: 0, end: 10, speakerID: "S1")]
        let result = SpeakerAlignment.apply(spans: spans, to: segments)
        #expect(result[0].speakerID == "S1")
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

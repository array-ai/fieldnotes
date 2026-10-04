import FieldnoteKit
import Foundation
import Testing

@Suite("Speaker activity")
struct SpeakerActivityTests {

    /// Builds a `[frames, speakers]` matrix from per-speaker activity strings, one
    /// character per frame: `#` is 0.9, `+` is 0.6, anything else is 0.1.
    private func matrix(_ rows: [String]) -> (probabilities: [Float], frames: Int) {
        let frames = rows.map(\.count).max() ?? 0
        var probabilities = [Float](repeating: 0.1, count: frames * rows.count)
        for (speaker, row) in rows.enumerated() {
            for (frame, character) in row.enumerated() {
                let value: Float = switch character {
                case "#": 0.9
                case "+": 0.6
                default: 0.1
                }
                probabilities[frame * rows.count + speaker] = value
            }
        }
        return (probabilities, frames)
    }

    @Test("A run above threshold becomes one span, labelled by slot")
    func singleRun() {
        let (p, frames) = matrix(["..####....", ".........."])
        let spans = SpeakerActivity.spans(
            probabilities: p, frameCount: frames, speakerCount: 2,
            frameSeconds: 0.1, minDuration: 0, maxGap: 0
        )
        #expect(spans.count == 1)
        #expect(spans.first?.speakerID == "S1")
        #expect(abs((spans.first?.start ?? 0) - 0.2) < 1e-9)
        #expect(abs((spans.first?.end ?? 0) - 0.6) < 1e-9)
    }

    @Test("Overlapping speakers both get spans")
    func overlap() {
        let (p, frames) = matrix(["######....", "....######"])
        let spans = SpeakerActivity.spans(
            probabilities: p, frameCount: frames, speakerCount: 2,
            frameSeconds: 0.1, minDuration: 0, maxGap: 0
        )
        #expect(spans.map(\.speakerID) == ["S1", "S2"])
    }

    @Test("Short gaps join, long gaps split")
    func gapJoining() {
        let (p, frames) = matrix(["###.###....###"])
        let spans = SpeakerActivity.spans(
            probabilities: p, frameCount: frames, speakerCount: 1,
            frameSeconds: 0.1, minDuration: 0, maxGap: 0.1
        )
        #expect(spans.count == 2)
        #expect(abs((spans.first?.end ?? 0) - 0.7) < 1e-9)
    }

    @Test("Blips shorter than the minimum are dropped")
    func minDuration() {
        let (p, frames) = matrix(["#.........#####"])
        let spans = SpeakerActivity.spans(
            probabilities: p, frameCount: frames, speakerCount: 1,
            frameSeconds: 0.1, minDuration: 0.3, maxGap: 0
        )
        #expect(spans.count == 1)
        #expect(abs((spans.first?.start ?? 0) - 1.0) < 1e-9)
    }

    @Test("Confidence is the mean probability over active frames")
    func confidence() {
        let (p, frames) = matrix(["##++"])
        let spans = SpeakerActivity.spans(
            probabilities: p, frameCount: frames, speakerCount: 1,
            frameSeconds: 0.1, minDuration: 0, maxGap: 0
        )
        #expect(abs((spans.first?.confidence ?? 0) - 0.75) < 1e-6)
    }

    @Test("A short or empty matrix yields nothing rather than trapping")
    func malformed() {
        #expect(SpeakerActivity.spans(probabilities: [], frameCount: 0, speakerCount: 8, frameSeconds: 0.01).isEmpty)
        #expect(SpeakerActivity.spans(probabilities: [0.9], frameCount: 4, speakerCount: 8, frameSeconds: 0.01).isEmpty)
    }
}

@Suite("Diarization method")
struct DiarizationMethodTests {

    @Test("Missing or unknown stored values fall back to the default")
    func fallback() {
        #expect(DiarizationMethod(storedValue: nil) == .default)
        #expect(DiarizationMethod(storedValue: "somethingRemoved") == .default)
        #expect(DiarizationMethod(storedValue: "pyannoteLegacy") == .pyannoteLegacy)
    }

    @Test("Stored raw values are stable")
    func rawValues() {
        // These are persisted in UserDefaults. Renaming a case silently resets every
        // user's choice to the default.
        #expect(DiarizationMethod.allCases.map(\.rawValue) == ["nemotron3", "pyannoteCommunity1", "pyannoteLegacy"])
    }
}

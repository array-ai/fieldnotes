import FieldnoteKit
import Foundation
import Testing

@Suite("Processing estimate")
struct ProcessingEstimatorTests {

    private let all = ProcessingEstimator.Work(transcribes: true, diarizes: true)

    @Test("Longer audio takes longer")
    func scalesWithAudio() {
        let estimator = ProcessingEstimator()
        #expect(estimator.remaining(from: .transcribing, audio: 3_600, work: all)
                > estimator.remaining(from: .transcribing, audio: 600, work: all))
    }

    @Test("Stages with nothing to do are near-instant")
    func skippedStages() {
        let estimator = ProcessingEstimator()
        let live = ProcessingEstimator.Work(transcribes: false, diarizes: false)
        #expect(estimator.seconds(for: .transcribing, audio: 3_600, work: live) == 1)
        #expect(estimator.remaining(from: .transcribing, audio: 3_600, work: live)
                < estimator.remaining(from: .transcribing, audio: 3_600, work: all))
    }

    @Test("Remaining time shrinks as stages complete")
    func remainingShrinks() {
        let estimator = ProcessingEstimator()
        #expect(estimator.remaining(from: .summarising, audio: 1_200, work: all)
                < estimator.remaining(from: .diarizing, audio: 1_200, work: all))
    }

    @Test("Measurements pull the rate toward what this phone does")
    func learns() {
        var estimator = ProcessingEstimator()
        let before = estimator.seconds(for: .summarising, audio: 600, work: all)
        // Ten minutes of audio summarised in 30 s: much faster than the default.
        for _ in 0..<10 { estimator.record(.summarising, elapsed: 30, audio: 600) }
        let after = estimator.seconds(for: .summarising, audio: 600, work: all)
        #expect(after < before)
        #expect(abs(after - 30) < 3)
    }

    @Test("Very short recordings don't skew the rate")
    func ignoresTiny() {
        var estimator = ProcessingEstimator()
        estimator.record(.summarising, elapsed: 40, audio: 6)
        #expect(estimator == ProcessingEstimator())
    }

    @Test("Round-trips through JSON")
    func codable() throws {
        var estimator = ProcessingEstimator()
        estimator.record(.diarizing, elapsed: 20, audio: 300)
        let data = try JSONEncoder().encode(estimator)
        #expect(try JSONDecoder().decode(ProcessingEstimator.self, from: data) == estimator)
    }

    @Test("Durations read loosely")
    func rough() {
        #expect(TimeInterval(20).roughDuration == "under a minute")
        #expect(TimeInterval(70).roughDuration == "about a minute")
        #expect(TimeInterval(300).roughDuration == "about 5 min")
    }
}

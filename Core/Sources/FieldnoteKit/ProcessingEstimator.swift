import Foundation

/// Estimates how long processing will take, from how long it has taken on this
/// phone before.
///
/// Each stage is modelled as a fixed cost (loading models, starting sessions) plus a
/// rate per minute of audio. Both start from conservative defaults and are then
/// learned: after every stage that really ran, the measured time nudges the rate
/// with an exponential moving average, so the estimate settles on this hardware
/// within a few meetings and still follows changes such as a new speaker method.
///
/// Pure and `Codable`, so it is stored as-is and tested off device.
public struct ProcessingEstimator: Codable, Sendable, Equatable {

    public struct Rate: Codable, Sendable, Equatable {
        /// Seconds regardless of length.
        public var fixed: Double
        /// Seconds per minute of audio.
        public var perMinute: Double

        public func seconds(forAudio audio: TimeInterval) -> Double {
            fixed + perMinute * audio / 60
        }
    }

    public var rates: [ProcessingStage: Rate]
    /// How much one new measurement moves the estimate, 0...1.
    public var learningRate: Double

    public init(
        rates: [ProcessingStage: Rate] = ProcessingEstimator.defaults,
        learningRate: Double = 0.4
    ) {
        self.rates = rates
        self.learningRate = learningRate
    }

    /// Starting guesses, before this phone has finished a meeting.
    public static let defaults: [ProcessingStage: Rate] = [
        .transcribing: Rate(fixed: 3, perMinute: 4),
        .diarizing: Rate(fixed: 8, perMinute: 1.5),
        .summarising: Rate(fixed: 10, perMinute: 12),
    ]

    /// Which stages actually have work to do. A stage covered by the live transcript,
    /// by live speaker identification, or by a checkpoint is near-instant.
    public struct Work: Sendable, Equatable {
        public var transcribes: Bool
        public var diarizes: Bool
        public var summarises: Bool

        public init(transcribes: Bool, diarizes: Bool, summarises: Bool = true) {
            self.transcribes = transcribes
            self.diarizes = diarizes
            self.summarises = summarises
        }

        public func includes(_ stage: ProcessingStage) -> Bool {
            switch stage {
            case .transcribing: transcribes
            case .diarizing: diarizes
            case .summarising: summarises
            }
        }
    }

    /// Seconds one stage is expected to take.
    public func seconds(for stage: ProcessingStage, audio: TimeInterval, work: Work) -> Double {
        guard work.includes(stage) else { return 1 }
        return (rates[stage] ?? Self.defaults[stage] ?? Rate(fixed: 5, perMinute: 5)).seconds(forAudio: audio)
    }

    /// Seconds from the start of `stage` to the end of processing.
    public func remaining(from stage: ProcessingStage, audio: TimeInterval, work: Work) -> Double {
        ProcessingStage.allCases
            .filter { $0 >= stage }
            .reduce(0) { $0 + seconds(for: $1, audio: audio, work: work) }
    }

    /// Folds in a measured stage. Only the per-minute rate learns: the fixed part is
    /// too entangled with it to separate from one measurement, and the rate is what
    /// differs most between phones.
    public mutating func record(_ stage: ProcessingStage, elapsed: TimeInterval, audio: TimeInterval) {
        guard elapsed > 0, audio >= 30 else { return }
        var rate = rates[stage] ?? Self.defaults[stage] ?? Rate(fixed: 5, perMinute: 5)
        let measured = max(0, elapsed - rate.fixed) / (audio / 60)
        rate.perMinute += learningRate * (measured - rate.perMinute)
        rates[stage] = rate
    }
}

extension TimeInterval {
    /// "about 3 min", "under a minute": loose on purpose, it's an estimate.
    public var roughDuration: String {
        switch self {
        case ..<60: "under a minute"
        case ..<90: "about a minute"
        case ..<3_600: "about \(Int((self / 60).rounded())) min"
        default:
            String(format: "about %.1f h", self / 3_600)
        }
    }
}

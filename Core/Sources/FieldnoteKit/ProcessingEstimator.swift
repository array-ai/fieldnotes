import Foundation

/// Estimates how long processing will take, from how long it has taken on this
/// phone before.
///
/// Each stage is modelled as a fixed cost (loading models, starting sessions) plus a
/// rate per minute of audio. Rates are kept per model, since Parakeet and Apple's
/// speech model, or MiniCPM5 and Apple's language model, differ several-fold. Each starts
/// from a default measured on an iPhone 16 (see `defaultRate`) and is then learned:
/// after every stage that really ran, the measured time nudges that model's rate with
/// an exponential moving average, so the estimate settles on this hardware within a
/// few meetings.
///
/// Pure and `Codable`, so it is stored as-is and tested off device.
public struct ProcessingEstimator: Codable, Sendable, Equatable {

    public struct Rate: Codable, Sendable, Equatable {
        /// Seconds regardless of length.
        public var fixed: Double
        /// Seconds per minute of audio.
        public var perMinute: Double

        public init(fixed: Double, perMinute: Double) {
            self.fixed = fixed
            self.perMinute = perMinute
        }

        public func seconds(forAudio audio: TimeInterval) -> Double {
            fixed + perMinute * audio / 60
        }
    }

    /// Learned rates, keyed by stage and model ("transcribing/parakeetCtc110m").
    public var learned: [String: Rate]
    /// How much one new measurement moves the estimate, 0...1.
    public var learningRate: Double
    /// The model each stage runs with this time (a `TranscriptionEngine`,
    /// `DiarizationMethod` or `SummaryEngine` raw value). Not stored: set per run.
    public var models: [ProcessingStage: String] = [:]

    private enum CodingKeys: String, CodingKey { case learned, learningRate }

    public init(models: [ProcessingStage: String] = [:], learningRate: Double = 0.4) {
        self.learned = [:]
        self.models = models
        self.learningRate = learningRate
    }

    /// Starting guesses before this phone has run a model, in seconds per minute of
    /// audio. Measured on an iPhone 16 (iPhone17,3), iOS 27.0.1, app in front:
    ///
    /// - Apple speech, from the audio files: 18.6 min in 80 s (4.3 s/min).
    /// - Parakeet TDT-CTC 110M: 68 min in 49 s and 18.6 min in 5 s (0.3–0.7 s/min).
    ///   Parakeet v3 and v2 (0.6B) aren't measured yet; ~3× the 110M model.
    ///   Nemotron 3.5 Streaming runs while recording; from a file it's unmeasured.
    /// - Nemotron on the Neural Engine: 68 min in 33 s (0.5 s/min). Its one-off
    ///   compile (25–40 s on first use) is not counted: it happens once per install.
    /// - pyannote community-1: 5 min in 1.4 s.
    /// - Apple's language model: 18.6 min summarised in 290 s (15.6 s/min) at
    ///   ~35 tokens/s; on a hot or locked phone it ran at ~10 tokens/s (~30 s/min).
    ///   MiniCPM5 1B isn't measured yet.
    public static func defaultRate(_ stage: ProcessingStage, model: String?) -> Rate {
        switch (stage, model) {
        case (.transcribing, "parakeetCtc110m"): Rate(fixed: 5, perMinute: 0.8)
        case (.transcribing, "parakeet"), (.transcribing, "parakeetV2"): Rate(fixed: 8, perMinute: 2)
        // Only when the live transcript is missing (imports, redo); unmeasured.
        case (.transcribing, "nemotronStreaming"): Rate(fixed: 10, perMinute: 1.5)
        case (.transcribing, _): Rate(fixed: 3, perMinute: 4.5)
        case (.diarizing, "pyannoteCommunity1"): Rate(fixed: 3, perMinute: 0.6)
        case (.diarizing, _): Rate(fixed: 3, perMinute: 0.6)
        case (.summarising, "minicpm5"): Rate(fixed: 15, perMinute: 12)
        case (.summarising, _): Rate(fixed: 10, perMinute: 18)
        }
    }

    private func key(_ stage: ProcessingStage) -> String {
        "\(stage.rawValue)/\(models[stage] ?? "default")"
    }

    public func rate(for stage: ProcessingStage) -> Rate {
        learned[key(stage)] ?? Self.defaultRate(stage, model: models[stage])
    }

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
        return rate(for: stage).seconds(forAudio: audio)
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
        var rate = rate(for: stage)
        let measured = max(0, elapsed - rate.fixed) / (audio / 60)
        rate.perMinute += learningRate * (measured - rate.perMinute)
        learned[key(stage)] = rate
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

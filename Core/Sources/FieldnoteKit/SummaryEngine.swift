import Foundation

/// Which on-device model writes the notes.
///
/// Apple's model is built in, with a 4,096-token context, and is rate-limited for
/// background work on battery. MiniCPM5 1B and 2B are optional downloads run through
/// Apple's Core AI runtime: the same context, and not rate-limited like Apple's. All
/// run entirely on the phone.
public enum SummaryEngine: String, Codable, CaseIterable, Sendable {
    case apple
    case minicpm5
    case minicpm5_2b
    case qwen3_5_2b

    public static let defaultsKey = "summaryEngine"
    /// This phone's Core AI chip family, stored by the app at launch (Core AI
    /// itself isn't available to this package).
    public static let deviceArchitectureKey = "coreAIDeviceArchitecture"

    public init(storedValue: String?) {
        self = storedValue.flatMap(SummaryEngine.init(rawValue:)) ?? .apple
    }

    public var modelPack: ModelPack.ID? {
        switch self {
        case .apple: nil
        // The build compiled for this phone if there is one and it works; else the
        // portable model, which the phone compiles itself (`CompiledFallback`).
        case .minicpm5:
            CompiledFallback.pack(for: .minicpm5, architecture: UserDefaults.standard.string(forKey: Self.deviceArchitectureKey))
        case .minicpm5_2b:
            CompiledFallback.pack(for: .minicpm5_2b, architecture: UserDefaults.standard.string(forKey: Self.deviceArchitectureKey))
        case .qwen3_5_2b:
            CompiledFallback.pack(for: .qwen3_5_2b, architecture: UserDefaults.standard.string(forKey: Self.deviceArchitectureKey))
        }
    }


    /// Ratings as in `ModelCard`, from a 68-minute meeting on an iPhone 16 (build 41):
    /// - Apple: 15 min; detailed, but much of it was transcript fragments (40 "open
    ///   questions", most not questions) before `NoteQuality` filtered them.
    /// - MiniCPM5 1B: 1.6 min; sometimes returns the transcript instead of notes, and
    ///   finds few tasks or decisions.
    /// - MiniCPM5 2B: 3 min (build 45); the cleanest notes (real questions,
    ///   decisions, owners), 17 sections and 53 points.
    public var card: ModelCard {
        switch self {
        case .apple:
            // iPhone 16, build 63: the most exact notes on a 5½-minute meeting (38 s);
            // 8½ minutes for a 68-minute one, with facts listed as decisions.
            ModelCard(
                title: "Apple Intelligence model",
                summary: "Built in. The most exact notes on short meetings in our tests, but slow on long ones (8½ minutes for an hour), and rate-limited in the background.",
                accuracy: 0.8, speed: 0.3, languages: "Many languages", runs: "In the app, or while charging")
        case .minicpm5:
            // iPhone 16, build 63: 22 s and one point for a 5½-minute meeting; 3 min for
            // a 68-minute one, in many small sections.
            ModelCard(
                title: "MiniCPM5 1B",
                summary: "OpenBMB's small open model on Apple's Core AI. Very fast, but thin notes on short meetings and scattered ones on long meetings.",
                accuracy: 0.35, speed: 0.95, languages: "English and Chinese best", runs: "In the app, or while charging")
        case .minicpm5_2b:
            // iPhone 16, build 63: a 68-minute meeting in 3¼ minutes, 2½ times faster
            // than Apple's model, with the most faithful decisions; a 5½-minute one in
            // 44 s, thinner than Apple's model.
            ModelCard(
                title: "MiniCPM5 2B",
                summary: "Recommended for long meetings: an hour's notes in about 3 minutes, faster than Apple's model and the most careful about what was actually decided. On short meetings Apple's model is more exact.",
                accuracy: 0.7, speed: 0.75, languages: "English and Chinese best", runs: "In the app, or while charging")
        case .qwen3_5_2b:
            // iPhone 16, build 63: 14 points in 3½ min for a 5½-minute meeting (one
            // point under greedy decoding before); 42½ min for a 68-minute meeting, on
            // a phone already warm from earlier benchmarks, so possibly throttled.
            ModelCard(
                title: "Qwen3.5 2B",
                summary: "Alibaba's small model. Detailed notes on short meetings, but slow: about 40 minutes for an hour-long meeting in our test. A 3 GB download.",
                accuracy: 0.55, speed: 0.1, languages: "Many languages", runs: "In the app, or while charging")
        }
    }

    /// Runs through Core AI from a download (not Apple's built-in model).
    public var isLocal: Bool { self != .apple }

    /// How a downloaded model is run for notes; nil for Apple's model, which keeps
    /// its own structured prompts and settings.
    public var notesProfile: NotesProfile? {
        switch self {
        case .apple:
            nil
        case .minicpm5, .minicpm5_2b:
            NotesProfile(temperature: 0.5, answerTokens: 1_000, format: .labelled)
        case .qwen3_5_2b:
            NotesProfile(temperature: 0.5, answerTokens: 1_000, format: .labelled)
        }
    }
}

/// Settings for writing notes with one downloaded model. Each model behaves
/// differently, so each gets its own.
///
/// - `temperature`: Core AI's `CoreAILanguageModel` reads only the temperature from
///   the generation options, and without one decodes greedily, which made Qwen3.5
///   and LFM2.5 repeat a line until the answer ran out (one point for a meeting,
///   build 62). It samples over the whole vocabulary: no top-k or top-p, so the
///   models' own recommended 1.0 (meant with top-p/top-k) is too loose; 0.5 keeps the
///   notes close to the transcript.
/// - `answerTokens`: room for each part's notes; 600 cut answers off mid-list.
/// - `partTokens`: transcript per part, if smaller than what fits. Unset: smaller
///   parts add detail but also mistakes.
/// - `format`: the labelled TOPIC/TASK lines, or plain Markdown notes for a model
///   that won't follow the labels (LFM2.5, offered until build 63, wrote headlines
///   with no points). No model uses it now.
public struct NotesProfile: Sendable, Equatable {
    public enum Format: Sendable, Equatable {
        case labelled
        case markdown
    }

    public var temperature: Double
    public var answerTokens: Int
    public var partTokens: Int?
    public var format: Format

    public init(temperature: Double, answerTokens: Int, partTokens: Int? = nil, format: Format) {
        self.temperature = temperature
        self.answerTokens = answerTokens
        self.partTokens = partTokens
        self.format = format
    }
}

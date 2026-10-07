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
    case lfm2_5

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
        case .lfm2_5:
            CompiledFallback.pack(for: .lfm2_5, architecture: UserDefaults.standard.string(forKey: Self.deviceArchitectureKey))
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
            ModelCard(
                title: "Apple Intelligence model",
                summary: "Built in. Detailed notes, the most points, but slow on long meetings and rate-limited in the background.",
                accuracy: 0.65, speed: 0.3, languages: "Many languages", runs: "In the app, or while charging")
        case .minicpm5:
            ModelCard(
                title: "MiniCPM5 1B",
                summary: "OpenBMB's small open model on Apple's Core AI. Very fast; thinner notes, and few tasks or decisions.",
                accuracy: 0.4, speed: 0.95, languages: "English and Chinese best", runs: "In the app, or while charging")
        case .minicpm5_2b:
            ModelCard(
                title: "MiniCPM5 2B",
                summary: "Recommended. The clearest notes in our tests: real questions, decisions and owners, and five times faster than Apple's model on long meetings.",
                accuracy: 0.8, speed: 0.75, languages: "English and Chinese best", runs: "In the app, or while charging")
        case .qwen3_5_2b:
            // DeviceMark (iPhone 17 Pro): IFEval 0.69, MMLU-Pro 0.51, 29 tokens/s. Qwen3
            // 4B, offered before, ran the iPhone 16 out of memory while preparing.
            // Not yet measured on this phone: ratings are placeholders until it is.
            ModelCard(
                title: "Qwen3.5 2B",
                summary: "Alibaba's small model: more general knowledge than LFM2.5, slower and a bigger download. Not yet tested on this phone.",
                accuracy: 0.7, speed: 0.6, languages: "Many languages", runs: "In the app, or while charging")
        case .lfm2_5:
            // DeviceMark (iPhone 17 Pro, 4,096-token cap): the best on-device model for
            // following instructions (IFEval 0.88; Apple's built-in 0.82), 45.5 tokens/s.
            // Not yet measured on this phone: ratings are placeholders until it is.
            ModelCard(
                title: "LFM2.5 1.2B",
                summary: "Liquid AI's small model, the best at following instructions of the on-device models DeviceMark tested, Apple's included. Fast; not yet tested on this phone.",
                accuracy: 0.75, speed: 0.9, languages: "English best; several others", runs: "In the app, or while charging")
        }
    }

    /// Runs through Core AI from a download (not Apple's built-in model).
    public var isLocal: Bool { self != .apple }
}

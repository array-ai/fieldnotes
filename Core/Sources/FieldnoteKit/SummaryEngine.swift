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
        // The build compiled for this phone if there is one; else the portable model,
        // which the phone compiles itself.
        case .minicpm5:
            ModelPack.ID.minicpm5.compiled(for: UserDefaults.standard.string(forKey: Self.deviceArchitectureKey)) ?? .minicpm5
        case .minicpm5_2b:
            ModelPack.ID.minicpm5_2b.compiled(for: UserDefaults.standard.string(forKey: Self.deviceArchitectureKey)) ?? .minicpm5_2b
        }
    }

    /// Ratings as in `ModelCard`, from a 68-minute meeting on an iPhone 16 (build 41):
    /// - Apple: 15 min; detailed, but much of it was transcript fragments (40 "open
    ///   questions", most not questions) before `NoteQuality` filtered them.
    /// - MiniCPM5 1B: 1.6 min; sometimes returns the transcript instead of notes, and
    ///   finds few tasks or decisions.
    /// - MiniCPM5 2B: 7.5 min; the cleanest notes (real questions, decisions, owners),
    ///   but fewer points per section.
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
                summary: "The larger MiniCPM5. The cleanest notes: real questions, decisions and owners. Twice as fast as Apple's model on long meetings.",
                accuracy: 0.75, speed: 0.6, languages: "English and Chinese best", runs: "In the app, or while charging")
        }
    }

    /// Runs through Core AI from a download (not Apple's built-in model).
    public var isLocal: Bool { self != .apple }
}

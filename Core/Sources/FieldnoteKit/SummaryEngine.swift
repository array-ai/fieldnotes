import Foundation

/// Which on-device model writes the notes.
///
/// Apple's model is built in, with a 4,096-token context, and is rate-limited for
/// background work on battery. MiniCPM5 1B is an optional download run through Apple's
/// Core AI runtime: the same context, and not rate-limited like Apple's. Both run
/// entirely on the phone.
public enum SummaryEngine: String, Codable, CaseIterable, Sendable {
    case apple
    case minicpm5

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
        }
    }

    /// Ratings as in `ModelCard`: relative, and for MiniCPM5 an estimate until it's
    /// been benchmarked on this phone. Speed for Apple's model is the iPhone 16
    /// benchmark (~34 tokens/s); MiniCPM5 1B publishes ~77 tokens/s on an iPhone 17 Pro
    /// Neural Engine. Accuracy: a 1B model against Apple's ~3B, so a little lower.
    public var card: ModelCard {
        switch self {
        case .apple:
            ModelCard(
                title: "Apple Intelligence model",
                summary: "Built in. 4,096-token context, so long meetings are summarised in parts.",
                accuracy: 0.7, speed: 0.6, languages: "Many languages", runs: "In the app, or while charging")
        case .minicpm5:
            ModelCard(
                title: "MiniCPM5 1B",
                summary: "OpenBMB's open model on Apple's Core AI. Small and fast, without Apple's rate limits.",
                accuracy: 0.6, speed: 0.85, languages: "English and Chinese best", runs: "In the app, or while charging")
        }
    }
}

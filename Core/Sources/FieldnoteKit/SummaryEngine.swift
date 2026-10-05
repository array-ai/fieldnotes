import Foundation

/// Which on-device model writes the notes.
///
/// Apple's model is built in, with a 4,096-token context, and is rate-limited for
/// background work on battery. Qwen3 1.7B is an optional download run through Apple's
/// Core AI runtime: twice the context, no content filter refusing ordinary meetings,
/// and generally faster. Both run entirely on the phone.
public enum SummaryEngine: String, Codable, CaseIterable, Sendable {
    case apple
    case qwen3

    public static let defaultsKey = "summaryEngine"

    public init(storedValue: String?) {
        self = storedValue.flatMap(SummaryEngine.init(rawValue:)) ?? .apple
    }

    public var modelPack: ModelPack.ID? {
        switch self {
        case .apple: nil
        case .qwen3: .qwen3
        }
    }

    /// Ratings as in `ModelCard`: relative, and for Qwen an estimate until it's been
    /// benchmarked on this phone. Speed for Apple's model is the iPhone 16 Pro benchmark
    /// (~34 tokens/s); Qwen3 1.7B Core AI builds publish ~45–66 tokens/s on an iPhone 17
    /// Pro GPU, and this Neural-Engine-friendly build is unmeasured.
    public var card: ModelCard {
        switch self {
        case .apple:
            ModelCard(
                title: "Apple Intelligence model",
                summary: "Built in. 4,096-token context, so long meetings are summarised in parts.",
                accuracy: 0.7, speed: 0.6, languages: "Many languages", runs: "In the app, or while charging")
        case .qwen3:
            ModelCard(
                title: "Qwen3 1.7B",
                summary: "Alibaba's open model on Apple's Core AI. Twice the context, no false content refusals.",
                accuracy: 0.7, speed: 0.75, languages: "100+ languages", runs: "In the app, or while charging")
        }
    }
}

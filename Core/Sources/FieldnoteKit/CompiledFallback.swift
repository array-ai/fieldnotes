import Foundation

/// When a model compiled for this phone's chip keeps failing, use the portable
/// model instead, which the phone compiles itself.
///
/// A compiled build can stop working after an iOS update, or fail to prepare (Qwen3
/// 4B's ran an iPhone 16 out of memory). Two failures in a row, while preparing or
/// writing notes, and the app stops choosing it; a success resets the count.
public enum CompiledFallback {

    static let defaultsKey = "compiledBuildFailures"
    static let limit = 2

    /// Whether the app has given up on this compiled build.
    public static func gaveUp(on id: ModelPack.ID, defaults: UserDefaults = .standard) -> Bool {
        failures(defaults)[id.rawValue, default: 0] >= limit
    }

    /// Counts a failure of a compiled build (a portable model's are not counted).
    /// Returns true when this one made the app give up on it.
    @discardableResult
    public static func recordFailure(_ id: ModelPack.ID, defaults: UserDefaults = .standard) -> Bool {
        guard id.portable != nil else { return false }
        var counts = failures(defaults)
        counts[id.rawValue, default: 0] += 1
        defaults.set(counts, forKey: defaultsKey)
        return counts[id.rawValue] == limit
    }

    public static func recordSuccess(_ id: ModelPack.ID, defaults: UserDefaults = .standard) {
        var counts = failures(defaults)
        guard counts.removeValue(forKey: id.rawValue) != nil else { return }
        defaults.set(counts, forKey: defaultsKey)
    }

    /// The pack to use for a model: its build for this chip, unless there is none or
    /// the app gave up on it.
    public static func pack(for portable: ModelPack.ID, architecture: String?, defaults: UserDefaults = .standard) -> ModelPack.ID {
        guard let compiled = portable.compiled(for: architecture), !gaveUp(on: compiled, defaults: defaults) else {
            return portable
        }
        return compiled
    }

    private static func failures(_ defaults: UserDefaults) -> [String: Int] {
        defaults.dictionary(forKey: defaultsKey) as? [String: Int] ?? [:]
    }
}

extension ModelPack.ID {
    /// For a build compiled for one chip ("minicpm5_2bH17p"), the portable model it
    /// was compiled from ("minicpm5_2b"); nil for a portable model.
    public var portable: ModelPack.ID? {
        ModelPack.ID.allCases
            .filter { base in
                guard base != self, rawValue.hasPrefix(base.rawValue) else { return false }
                let suffix = rawValue.dropFirst(base.rawValue.count)
                return suffix.first == "H" && suffix.dropFirst().first?.isNumber == true
                    && base.compiled(for: "h" + suffix.dropFirst()) == self
            }
            .max { $0.rawValue.count < $1.rawValue.count }
    }
}

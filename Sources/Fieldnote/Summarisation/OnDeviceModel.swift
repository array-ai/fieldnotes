import CoreAI
import CoreAILanguageModels
import FieldnoteKit
import Foundation
import FoundationModels
import Synchronization

/// Which on-device tier to run. AFM 3 ships two (spec 4.5):
///
/// - `core`: 3B dense. Cheap classification work.
/// - `coreAdvanced`: 20B sparse, 1–4B activated per prompt. Roll-up summaries and
///   per-speaker content passes.
///
/// Both are on-device. Neither is Private Cloud Compute, and neither is a
/// third-party provider. There is no third case and there must never be one.
public enum ModelTier: Sendable {
    case core
    case coreAdvanced
}

/// The single sanctioned construction point for every `LanguageModelSession` in
/// Fieldnote.
///
/// # Why this type exists
///
/// iOS 27 made Private Cloud Compute seamless — no auth, no keys, no config — and
/// opened `LanguageModel` to third-party providers (Claude, Gemini, anything
/// conforming). Both are one initialiser argument away from routing client meeting
/// content off the device, silently and without a permission prompt. Seamless is the
/// hazard.
///
/// So: no other file in this target may construct a session. That is enforced three
/// ways, none of which is code review —
///
/// 1. `Tests/FieldnoteTests/ModelPolicyTests.swift` scans the checked-in sources and
///    fails if `LanguageModelSession(` appears outside this file.
/// 2. The same test fails on any third-party provider import or `LanguageModel`
///    conformance in the target.
/// 3. `Scripts/policy-check.sh` runs both greps in CI, so a green build is required
///    to merge.
///
/// # If the SDK symbols differ
///
/// `pinnedModel(for:)` below is the only place the tier and the on-device pin are
/// expressed. If Xcode 27's actual spelling differs from what is written there, fix
/// it there and nowhere else — that is the entire point of the choke point.
public enum OnDeviceModel {

    public static var availability: SystemLanguageModel.Availability {
        SystemLanguageModel.default.availability
    }

    public static var isReady: Bool {
        if case .available = availability { return true }
        return false
    }

    // MARK: - The pin

    /// SPEC-API — verify this function against the Xcode 27 SDK on first compile.
    ///
    /// Everything else in Fieldnote goes through it, so a signature change here is a
    /// one-line migration rather than a hunt. What must remain true whatever the
    /// spelling:
    ///
    /// - the returned model executes on this device;
    /// - no code path can substitute a Private Cloud Compute model;
    /// - no code path can substitute a third-party provider.
    private static func pinnedModel(for tier: ModelTier) -> SystemLanguageModel {
        // The on-device model, with the guardrail mode Apple provides for transforming
        // text the user supplied (summaries, rewrites). The default mode refused
        // ordinary meeting talk as "may contain sensitive content". Both tiers resolve
        // to the on-device model; never a use case that implies server execution.
        switch tier {
        case .core, .coreAdvanced:
            return SystemLanguageModel(useCase: .general, guardrails: .permissiveContentTransformations)
        }
    }

    // MARK: - Sessions

    /// Build a session pinned to the on-device model.
    ///
    /// - Throws: `ModelUnavailable` rather than returning a session that would fail
    ///   on first use, so callers checkpoint and retry instead of losing a stage.
    public static func session(
        tier: ModelTier,
        instructions: String
    ) throws -> LanguageModelSession {
        if usesLocalModel, let local = localModel.withLock({ $0 }) {
            return LanguageModelSession(model: local, instructions: instructions)
        }
        let model = pinnedModel(for: tier)
        guard case .available = model.availability else {
            throw ModelUnavailable(status: DeviceCapability.current())
        }
        return LanguageModelSession(model: model, instructions: instructions)
    }

    // MARK: - Optional local model (MiniCPM5 on Core AI)

    /// Loaded by `prepareSummaryModel()`, released by `releaseSummaryModel()`.
    private static let localModel = Mutex<CoreAILanguageModel?>(nil)

    /// This phone's chip family as Core AI names it ("h18p" on an iPhone 17 Pro): the
    /// suffix of the ahead-of-time compiled model that runs here.
    public static var deviceArchitecture: String { AIModel.deviceArchitectureName }

    /// The summary model chosen in Settings.
    public static var selectedEngine: SummaryEngine {
        SummaryEngine(storedValue: UserDefaults.standard.string(forKey: SummaryEngine.defaultsKey))
    }

    /// A downloaded model (MiniCPM5 1B or 2B) is chosen and fully downloaded.
    public static var usesLocalModel: Bool {
        selectedEngine.isLocal && localModelDirectory != nil
    }

    /// The model bundle inside the download: the pack keeps the repo's layout
    /// (`ios-static/` for the portable model, `ios-<chip>/` for a compiled one).
    public static var localModelDirectory: URL? {
        guard let pack = selectedEngine.modelPack,
              let directory = ModelDownloads.installedDirectory(for: pack) else { return nil }
        return ModelPack.pack(pack).bundleFolder.map { directory.appendingPathComponent($0, isDirectory: true) } ?? directory
    }

    /// Loads MiniCPM5 if it's the chosen summary model (tokenizer now, weights on
    /// first use). A no-op for Apple's model.
    public static func prepareSummaryModel() async throws {
        guard usesLocalModel, localModel.withLock({ $0 }) == nil,
              let directory = localModelDirectory else { return }
        let model = try await loadLocalModel(at: directory, eager: false)
        localModel.withLock { $0 = model }
    }

    /// Frees MiniCPM5's memory: it, Nemotron and Parakeet together are too much to keep
    /// resident in a background task.
    public static func releaseSummaryModel() {
        localModel.withLock { model in
            model?.unload()
            model = nil
        }
    }

    /// Deletes Core AI's prepared (specialised) copy of the model in a bundle.
    ///
    /// Core AI caches it by the model file's path, and the cache is purgeable: iOS
    /// can delete part of it under storage pressure while the index still points at
    /// it. MiniCPM5 1B then failed every request in 2 s with "nilError", and a fresh
    /// download (same path) failed the same way in 0.4 s (build 43). Clearing the
    /// entry makes the next load prepare it again.
    public static func clearPreparedCopy(in bundle: URL) {
        guard let model = mainAsset(in: bundle) else { return }
        do {
            try AIModelCache.default.deleteEntries(for: model)
            DebugLog.shared.log("models", "cleared the prepared copy of \(model.lastPathComponent)")
        } catch {
            DebugLog.shared.log("models", "couldn't clear the prepared copy of \(model.lastPathComponent): \(error)")
        }
    }

    /// The model file a bundle's metadata.json names (`assets.main`).
    static func mainAsset(in bundle: URL) -> URL? {
        guard let data = try? Data(contentsOf: bundle.appending(path: "metadata.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let assets = json["assets"] as? [String: Any],
              let main = assets["main"] as? String else { return nil }
        return bundle.appending(path: main)
    }

    /// The bundle folder of a downloaded summary-model pack, if it's installed.
    public static func bundle(for pack: ModelPack.ID) -> URL? {
        guard let directory = ModelDownloads.installedDirectory(for: pack) else { return nil }
        return ModelPack.pack(pack).bundleFolder.map { directory.appendingPathComponent($0, isDirectory: true) } ?? directory
    }

    /// The one place the Core AI model is constructed. Refuses a bundle without its
    /// own tokenizer: the runtime would otherwise fetch one from Hugging Face.
    static func loadLocalModel(at directory: URL, eager: Bool) async throws -> CoreAILanguageModel {
        let tokenizer = directory.appending(path: "tokenizer/tokenizer.json")
        guard FileManager.default.fileExists(atPath: tokenizer.path(percentEncoded: false)) else {
            throw LocalModelError.tokenizerMissing
        }
        return try await CoreAILanguageModel(resourcesAt: directory, mode: eager ? .eager : .lazy)
    }

    public enum LocalModelError: Error, LocalizedError {
        case tokenizerMissing
        public var errorDescription: String? {
            "The downloaded summary model is missing its tokenizer. Delete and download it again."
        }
    }

    /// Generation context for every summary request. MiniCPM5 can "think" out loud
    /// (its chat template's enable_thinking), which would spend the answer budget;
    /// this turns that off.
    public static var contextOptions: ContextOptions {
        contextOptions(local: usesLocalModel)
    }

    public static func contextOptions(local: Bool) -> ContextOptions {
        local
            ? ContextOptions(includeSchemaInPrompt: true, reasoningLevel: .custom("none"))
            : ContextOptions(includeSchemaInPrompt: true)
    }

    /// Benchmark only: a session on one downloaded model, whatever is chosen in
    /// Settings, plus the loaded model to unload afterwards. Nil if it isn't
    /// downloaded.
    public static func benchmarkSession(
        for engine: SummaryEngine,
        instructions: String
    ) async throws -> BenchmarkSession? {
        guard engine.isLocal, let pack = engine.modelPack,
              let directory = ModelDownloads.installedDirectory(for: pack) else { return nil }
        let bundle = ModelPack.pack(pack).bundleFolder.map { directory.appendingPathComponent($0, isDirectory: true) } ?? directory
        let model = try await loadLocalModel(at: bundle, eager: false)
        return BenchmarkSession(session: LanguageModelSession(model: model, instructions: instructions), model: model)
    }

    /// A session on a downloaded model, and the means to free it.
    public struct BenchmarkSession {
        public let session: LanguageModelSession
        fileprivate let model: CoreAILanguageModel
        public func unload() { model.unload() }
    }

    /// Benchmark only: a session on Apple's model, whatever is chosen in Settings.
    public static func appleSession(tier: ModelTier, instructions: String) throws -> LanguageModelSession {
        let model = pinnedModel(for: tier)
        guard case .available = model.availability else {
            throw ModelUnavailable(status: DeviceCapability.current())
        }
        return LanguageModelSession(model: model, instructions: instructions)
    }

    /// MiniCPM5's context from the export (`max_context_length` in its metadata.json).
    public static let localContextSize = 4_096

    // MARK: - Measuring

    /// The pinned model's context window, in tokens.
    public static func contextSize(tier: ModelTier) -> Int {
        pinnedModel(for: tier).contextSize
    }

    /// Exact token cost of a prompt, from the pinned model's own tokenizer. Nil if
    /// the framework can't answer, so callers fall back rather than fail.
    public static func tokenCount(prompt: String, tier: ModelTier) async -> Int? {
        try? await pinnedModel(for: tier).tokenCount(for: prompt)
    }

    public static func tokenCount(instructions: String, tier: ModelTier) async -> Int? {
        try? await pinnedModel(for: tier).tokenCount(for: Instructions(instructions))
    }

    public static func tokenCount(schema: GenerationSchema, tier: ModelTier) async -> Int? {
        try? await pinnedModel(for: tier).tokenCount(for: schema)
    }

    public struct ModelUnavailable: Error, LocalizedError, Sendable {
        public let status: DeviceCapability.Status
        public var errorDescription: String? { status.headline }
        public var failureReason: String? { status.explanation }
    }
}

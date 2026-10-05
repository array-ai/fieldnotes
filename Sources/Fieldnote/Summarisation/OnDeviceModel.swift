import Foundation
import FoundationModels

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
        let model = pinnedModel(for: tier)
        guard case .available = model.availability else {
            throw ModelUnavailable(status: DeviceCapability.current())
        }
        return LanguageModelSession(model: model, instructions: instructions)
    }

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

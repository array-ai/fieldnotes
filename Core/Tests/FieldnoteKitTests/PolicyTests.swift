import Foundation
import Testing

/// The prohibitions from the spec, enforced by test rather than by review.
///
/// Each of these is a rule that is easy to break by accident and impossible to notice
/// afterwards: a convenience intent added on a Friday, a second session constructed
/// during a refactor, a networking call added "just for a health check". A failing
/// test on a pull request is the only mechanism that actually holds.
@Suite("Policy")
struct PolicyTests {

    // MARK: - Controls
    //
    // Every rule below is of the form "this string does not appear in the app
    // sources". That shape has one catastrophic failure: if the scan finds no
    // sources at all, every rule passes and the suite goes green while enforcing
    // nothing. That is not hypothetical — it happened when the package was split
    // into two for xtool and the scanner's root moved with it.
    //
    // These two tests are the controls. They fail when the scan is empty or blind,
    // so the absence-based rules below can be trusted.

    @Test("The scanner can see the app sources")
    func scannerSeesTheAppSources() {
        let sources = PolicySourceScanner.appSources()
        #expect(
            sources.count > 20,
            "Scanned only \(sources.count) files. The policy rules below are all \"this does not appear\" rules, so a scan that finds nothing passes them all."
        )
        #expect(
            sources.contains { $0.path.hasSuffix("/Summarisation/OnDeviceModel.swift") },
            "OnDeviceModel.swift was not scanned, so the on-device pin is not actually being checked."
        )
        #expect(
            sources.contains { $0.path.hasSuffix("/FieldnoteWidgets/RecordingLiveActivity.swift") },
            "The widget extension was not scanned. Its sources ship in the app too."
        )
    }

    @Test("The scanner detects a symbol that is genuinely present")
    func scannerDetectsWhatIsThere() {
        // A positive control: proves the matcher works, not merely that files were
        // read. SpeechAnalyzer is central to the app and is not going away.
        #expect(
            !PolicySourceScanner.filesContaining("SpeechAnalyzer").isEmpty,
            "The scanner found no SpeechAnalyzer usage, so it is not matching source lines at all."
        )
        // And that the comment-stripping does not swallow real code: the pinned
        // factory does construct a session, on a line that is not a comment.
        #expect(
            PolicySourceScanner.filesContaining("LanguageModelSession(")
                == ["Sources/Fieldnote/Summarisation/OnDeviceModel.swift"],
            "The one sanctioned session construction site was not found where expected."
        )
    }

    /// Constraint 6: no Foundation Models session exists that is not pinned to the
    /// on-device model.
    ///
    /// iOS 27 makes Private Cloud Compute seamless — no auth, no keys, no config — so
    /// an unpinned session silently sends client meeting content to Apple's servers.
    /// `OnDeviceModel` is the only place allowed to construct one.
    @Test("Sessions are only constructed in the pinned factory")
    func sessionsOnlyFromFactory() {
        let offenders = PolicySourceScanner.filesContaining(
            "LanguageModelSession(",
            excluding: ["Sources/Fieldnote/Summarisation/OnDeviceModel.swift"]
        )
        #expect(
            offenders.isEmpty,
            """
            LanguageModelSession is constructed outside OnDeviceModel in: \
            \(offenders.joined(separator: ", ")). Every session must come from \
            OnDeviceModel.session(tier:instructions:), which pins it on-device.
            """
        )
    }

    /// Constraint 7: never adopt a third-party `LanguageModel` provider. iOS 27 opened
    /// the framework to Claude, Gemini and anything conforming. Fieldnote uses Apple's
    /// on-device model only.
    @Test("No third-party model providers")
    func noThirdPartyProviders() {
        let markers = [": LanguageModel ", ": LanguageModel,", ": LanguageModel {", "SystemLanguageModel(useCase: .server"]
        for marker in markers {
            let offenders = PolicySourceScanner.filesContaining(marker)
            #expect(offenders.isEmpty, "Third-party or off-device model provider in: \(offenders.joined(separator: ", "))")
        }
    }

    /// Constraint 8 / spec 4.8: no App Intents in the target at all, and nothing that
    /// could contribute app content to the Spotlight semantic index.
    ///
    /// Siri is now a cloud Gemini model with cloud routing. Indexing a transcript
    /// entity is a data-exfiltration path with a friendly name. Fieldnote accepts
    /// being invisible to Siri's content search.
    @Test("No App Intents or semantic indexing")
    func noAppIntents() {
        let forbidden = [
            "import AppIntents",
            "IndexedEntity",
            "AssistantEntity",
            "AssistantIntent",
            "indexingKey",
            "AppShortcutsProvider",
            "ViewAnnotation",
            ": AppIntent",
            "EntityQuery"
        ]
        for marker in forbidden {
            let offenders = PolicySourceScanner.filesContaining(marker)
            #expect(offenders.isEmpty, "\(marker) found in: \(offenders.joined(separator: ", "))")
        }
    }

    /// Constraint 1: the app makes zero outbound requests. Not "no meeting content
    /// over the network" — no network code at all, so there is nothing to audit later.
    @Test("No networking code anywhere in the app")
    func noNetworking() {
        let forbidden = [
            "URLRequest",
            "NSURLConnection",
            "import Network",
            "NWConnection",
            "CFReadStream",
            "WKWebView",
            "URLProtocol"
        ]
        for marker in forbidden {
            let offenders = PolicySourceScanner.filesContaining(marker)
            #expect(offenders.isEmpty, "Networking symbol \(marker) found in: \(offenders.joined(separator: ", "))")
        }
    }

    /// Constraint 1, the part networking symbols alone do not catch: FluidAudio's
    /// convenience model loaders download from Hugging Face whenever a file is
    /// missing, through its own URLSession. Every model is vendored into the bundle
    /// and loaded from local files instead (`DiarizationModelProvider`).
    @Test("No network-backed model loaders")
    func noModelDownloads() {
        let forbidden = [
            "loadFromHuggingFace",
            "ModelHub",
            "DownloadUtils",
            "prepareModels(",
            "downloadIfNeeded",
            "DiarizerModels.download",
            "DiarizerModels.load(from",
            "OfflineDiarizerModels.load(",
            "AsrModels.load(",
            "AsrModels.downloadAndLoad",
            "downloadAndLoad("
        ]
        for marker in forbidden {
            let offenders = PolicySourceScanner.filesContaining(marker)
            #expect(offenders.isEmpty, "Network-backed loader \(marker) found in: \(offenders.joined(separator: ", "))")
        }
    }

    /// The optional Qwen summary model runs through Apple's Core AI runtime as a
    /// Foundation Models `LanguageModel`. It is built in one file, and nothing may name
    /// Apple's cloud model or the Hugging Face loaders that runtime could fall back on.
    @Test("Local summary model confined; no cloud model, no downloading tokenizer")
    func localModelConfined() {
        let offenders = PolicySourceScanner.filesContaining(
            "CoreAILanguageModel(",
            excluding: ["Sources/Fieldnote/Summarisation/OnDeviceModel.swift"]
        )
        #expect(offenders.isEmpty, "CoreAILanguageModel outside OnDeviceModel: \(offenders.joined(separator: ", "))")
        for marker in ["PrivateCloudComputeLanguageModel", "AutoTokenizer.from(pretrained", "HubApi"] {
            let found = PolicySourceScanner.filesContaining(marker)
            #expect(found.isEmpty, "\(marker) found in: \(found.joined(separator: ", "))")
        }
    }

    /// Optional model downloads are the other sanctioned network use: only on a
    /// tap, pinned, hashed, and only from `ModelDownloads`.
    @Test("URLSession only in ModelDownloads")
    func downloadsConfined() {
        let offenders = PolicySourceScanner.filesContaining(
            "URLSession",
            excluding: ["Sources/Fieldnote/Models/ModelDownloads.swift"]
        )
        #expect(offenders.isEmpty, "URLSession outside ModelDownloads: \(offenders.joined(separator: ", "))")
    }

    /// The one sanctioned outbound request: naming a place with Apple Maps, opt-in
    /// and off by default. Keeping every lookup in `PlaceNamer` keeps what leaves the
    /// device for location in one file that's easy to audit.
    @Test("Apple Maps lookups only in PlaceNamer")
    func placeLookupsConfined() {
        let lookups = [
            "MKReverseGeocodingRequest",
            "MKLocalSearch",
            "MKLocalPointsOfInterestRequest",
            "MKGeocodingRequest",
            "CLGeocoder",
            "MKLookAroundSceneRequest"
        ]
        for marker in lookups {
            let offenders = PolicySourceScanner.filesContaining(
                marker,
                excluding: ["Sources/Fieldnote/Location/PlaceNamer.swift"]
            )
            #expect(offenders.isEmpty, "Place lookup \(marker) outside PlaceNamer: \(offenders.joined(separator: ", "))")
        }
    }

    /// Spec 4.7: without the continued-processing inference entitlement, summarisation
    /// dies the moment the app backgrounds — which is exactly when it runs.
    @Test("Inference entitlement is present")
    func inferenceEntitlement() throws {
        let url = PolicySourceScanner.repositoryRoot
            .appending(path: "Config/Fieldnote.entitlements")
        let contents = try String(contentsOf: url, encoding: .utf8)
        #expect(contents.contains("com.apple.developer.background-tasks.continued-processing.inference"))
    }

    /// The macOS sandbox entitlements must not grant network client access. Nothing in
    /// the app uses it, and granting it invites something later to.
    @Test("No network entitlements")
    func noNetworkEntitlements() throws {
        let url = PolicySourceScanner.repositoryRoot
            .appending(path: "Config/Fieldnote.entitlements")
        let contents = try String(contentsOf: url, encoding: .utf8)
        #expect(!contents.contains("<key>com.apple.security.network.client</key>"))
        #expect(!contents.contains("<key>com.apple.security.network.server</key>"))
    }
}

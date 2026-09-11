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
            excluding: ["/Fieldnote/Summarisation/OnDeviceModel.swift"]
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
            "URLSession",
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

    /// Spec 4.7: without the continued-processing inference entitlement, summarisation
    /// dies the moment the app backgrounds — which is exactly when it runs.
    @Test("Inference entitlement is present")
    func inferenceEntitlement() throws {
        let url = PolicySourceScanner.repositoryRoot
            .appending(path: "Fieldnote/Resources/Fieldnote.entitlements")
        let contents = try String(contentsOf: url, encoding: .utf8)
        #expect(contents.contains("com.apple.developer.background-tasks.continued-processing.inference"))
    }

    /// The macOS sandbox entitlements must not grant network client access. Nothing in
    /// the app uses it, and granting it invites something later to.
    @Test("No network entitlements")
    func noNetworkEntitlements() throws {
        let url = PolicySourceScanner.repositoryRoot
            .appending(path: "Fieldnote/Resources/Fieldnote.entitlements")
        let contents = try String(contentsOf: url, encoding: .utf8)
        #expect(!contents.contains("<key>com.apple.security.network.client</key>"))
        #expect(!contents.contains("<key>com.apple.security.network.server</key>"))
    }
}

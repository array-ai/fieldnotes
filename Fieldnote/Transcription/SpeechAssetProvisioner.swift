import Foundation
import Speech
import OSLog

/// Gets the Speech model assets installed and the locale allocated, in that order.
///
/// The order is the whole point. Allocating before the installation request finishes
/// gives you "cannot use modules with unallocated locales", which reads like a
/// permissions problem and is not (spec 4.3).
///
/// The model is OS-managed and adds nothing to the bundle, but it does download on
/// first use, so the UI has a state for it rather than a spinner that never ends.
public actor SpeechAssetProvisioner {
    public static let shared = SpeechAssetProvisioner()

    public enum State: Equatable, Sendable {
        case idle
        case downloading(Double)
        case ready
        case failed(String)
    }

    private let log = Logger(subsystem: "com.publicarray.fieldnotes", category: "speech.assets")
    private var allocatedLocales: Set<String> = []
    private(set) public var state: State = .idle

    public init() {}

    /// Installs assets for `transcriber` and allocates `locale`, once per locale.
    public func prepare(transcriber: SpeechTranscriber, locale: Locale) async throws {
        let identifier = locale.identifier(.bcp47)
        if allocatedLocales.contains(identifier) { return }

        state = .downloading(0)
        do {
            // 1. Install. Returns nil when everything needed is already present.
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                log.notice("Downloading speech assets for \(identifier, privacy: .public)")
                try await request.downloadAndInstall()
            }
            // 2. Only now allocate.
            try await AssetInventory.allocate(locale: locale)
            allocatedLocales.insert(identifier)
            state = .ready
        } catch {
            state = .failed(error.localizedDescription)
            throw error
        }
    }

    public func release(locale: Locale) async {
        await AssetInventory.deallocate(locale: locale)
        allocatedLocales.remove(locale.identifier(.bcp47))
    }

    public static func supportedLocales() async -> [Locale] {
        await SpeechTranscriber.supportedLocales
    }
}

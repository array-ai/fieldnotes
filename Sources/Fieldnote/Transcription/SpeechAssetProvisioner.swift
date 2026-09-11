import Foundation
import OSLog
import Speech

/// Gets the Speech model assets installed and the locale reserved, in that order.
///
/// The order is the whole point. Reserving before the installation request finishes
/// gives you an unallocated-locale error, which reads like a permissions problem and
/// is not (spec 4.3).
///
/// Reservation is a limited resource: `AssetInventory.maximumReservedLocales` caps how
/// many locales an app may hold, and the Speech error codes include
/// `tooManyAssetLocalesAllocated`. v1 uses one locale at a time, so this reserves on
/// demand and releases on request rather than holding several.
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
    private var reservedLocaleIdentifiers: Set<String> = []
    private(set) public var state: State = .idle

    public init() {}

    /// Installs assets for `transcriber` and reserves `locale`, once per locale.
    public func prepare(transcriber: SpeechTranscriber, locale: Locale) async throws {
        let identifier = locale.identifier(.bcp47)
        if reservedLocaleIdentifiers.contains(identifier) { return }

        state = .downloading(0)
        do {
            // 1. Install. Returns nil when everything needed is already present.
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                log.notice("Downloading speech assets for \(identifier, privacy: .public)")
                try await request.downloadAndInstall()
            }
            // 2. Only now reserve.
            try await AssetInventory.reserve(locale: locale)
            reservedLocaleIdentifiers.insert(identifier)
            state = .ready
        } catch {
            state = .failed(error.localizedDescription)
            throw error
        }
    }

    public func release(locale: Locale) async {
        await AssetInventory.release(reservedLocale: locale)
        reservedLocaleIdentifiers.remove(locale.identifier(.bcp47))
    }

    public static func supportedLocales() async -> [Locale] {
        await SpeechTranscriber.supportedLocales
    }
}

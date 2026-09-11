import FieldnoteKit
import Foundation
import Observation
import SwiftData
import SwiftUI

/// App-wide state: the store, the recorder, the background coordinator, and the
/// meeting list the UI renders.
@MainActor
@Observable
public final class AppModel {

    public private(set) var capability: DeviceCapability.Status = .ready
    public private(set) var meetings: [MeetingSnapshot] = []
    public var searchQuery: String = "" {
        didSet { Task { await refresh() } }
    }

    public let recorder = RecordingController()
    public let store: MeetingStore
    #if os(iOS)
    public let coordinator: BackgroundProcessingCoordinator
    #endif

    public var settings = Settings()

    public init(container: ModelContainer) {
        let store = MeetingStore(modelContainer: container)
        self.store = store
        #if os(iOS)
        self.coordinator = BackgroundProcessingCoordinator(provider: store)
        #endif
    }

    public func onLaunch() async {
        refreshCapability()
        await refresh()
        #if os(iOS)
        // Anything left unfinished by a kill or a restart resumes from its last
        // checkpoint rather than from raw audio.
        coordinator.resumeUnfinishedWork()
        #endif
    }

    public func refreshCapability() {
        capability = DeviceCapability.current()
    }

    public func refresh() async {
        let query = searchQuery
        meetings = (try? await store.search(query)) ?? []
    }

    // MARK: - Recording

    public func startRecording(title: String, type: MeetingType) async throws {
        let locale = settings.locale
        let id = try await store.createMeeting(
            title: title,
            type: type,
            locale: locale,
            consentAcknowledged: settings.consentAcknowledged
        )
        try await recorder.start(meetingID: id, title: title, type: type, locale: locale)
        await refresh()
    }

    /// Stop hands off to the background task and returns. The user can pocket the
    /// phone from here (spec 4.7).
    public func stopRecording() async {
        guard let result = await recorder.stop() else { return }
        try? await store.finishRecording(result)
        #if os(iOS)
        let title = meetings.first { $0.id == result.meetingID }?.title ?? "meeting"
        await coordinator.submitAfterRecording(title: title)
        #endif
        await refresh()
    }

    // MARK: - Settings

    @Observable
    public final class Settings {
        public var localeIdentifier: String {
            didSet { UserDefaults.standard.set(localeIdentifier, forKey: "locale") }
        }
        /// Reminders export is off by default (spec 6.3).
        public var remindersEnabled: Bool {
            didSet { UserDefaults.standard.set(remindersEnabled, forKey: "remindersEnabled") }
        }
        public var remindersListID: String? {
            didSet { UserDefaults.standard.set(remindersListID, forKey: "remindersListID") }
        }
        /// The user has read the recording-obligation line at least once (spec 7).
        public var consentAcknowledged: Bool {
            didSet { UserDefaults.standard.set(consentAcknowledged, forKey: "consentAcknowledged") }
        }

        public init() {
            self.localeIdentifier = UserDefaults.standard.string(forKey: "locale") ?? "en_AU"
            self.remindersEnabled = UserDefaults.standard.bool(forKey: "remindersEnabled")
            self.remindersListID = UserDefaults.standard.string(forKey: "remindersListID")
            self.consentAcknowledged = UserDefaults.standard.bool(forKey: "consentAcknowledged")
        }

        public var locale: Locale { Locale(identifier: localeIdentifier) }
    }
}

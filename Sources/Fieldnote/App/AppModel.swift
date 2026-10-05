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
    public let locationProvider = LocationProvider()
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

    public func startRecording(title: String, coordinate: (latitude: Double, longitude: Double)?) async throws {
        let locale = settings.locale
        // Meeting types are gone from the UI; every meeting is stored as `.general`.
        let type = MeetingType.general
        let id = try await store.createMeeting(
            title: title,
            type: type,
            locale: locale,
            consentAcknowledged: settings.consentAcknowledged,
            latitude: coordinate?.latitude,
            longitude: coordinate?.longitude
        )
        try await recorder.start(meetingID: id, title: title, type: type, locale: locale)
        DebugLog.shared.log("recording", "\(DebugLog.short(id)): started, speaker method \(settings.diarizationMethod.rawValue)")
        // Load the speaker models now, so their first-load compile overlaps the
        // recording instead of delaying the results after stop.
        let method = settings.diarizationMethod
        Task(priority: .utility) { await DiarizationService.shared.prewarm(method) }
        await refresh()
    }

    /// Stop hands off to the background task and returns. The user can pocket the
    /// phone from here (spec 4.7).
    public func stopRecording() async {
        guard let result = await recorder.stop() else { return }
        DebugLog.shared.log(
            "recording",
            "\(DebugLog.short(result.meetingID)): stopped after \(String(format: "%.1f", result.duration))s, \(result.chunks.count) audio chunk(s), \(result.liveSegments.count) live lines"
        )
        try? await store.finishRecording(result)
        #if os(iOS)
        let title = meetings.first { $0.id == result.meetingID }?.title ?? "meeting"
        await coordinator.submitAfterRecording(title: title)
        #endif
        await refresh()
    }

    // MARK: - Editing

    public func renameMeeting(_ meetingID: UUID, to title: String) async {
        try? await store.renameMeeting(meetingID, to: title)
        await refresh()
    }

    /// Debug mode: re-run one stage (and everything after it) for a finished meeting.
    public func redo(_ stage: MeetingStore.RedoStage, meetingID: UUID, title: String) async {
        do {
            try await store.prepareRedo(stage, meetingID: meetingID)
        } catch {
            DebugLog.shared.log("store", "\(DebugLog.short(meetingID)): could not queue redo of \(stage.rawValue): \(error)")
            return
        }
        #if os(iOS)
        await coordinator.submitRedo(title: "Redoing \(stage.rawValue) for \(title)")
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
        /// Off by default. When on, a coordinate is captured at the start of each
        /// recording and stored on the meeting — never geocoded, never sent anywhere.
        public var locationEnabled: Bool {
            didSet { UserDefaults.standard.set(locationEnabled, forKey: "locationEnabled") }
        }

        /// Shows the log viewer and the redo actions.
        public var debugMode: Bool {
            didSet { UserDefaults.standard.set(debugMode, forKey: "debugMode") }
        }

        /// Applies to the next recording processed. See `DiarizationMethod`.
        public var diarizationMethod: DiarizationMethod {
            didSet { UserDefaults.standard.set(diarizationMethod.rawValue, forKey: DiarizationMethod.defaultsKey) }
        }

        public init() {
            self.debugMode = UserDefaults.standard.bool(forKey: "debugMode")
            self.diarizationMethod = DiarizationMethod(
                storedValue: UserDefaults.standard.string(forKey: DiarizationMethod.defaultsKey)
            )
            self.localeIdentifier = UserDefaults.standard.string(forKey: "locale") ?? "en_AU"
            self.remindersEnabled = UserDefaults.standard.bool(forKey: "remindersEnabled")
            self.remindersListID = UserDefaults.standard.string(forKey: "remindersListID")
            self.consentAcknowledged = UserDefaults.standard.bool(forKey: "consentAcknowledged")
            self.locationEnabled = UserDefaults.standard.bool(forKey: "locationEnabled")
        }

        public var locale: Locale { Locale(identifier: localeIdentifier) }
    }
}

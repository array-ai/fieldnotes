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
    /// Set to navigate to a meeting, e.g. from a tapped notification.
    public var openMeetingID: UUID?
    /// 0...1 while a recording is being imported, nil otherwise.
    public private(set) var importProgress: Double?
    public var importError: String?
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
        // Read by SummaryEngine to pick the summary model compiled for this phone.
        UserDefaults.standard.set(OnDeviceModel.deviceArchitecture, forKey: SummaryEngine.deviceArchitectureKey)
        let store = MeetingStore(modelContainer: container)
        self.store = store
        #if os(iOS)
        self.coordinator = BackgroundProcessingCoordinator(provider: store)
        #endif
    }

    public func onLaunch() async {
        DebugLog.shared.logLaunch(device: ModelBenchmark.deviceModel())
        #if os(iOS)
        CrashWatch.shared.start()
        #endif
        refreshCapability()
        await store.reindexIfNeeded()
        await store.recoverInterruptedRecordings(except: recorder.isActive ? recorder.meetingID : nil)
        await refresh()
        // The first Neural Engine load compiles the speaker model (minutes, once per
        // install). Start it now so it's done before the first meeting ends.
        let method = settings.diarizationMethod.isInstalled ? settings.diarizationMethod : .nemotron3
        Task(priority: .utility) { await DiarizationService.shared.warmUpInBackground(method) }
        await nameUnnamedPlaces()
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
        let live = settings.identifiesSpeakersLive
        do {
            try await recorder.start(meetingID: id, title: title, type: type, locale: locale, identifySpeakersLive: live)
        } catch {
            // Nothing was recorded; don't leave an empty meeting behind.
            try? await store.delete(meetingID: id)
            await refresh()
            throw error
        }
        DebugLog.shared.log(
            "recording",
            "\(DebugLog.short(id)): started, speaker method \(settings.diarizationMethod.rawValue)\(recorder.identifiesSpeakersLive ? ", identifying speakers live" : "")"
        )
        if !recorder.identifiesSpeakersLive {
            // Load the speaker models now, so their first-load compile overlaps the
            // recording instead of delaying the results after stop.
            let method = settings.diarizationMethod.isInstalled ? settings.diarizationMethod : .nemotron3
            Task(priority: .utility) { await DiarizationService.shared.prewarm(method) }
        }
        if let coordinate {
            let useAppleMaps = settings.appleMapsPlaceNames
            Task(priority: .utility) { await self.namePlace(id, coordinate, useAppleMaps: useAppleMaps) }
        }
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
        if let spans = result.liveSpeakerSpans,
           let checkpoints = try? ProcessingCheckpointStore(meetingID: result.meetingID) {
            try? await checkpoints.saveLiveSpans(spans)
        }
        #if os(iOS)
        let title = meetings.first { $0.id == result.meetingID }?.title ?? "meeting"
        await ProcessingNotifier.shared.requestPermissionIfNeeded()
        await coordinator.submitAfterRecording(title: title)
        #endif
        await refresh()
    }

    public func resumeWaitingWork() async {
        await refresh()
        guard meetings.contains(where: { !$0.state.isTerminal && $0.state != .recording }) else { return }
        await ProcessingNotifier.shared.requestPermissionIfNeeded()
        #if os(iOS)
        // In the app, not a background task: summaries only run here.
        coordinator.runPendingInApp()
        #endif
    }

    // MARK: - Import

    /// Imports a recording from another app (Files, share sheet, "Open in"), then
    /// queues it for transcription, speakers and summary like a recording made here.
    public func importRecording(from url: URL) async {
        guard importProgress == nil else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        importProgress = 0
        defer { importProgress = nil }

        let title = url.deletingPathExtension().lastPathComponent
        let created = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date()
        let started = ContinuousClock.now
        var meetingID: UUID?
        do {
            let id = try await store.createMeeting(
                title: title,
                type: .general,
                locale: settings.locale,
                consentAcknowledged: settings.consentAcknowledged,
                startedAt: created
            )
            meetingID = id
            DebugLog.shared.log("import", "\(DebugLog.short(id)): importing a .\(url.pathExtension.lowercased()) file")
            let result = try await RecordingImporter.importAudio(from: url, meetingID: id) { fraction in
                Task { @MainActor in self.importProgress = fraction }
            }
            try await store.finishRecording(RecordingResult(
                meetingID: id,
                chunks: result.chunks,
                liveSegments: [],
                duration: result.duration,
                locale: settings.locale
            ))
            DebugLog.shared.log(
                "import",
                "\(DebugLog.short(id)): imported \(String(format: "%.1f", result.duration))s in \(result.chunks.count) chunk(s) in \(DebugLog.elapsed(since: started))"
            )
            #if os(iOS)
            await ProcessingNotifier.shared.requestPermissionIfNeeded()
            await coordinator.submitAfterRecording(title: title)
            #endif
        } catch {
            DebugLog.shared.log("import", "import failed: \(error)")
            importError = error.localizedDescription
            if let meetingID { try? await store.delete(meetingID: meetingID) }
        }
        await refresh()
    }

    // MARK: - Places

    /// Offline name first, so the meeting has one straight away; Apple Maps then
    /// replaces it with a business or street name if that is turned on and finds one.
    private func namePlace(_ id: UUID, _ coordinate: (latitude: Double, longitude: Double), useAppleMaps: Bool) async {
        if let offline = await PlaceNamer.shared.offlineName(latitude: coordinate.latitude, longitude: coordinate.longitude) {
            try? await store.setPlaceName(offline, for: id)
        }
        if useAppleMaps,
           let named = await PlaceNamer.appleMapsName(latitude: coordinate.latitude, longitude: coordinate.longitude) {
            try? await store.setPlaceName(named, for: id)
        }
        await refresh()
    }

    /// Gives older meetings (recorded before place names existed) an offline name.
    /// Never calls Apple Maps: that only happens for new recordings, by choice.
    private func nameUnnamedPlaces() async {
        guard let pending = try? await store.meetingsNeedingPlaceNames(), !pending.isEmpty else { return }
        for meeting in pending {
            let name = await PlaceNamer.shared.offlineName(latitude: meeting.latitude, longitude: meeting.longitude)
            try? await store.setPlaceName(name ?? "", for: meeting.id)
        }
        DebugLog.shared.log("place", "named \(pending.count) older meeting location(s) offline")
        await refresh()
    }

    // MARK: - Stop / retry

    public func stopProcessing(_ meetingID: UUID) async {
        let state = meetings.first { $0.id == meetingID }?.state.rawValue ?? "unknown"
        DebugLog.shared.log("user", "\(DebugLog.short(meetingID)): stopped processing (was \(state))")
        await store.markStopped(meetingID: meetingID)
        #if os(iOS)
        coordinator.stop(meetingID: meetingID)
        #endif
        await refresh()
    }

    public func retryProcessing(_ meetingID: UUID, title: String) async {
        DebugLog.shared.log("user", "\(DebugLog.short(meetingID)): tapped Try again")
        // A fresh go gets its one automatic retry back.
        if let checkpoints = try? ProcessingCheckpointStore(meetingID: meetingID) {
            var checkpoint = await checkpoints.load()
            checkpoint.summaryDeferrals = 0
            try? await checkpoints.save(checkpoint)
        }
        await store.requeue(meetingID: meetingID)
        await ProcessingNotifier.shared.requestPermissionIfNeeded()
        #if os(iOS)
        await coordinator.submitRedo(title: "Processing \(title)")
        #endif
        await refresh()
    }

    /// Deletes meetings, stopping any processing first. The meeting being recorded
    /// is skipped: its files are still being written.
    public func deleteMeetings(_ ids: [UUID]) async {
        let ids = ids.filter { !(recorder.isActive && recorder.meetingID == $0) }
        // The rows go first, so they vanish at once and no restarted run picks
        // them up; then any run still on one is stopped before its files go.
        for id in ids { try? await store.deleteRecord(meetingID: id) }
        await refresh()
        for id in ids {
            #if os(iOS)
            await coordinator.stopAndWait(meetingID: id)
            #endif
            MeetingStore.deleteFiles(meetingID: id)
        }
    }

    // MARK: - Editing

    public func renameMeeting(_ meetingID: UUID, to title: String) async {
        try? await store.renameMeeting(meetingID, to: title)
        await refresh()
    }

    public func renameSpeaker(label: String, in meetingID: UUID, to name: String) async {
        try? await store.renameSpeaker(label: label, in: meetingID, to: name)
        await refresh()
    }

    /// Debug mode: re-run one stage (and everything after it) for a finished meeting.
    public func redo(_ stage: MeetingStore.RedoStage, meetingID: UUID, title: String) async {
        await ProcessingNotifier.shared.requestPermissionIfNeeded()
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

        /// Off by default. When on, new recordings' coordinates are sent to Apple Maps
        /// to name the business, building or street. Otherwise naming is offline.
        public var appleMapsPlaceNames: Bool {
            didSet { UserDefaults.standard.set(appleMapsPlaceNames, forKey: "appleMapsPlaceNames") }
        }

        /// Identify speakers while recording (Nemotron 3 only). On by default: the
        /// results are ready at stop, and the model is cheap to run alongside capture.
        public var liveSpeakers: Bool {
            didSet { UserDefaults.standard.set(liveSpeakers, forKey: "liveSpeakers") }
        }

        /// Whether the next recording identifies speakers as it goes.
        public var identifiesSpeakersLive: Bool {
            liveSpeakers && diarizationMethod == .nemotron3
        }

        /// A local notification when a meeting's notes are ready. On by default.
        public var notifyWhenProcessed: Bool {
            didSet { UserDefaults.standard.set(notifyWhenProcessed, forKey: ProcessingNotifier.enabledKey) }
        }

        /// Lets summaries run in the background while the phone is charging, including
        /// an overnight run with the app closed. Off by default.
        public var summariseWhileCharging: Bool {
            didSet { UserDefaults.standard.set(summariseWhileCharging, forKey: SummaryInBackground.defaultsKey) }
        }

        /// Stops the phone locking while notes are written in the app (they can only be
        /// written with the app in front, unless charging is allowed above).
        public var keepAwakeWhileProcessing: Bool {
            didSet { UserDefaults.standard.set(keepAwakeWhileProcessing, forKey: "keepAwakeWhileProcessing") }
        }

        /// Shows the log viewer and the redo actions.
        public var debugMode: Bool {
            didSet { UserDefaults.standard.set(debugMode, forKey: "debugMode") }
        }

        /// Which on-device model writes the notes. See `SummaryEngine`.
        public var summaryEngine: SummaryEngine {
            didSet { UserDefaults.standard.set(summaryEngine.rawValue, forKey: SummaryEngine.defaultsKey) }
        }

        /// Which speech model writes the transcript after stop. See `TranscriptionEngine`.
        public var transcriptionEngine: TranscriptionEngine {
            didSet { UserDefaults.standard.set(transcriptionEngine.rawValue, forKey: TranscriptionEngine.defaultsKey) }
        }

        /// Applies to the next recording processed. See `DiarizationMethod`.
        public var diarizationMethod: DiarizationMethod {
            didSet { UserDefaults.standard.set(diarizationMethod.rawValue, forKey: DiarizationMethod.defaultsKey) }
        }

        public init() {
            self.debugMode = UserDefaults.standard.bool(forKey: "debugMode")
            self.summariseWhileCharging = UserDefaults.standard.bool(forKey: SummaryInBackground.defaultsKey)
            self.keepAwakeWhileProcessing = UserDefaults.standard.object(forKey: "keepAwakeWhileProcessing") as? Bool ?? true
            self.summaryEngine = SummaryEngine(storedValue: UserDefaults.standard.string(forKey: SummaryEngine.defaultsKey))
            self.transcriptionEngine = TranscriptionEngine(
                storedValue: UserDefaults.standard.string(forKey: TranscriptionEngine.defaultsKey)
            )
            self.notifyWhenProcessed = UserDefaults.standard.object(forKey: ProcessingNotifier.enabledKey) as? Bool ?? true
            self.liveSpeakers = UserDefaults.standard.object(forKey: "liveSpeakers") as? Bool ?? true
            self.appleMapsPlaceNames = UserDefaults.standard.bool(forKey: "appleMapsPlaceNames")
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

import FieldnoteShared
import SwiftData
import SwiftUI
#if os(iOS)
import UIKit
#endif
import UserNotifications

@main
struct FieldnoteApp: App {
    @Environment(\.scenePhase) private var scenePhase
    #if os(iOS)
    @UIApplicationDelegateAdaptor(ModelDownloadsAppDelegate.self) private var downloadsDelegate
    #endif

    @State private var model: AppModel
    private let container: ModelContainer

    init() {
        let container: ModelContainer
        do {
            container = try MeetingStore.makeContainer()
        } catch {
            fatalError("Could not open the Fieldnote database: \(error)")
        }
        self.container = container

        let model = AppModel(container: container)
        _model = State(initialValue: model)

        // Tapping a "notes ready" notification opens that meeting.
        UNUserNotificationCenter.current().delegate = ProcessingNotifier.shared
        ProcessingNotifier.shared.onOpen = { id in model.openMeetingID = id }

        #if os(iOS)
        // Registration must happen before launch completes. Not at the call site —
        // BGTaskScheduler refuses a handler registered later, with an error that
        // reads like a provisioning problem (spec 4.7).
        model.coordinator.registerHandlers()
        // Work that paused because the phone locked (its files are sealed while
        // locked) carries on as soon as it's unlocked.
        NotificationCenter.default.addObserver(
            forName: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil, queue: .main
        ) { _ in
            DebugLog.shared.log("background", "phone unlocked; resuming paused work")
            model.coordinator.resumeUnfinishedWork()
        }
        // The Action button / Control Centre / Siri control runs in this process.
        MeetingRecordingControl.toggle = { try await model.toggleRecordingFromIntent() }
        // Siri's questions about meetings, also answered in this process.
        MeetingNotesForSiri.store = model.store
        MeetingNotesForSiri.open = { id in model.openMeetingID = id }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .modelContainer(container)
                .task { await model.onLaunch() }
                // "Open in Fieldnote" / "Copy to Fieldnote" from another app's share
                // sheet, for any audio file (see CFBundleDocumentTypes).
                .onOpenURL { url in
                    Task { await model.importRecording(from: url) }
                }
                // Meetings left waiting (the on-device model won't summarise for a
                // backgrounded app) finish as soon as the app is open again.
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active else { return }
                    Task { await model.resumeWaitingWork() }
                }
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.capability.allowsRecording {
                MeetingListView()
            } else {
                UnsupportedDeviceView(status: model.capability) {
                    model.refreshCapability()
                }
            }
        }
    }
}


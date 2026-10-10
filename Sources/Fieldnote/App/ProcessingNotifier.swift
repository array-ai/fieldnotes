import FieldnoteKit
import Foundation
import UserNotifications

/// A local notification when a meeting finishes processing, so the user can pocket
/// the phone after pressing stop. Local only: nothing goes through a push server.
///
/// The notification shows the meeting title and its first topic headline, which can
/// appear on the lock screen. It's on by default and can be turned off in Settings.
public final class ProcessingNotifier: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {

    public static let shared = ProcessingNotifier()
    public static let enabledKey = "notifyWhenProcessed"

    /// Set by the app: opens the meeting a tapped notification refers to.
    @MainActor public var onOpen: ((UUID) -> Void)?

    private static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    /// Asks once, the first time it matters (after a recording stops).
    public func requestPermissionIfNeeded() async {
        guard Self.isEnabled else { return }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        DebugLog.shared.log("notify", "notification permission \(granted ? "granted" : "declined")")
    }

    public func notifyFinished(meetingID: UUID, title: String, headline: String?) async {
        await post(
            meetingID: meetingID,
            title: "Notes ready",
            body: headline.map { "\(title): \($0)" } ?? title
        )
    }

    public func notifyWaiting(meetingID: UUID, title: String) async {
        await post(
            meetingID: meetingID,
            title: "Almost there",
            body: "\(title): transcript and speakers are done. Open Fieldnote to finish the notes."
        )
    }

    public func notifyFailed(meetingID: UUID, title: String) async {
        await post(
            meetingID: meetingID,
            title: "Processing stopped",
            body: "\(title) couldn't be finished. Open it to see why."
        )
    }

    private func post(meetingID: UUID, title: String, body: String) async {
        guard Self.isEnabled else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = ["meetingID": meetingID.uuidString]
        let request = UNNotificationRequest(identifier: meetingID.uuidString, content: content, trigger: nil)
        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            DebugLog.shared.log("notify", "couldn't post notification: \(error)")
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    // The completion-handler forms, finished on the main thread. The async forms
    // completed on whatever thread the task ended on, and UIKit, refreshing the app
    // snapshot as the response finished, asserted it was on the main thread: a crash
    // when a notification was tapped after iOS had unloaded the app (build 60).

    /// Shown as a banner even when the app is open on another screen.
    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        nonisolated(unsafe) let done = completionHandler
        DispatchQueue.main.async { done([.banner, .list, .sound]) }
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let id = (response.notification.request.content.userInfo["meetingID"] as? String).flatMap(UUID.init(uuidString:))
        nonisolated(unsafe) let done = completionHandler
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                if let id { self.onOpen?(id) }
            }
            done()
        }
    }
}

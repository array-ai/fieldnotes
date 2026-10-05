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

    /// Shown as a banner even when the app is open on another screen.
    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard let raw = response.notification.request.content.userInfo["meetingID"] as? String,
              let id = UUID(uuidString: raw) else { return }
        await MainActor.run { onOpen?(id) }
    }
}

#if os(iOS)
import ActivityKit
import FieldnoteKit
import FieldnoteShared
import Foundation
import OSLog

/// The recording Live Activity and Dynamic Island: elapsed time, level meter,
/// pause/resume/stop (spec 4.1).
///
/// Updates are throttled to about 1 Hz. ActivityKit budgets frequent updates, and a
/// meter refreshed at buffer rate would spend that budget in the first minute of a
/// two-hour meeting.
///
/// # Why this holds an id rather than the Activity
///
/// `Activity.update` and `Activity.end` are `@concurrent` on iOS 27, and an `Activity`
/// held by this main-actor type belongs to the main actor's region — handing it to a
/// concurrent method is a data race the compiler rejects. So the main actor keeps only
/// the id (a `String`), and the ActivityKit calls happen in a nonisolated context that
/// looks the activity up for itself. Nothing non-`Sendable` crosses an isolation
/// boundary.
@MainActor
public final class RecordingActivityController {

    private let log = Logger(subsystem: "com.publicarray.fieldnotes", category: "liveactivity")
    private let attributes: RecordingActivityAttributes
    private var activityID: String?
    private var startedAt = Date()
    private var lastUpdate = Date.distantPast

    public init(meetingID: UUID, title: String, type: MeetingType) {
        self.attributes = RecordingActivityAttributes(meetingID: meetingID, title: title, meetingType: type)
    }

    public func start(startedAt: Date) async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        self.startedAt = startedAt
        let state = RecordingActivityAttributes.ContentState(
            startedAt: startedAt,
            elapsed: 0,
            level: 0,
            isPaused: false
        )
        do {
            // The returned Activity is not stored: only its id leaves this scope.
            let activity = try Activity.request(
                attributes: attributes,
                content: .init(state: state, staleDate: nil)
            )
            activityID = activity.id
        } catch {
            log.error("Live Activity refused: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func update(elapsed: TimeInterval, level: Double, isPaused: Bool) async {
        guard let activityID else { return }
        guard isPaused || Date().timeIntervalSince(lastUpdate) >= 1 else { return }
        lastUpdate = Date()
        let state = RecordingActivityAttributes.ContentState(
            startedAt: startedAt,
            elapsed: elapsed,
            level: level,
            isPaused: isPaused
        )
        await Self.push(state: state, toActivityWithID: activityID)
    }

    public func end() async {
        guard let activityID else { return }
        self.activityID = nil
        await Self.end(activityWithID: activityID)
    }

    // MARK: - Off the main actor

    /// Looks the activity up here rather than receiving it, so the value is created
    /// and consumed in the same isolation region.
    private nonisolated static func push(
        state: RecordingActivityAttributes.ContentState,
        toActivityWithID id: String
    ) async {
        guard let activity = Activity<RecordingActivityAttributes>.activities.first(where: { $0.id == id }) else {
            return
        }
        await activity.update(.init(state: state, staleDate: nil))
    }

    private nonisolated static func end(activityWithID id: String) async {
        guard let activity = Activity<RecordingActivityAttributes>.activities.first(where: { $0.id == id }) else {
            return
        }
        await activity.end(nil, dismissalPolicy: .immediate)
    }
}
#endif

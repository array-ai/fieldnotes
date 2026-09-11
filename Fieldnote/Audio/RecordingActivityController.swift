#if os(iOS)
import ActivityKit
import Foundation
import OSLog

/// The recording Live Activity and Dynamic Island: elapsed time, level meter,
/// pause/resume/stop (spec 4.1).
///
/// Updates are throttled to about 1 Hz. ActivityKit budgets frequent updates, and a
/// meter refreshed at buffer rate would spend that budget in the first minute of a
/// two-hour meeting.
@MainActor
public final class RecordingActivityController {

    private let log = Logger(subsystem: "com.publicarray.fieldnotes", category: "liveactivity")
    private let attributes: RecordingActivityAttributes
    private var activity: Activity<RecordingActivityAttributes>?
    private var lastUpdate = Date.distantPast

    public init(meetingID: UUID, title: String, type: MeetingType) {
        self.attributes = RecordingActivityAttributes(meetingID: meetingID, title: title, meetingType: type)
    }

    public func start(startedAt: Date) async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let state = RecordingActivityAttributes.ContentState(
            startedAt: startedAt,
            elapsed: 0,
            level: 0,
            isPaused: false
        )
        do {
            activity = try Activity.request(
                attributes: attributes,
                content: .init(state: state, staleDate: nil)
            )
        } catch {
            log.error("Live Activity refused: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func update(elapsed: TimeInterval, level: Double, isPaused: Bool) async {
        guard let activity else { return }
        guard isPaused || Date().timeIntervalSince(lastUpdate) >= 1 else { return }
        lastUpdate = Date()
        let state = RecordingActivityAttributes.ContentState(
            startedAt: activity.content.state.startedAt,
            elapsed: elapsed,
            level: level,
            isPaused: isPaused
        )
        await activity.update(.init(state: state, staleDate: nil))
    }

    public func end() async {
        guard let activity else { return }
        await activity.end(nil, dismissalPolicy: .immediate)
        self.activity = nil
    }
}
#endif

// os(iOS), not canImport(ActivityKit): the module *does* import on macOS, but every
// type in it is marked unavailable there, so canImport lets the file through and then
// the compiler rejects the conformance.
#if os(iOS)
import ActivityKit
import FieldnoteKit
import Foundation

/// Drives the recording Live Activity and Dynamic Island. Shared between the app and
/// the widget extension.
///
/// Nothing here is meeting content: no transcript, no summary, no speaker name. The
/// title is the user-typed meeting title, which the user chose to put on their own
/// Lock Screen.
public struct RecordingActivityAttributes: ActivityAttributes, Sendable {
    public struct ContentState: Codable, Hashable, Sendable {
        public var startedAt: Date
        /// Seconds of audio captured, excluding paused time.
        public var elapsed: TimeInterval
        /// 0...1, smoothed peak power for the level meter.
        public var level: Double
        public var isPaused: Bool

        public init(startedAt: Date, elapsed: TimeInterval, level: Double, isPaused: Bool) {
            self.startedAt = startedAt
            self.elapsed = elapsed
            self.level = level
            self.isPaused = isPaused
        }
    }

    public var meetingID: UUID
    public var title: String
    public var meetingType: MeetingType

    public init(meetingID: UUID, title: String, meetingType: MeetingType) {
        self.meetingID = meetingID
        self.title = title
        self.meetingType = meetingType
    }
}
#endif

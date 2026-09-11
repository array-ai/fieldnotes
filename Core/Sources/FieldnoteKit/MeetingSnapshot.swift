import Foundation

/// A `Sendable` copy of a meeting for use outside the store.
public struct MeetingSnapshot: Sendable, Identifiable, Hashable {
    public var id: UUID
    public var title: String
    public var type: MeetingType
    public var startedAt: Date
    public var duration: TimeInterval
    public var state: ProcessingState
    public var failureMessage: String?
    public var folderName: String?
    public var segments: [TranscriptSegment]
    public var speakerNames: [String: String]
    public var summary: MeetingSummary?

    public init(
        id: UUID = UUID(),
        title: String,
        type: MeetingType,
        startedAt: Date,
        duration: TimeInterval = 0,
        state: ProcessingState = .complete,
        failureMessage: String? = nil,
        folderName: String? = nil,
        segments: [TranscriptSegment] = [],
        speakerNames: [String: String] = [:],
        summary: MeetingSummary? = nil
    ) {
        self.id = id
        self.title = title
        self.type = type
        self.startedAt = startedAt
        self.duration = duration
        self.state = state
        self.failureMessage = failureMessage
        self.folderName = folderName
        self.segments = segments
        self.speakerNames = speakerNames
        self.summary = summary
    }
}

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
    /// When processing is expected to finish, while it is running.
    public var estimatedCompletion: Date?
    public var folderName: String?
    public var segments: [TranscriptSegment]
    public var speakerNames: [String: String]
    public var summary: MeetingSummary?
    /// Where the recording started, if the user opted in.
    public var latitude: Double?
    public var longitude: Double?
    /// A readable name for those coordinates: the nearest town from the offline
    /// table, or a building or business from Apple Maps when that is turned on.
    public var placeName: String?

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
        summary: MeetingSummary? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil,
        placeName: String? = nil,
        estimatedCompletion: Date? = nil
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
        self.latitude = latitude
        self.longitude = longitude
        self.placeName = placeName
        self.estimatedCompletion = estimatedCompletion
    }
}

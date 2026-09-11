import Foundation

/// What a killed pipeline run needs to know to pick up where it stopped.
///
/// The system terminates continued-processing tasks under memory pressure, and long
/// tasks expire unpredictably in production even when they behave in testing
/// (spec 4.7). So every stage writes its output to disk and stamps the checkpoint
/// before the next stage starts. A resumed run never re-does a completed stage, and
/// never restarts from raw audio.
public struct ProcessingCheckpoint: Codable, Sendable {
    public var meetingID: UUID
    public var completedStages: Set<ProcessingStage>
    /// Highest chunk index already transcribed. Lets the transcribing stage itself
    /// resume part-way, which matters most: it is the longest stage.
    public var lastTranscribedChunkIndex: Int?
    public var updatedAt: Date
    public var failureCount: Int

    public init(meetingID: UUID) {
        self.meetingID = meetingID
        self.completedStages = []
        self.lastTranscribedChunkIndex = nil
        self.updatedAt = Date()
        self.failureCount = 0
    }

    public func isComplete(_ stage: ProcessingStage) -> Bool {
        completedStages.contains(stage)
    }

    public var nextStage: ProcessingStage? {
        ProcessingStage.allCases.first { !completedStages.contains($0) }
    }
}

import FieldnoteKit
import Foundation

/// Supplies work to the coordinator and takes the results back. Implemented by
/// `MeetingStore`; kept as a protocol so the pipeline layer does not depend on
/// SwiftData.
public protocol ProcessingJobProvider: Sendable {
    /// Meetings that stopped recording but have not finished processing, oldest first.
    func pendingJobs() async -> [ProcessingPipeline.Input]
    func markStage(_ stage: ProcessingStage, meetingID: UUID, estimatedCompletion: Date?) async
    func apply(_ output: ProcessingPipeline.Output, to meetingID: UUID) async
    func markFailed(meetingID: UUID, message: String) async
}

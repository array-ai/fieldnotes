import FieldnoteKit
import Foundation

/// Supplies work to the coordinator and takes the results back. Implemented by
/// `MeetingStore`; kept as a protocol so the pipeline layer does not depend on
/// SwiftData.
public protocol ProcessingJobProvider: Sendable {
    /// Meetings that stopped recording but have not finished processing, oldest first.
    func pendingJobs() async -> [ProcessingPipeline.Input]
    /// Whether a meeting is still waiting for processing. Cheap: no audio files read.
    func isPending(_ meetingID: UUID) async -> Bool
    func markStage(_ stage: ProcessingStage, meetingID: UUID, estimatedCompletion: Date?) async
    /// Transcript and speakers, before the summary: shown while it's written.
    func applyTranscript(_ segments: [TranscriptSegment], embeddings: [String: [Float]], replacesEditedSegments: Bool, to meetingID: UUID) async
    func apply(_ output: ProcessingPipeline.Output, to meetingID: UUID) async
    func markFailed(meetingID: UUID, message: String) async
    /// Paused, not failed: stays queued with a note saying why.
    func markWaiting(meetingID: UUID, message: String) async
}

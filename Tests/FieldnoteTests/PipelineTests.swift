import Foundation
import Testing

@Suite("Pipeline bookkeeping")
struct PipelineTests {

    @Test("Stage weights cover the whole run exactly once")
    func stageWeights() {
        #expect(ProcessingStage.totalWeight == 100)
        #expect(ProcessingStage.transcribing.precedingWeight == 0)
        #expect(ProcessingStage.diarizing.precedingWeight == 60)
        #expect(ProcessingStage.summarising.precedingWeight == 80)
    }

    @Test("A checkpoint resumes at the next incomplete stage")
    func checkpointOrdering() {
        var checkpoint = ProcessingCheckpoint(meetingID: UUID())
        #expect(checkpoint.nextStage == .transcribing)

        checkpoint.completedStages.insert(.transcribing)
        #expect(checkpoint.nextStage == .diarizing)

        checkpoint.completedStages.insert(.diarizing)
        #expect(checkpoint.nextStage == .summarising)

        checkpoint.completedStages.insert(.summarising)
        #expect(checkpoint.nextStage == nil)
    }

    @Test("Checkpoints survive a round trip through disk encoding")
    func checkpointCodable() throws {
        var checkpoint = ProcessingCheckpoint(meetingID: UUID())
        checkpoint.completedStages = [.transcribing, .diarizing]
        checkpoint.lastTranscribedChunkIndex = 7

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let restored = try decoder.decode(ProcessingCheckpoint.self, from: encoder.encode(checkpoint))
        #expect(restored.completedStages == checkpoint.completedStages)
        #expect(restored.lastTranscribedChunkIndex == 7)
        #expect(restored.meetingID == checkpoint.meetingID)
    }

    @Test("Progress is reported across the whole run, not per stage")
    func progressMapping() {
        // What the background coordinator computes from (stage, fraction).
        func units(_ stage: ProcessingStage, _ fraction: Double) -> Int64 {
            stage.precedingWeight + Int64(Double(stage.progressWeight) * fraction)
        }
        #expect(units(.transcribing, 0.5) == 30)
        #expect(units(.diarizing, 0.5) == 70)
        #expect(units(.summarising, 1.0) == 100)
    }
}

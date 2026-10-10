import FieldnoteKit
import Foundation
import Testing

@Suite("Models used")
struct ModelsUsedTests {

    private func meeting(transcript: String? = nil, speakers: String? = nil, notes: String? = nil) -> MeetingSnapshot {
        var summary = MeetingSummary(overview: "Overview")
        summary.model = notes
        return MeetingSnapshot(
            title: "Standup", type: .general, startedAt: Date(timeIntervalSince1970: 0),
            summary: summary, transcriptModel: transcript, speakersModel: speakers
        )
    }

    @Test("The transcript line names whichever models are known")
    func transcriptModels() {
        #expect(meeting(transcript: "Parakeet TDT v3", speakers: "Nemotron 3").transcriptModelsUsed
            == "Transcript: Parakeet TDT v3 · Speakers: Nemotron 3")
        #expect(meeting(transcript: "Apple speech model").transcriptModelsUsed == "Transcript: Apple speech model")
        #expect(meeting(speakers: "Nemotron 3").transcriptModelsUsed == "Speakers: Nemotron 3")
        #expect(meeting().transcriptModelsUsed == nil)
    }

    @Test("The notes model comes from the summary, and survives speaker names")
    func summaryModel() {
        #expect(meeting(notes: "MiniCPM5 2B").summaryModelUsed == "Notes: MiniCPM5 2B")
        #expect(meeting().summaryModelUsed == nil)
        #expect(meeting(notes: "LFM2.5 1.2B").summary?.applyingSpeakerNames(["S1": "Priya"]).model == "LFM2.5 1.2B")
    }

    @Test("Notes saved before the model was recorded still decode")
    func oldSummaryDecodes() throws {
        let old = try JSONEncoder().encode(MeetingSummary(overview: "Old"))
        var json = try #require(try JSONSerialization.jsonObject(with: old) as? [String: Any])
        json.removeValue(forKey: "model")
        let decoded = try JSONDecoder().decode(MeetingSummary.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.overview == "Old")
        #expect(decoded.model == nil)
    }
}

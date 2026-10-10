import FieldnoteKit
import Foundation
import Testing

@Suite("Model credits")
struct ModelCreditTests {

    private func meeting(transcript: String? = nil, speakers: String? = nil, notes: String? = nil) -> MeetingSnapshot {
        var summary = MeetingSummary(overview: "Overview")
        summary.model = notes
        return MeetingSnapshot(
            title: "Standup", type: .general, startedAt: Date(timeIntervalSince1970: 0),
            summary: summary, transcriptModel: transcript, speakersModel: speakers
        )
    }

    @Test("The transcript credit names whichever models are known")
    func transcriptCredit() {
        #expect(meeting(transcript: "Parakeet TDT v3", speakers: "Nemotron 3").transcriptCredit
            == "Transcript by Parakeet TDT v3, speakers by Nemotron 3")
        #expect(meeting(transcript: "Apple speech model").transcriptCredit == "Transcript by Apple speech model")
        #expect(meeting(speakers: "Nemotron 3").transcriptCredit == "Speakers by Nemotron 3")
        #expect(meeting().transcriptCredit == nil)
    }

    @Test("The notes credit comes from the summary, and survives speaker names")
    func summaryCredit() {
        #expect(meeting(notes: "MiniCPM5 2B").summaryCredit == "Notes by MiniCPM5 2B")
        #expect(meeting().summaryCredit == nil)
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

import FieldnoteKit
import Foundation
import Testing

@Suite("Speaker name heuristics")
struct SpeakerNameHeuristicsTests {

    private func segment(_ text: String, speakerID: String? = "S1") -> TranscriptSegment {
        TranscriptSegment(start: 0, end: 1, text: text, speakerID: speakerID)
    }

    @Test("A plain self-introduction is recognised")
    func plainIntroduction() {
        let result = SpeakerNameHeuristics.selfIntroductions(in: [segment("My name is Priya.")])
        #expect(result == ["S1": "Priya"])
    }

    @Test("A first and last name are both taken")
    func firstAndLastName() {
        let result = SpeakerNameHeuristics.selfIntroductions(in: [segment("My name is Priya Raman.")])
        #expect(result == ["S1": "Priya Raman"])
    }

    @Test("A third word is not swept in as part of the name")
    func stopsAtTwoWords() {
        let result = SpeakerNameHeuristics.selfIntroductions(in: [segment("My name is Mary Jane Watson.")])
        #expect(result == ["S1": "Mary Jane"])
    }

    @Test("A lowercase word after the trigger yields no name rather than a guess")
    func lowercaseWordIsNotGuessed() {
        let result = SpeakerNameHeuristics.selfIntroductions(in: [segment("My name is really confusing.")])
        #expect(result.isEmpty)
    }

    @Test("A comma right after the name does not attach to it")
    func trailingPunctuationIsStripped() {
        let result = SpeakerNameHeuristics.selfIntroductions(in: [segment("My name is Bob, and I called about the invoice.")])
        #expect(result == ["S1": "Bob"])
    }

    @Test("A segment with no diarized speaker is skipped")
    func noSpeakerIsSkipped() {
        let result = SpeakerNameHeuristics.selfIntroductions(in: [segment("My name is Priya.", speakerID: nil)])
        #expect(result.isEmpty)
    }

    @Test("The first introduction for a speaker wins over a later, different one")
    func firstIntroductionWins() {
        let result = SpeakerNameHeuristics.selfIntroductions(in: [
            segment("My name is Priya."),
            segment("Actually my name is Pri.")
        ])
        #expect(result == ["S1": "Priya"])
    }

    @Test("Different speakers each get their own introduction")
    func multipleSpeakers() {
        let result = SpeakerNameHeuristics.selfIntroductions(in: [
            segment("My name is Priya.", speakerID: "S1"),
            segment("And my name is Dave.", speakerID: "S2")
        ])
        #expect(result == ["S1": "Priya", "S2": "Dave"])
    }

    @Test("Text with no introduction at all yields nothing")
    func noIntroduction() {
        let result = SpeakerNameHeuristics.selfIntroductions(in: [segment("I just wanted to test this out.")])
        #expect(result.isEmpty)
    }
}

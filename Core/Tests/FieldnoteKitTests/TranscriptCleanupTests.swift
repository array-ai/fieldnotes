import FieldnoteKit
import Foundation
import Testing

@Suite("Transcript clean-up")
struct TranscriptCleanupTests {

    let terms = ["Grafana", "Tailscale", "Kubernetes", "Datadog", "Okta"]
    let dictionary: Set<String> = ["we", "moved", "to", "last", "year", "the", "weather", "was", "fine",
                                   "tail", "scale", "is", "set", "up", "data", "dog", "okay", "already",
                                   "spelled", "right", "graphene", "graph", "on", "it"]

    private func segment(_ text: String) -> TranscriptSegment {
        let words = text.split(separator: " ").enumerated().map { index, word in
            TranscriptWord(text: word + " ", start: Double(index), end: Double(index) + 1)
        }
        return TranscriptSegment(start: 0, end: Double(words.count), text: text, words: words)
    }

    @Test("Asked about: split-up words, unknown near words, very near real words")
    func candidates() {
        let isWord = { self.dictionary.contains($0) }
        let lines = [
            segment("We moved to Grafina last year."),     // unknown word, near Grafana
            segment("The weather was fine."),
            segment("Tail scale is set up."),             // the custom word split up
            segment("Okay, Kubernetes is already spelled right."),
            segment("Graphene on it."),                    // real, but not near enough
        ]
        #expect(TranscriptCleanup.candidates(lines, terms: terms, isWord: isWord) == [0, 2])
        #expect(TranscriptCleanup.relevantTerms(lines.map(\.text), terms: terms, isWord: isWord) == ["Grafana", "Tailscale"])
    }

    @Test("Answer lines are checked against the line and the custom words")
    func parse() {
        let lines = ["We moved to Grafina last year.", "Tail scale is set up.", "The server is old."]
        let answer = """
            [1] | Grafina | Grafana
            2 | Tail scale | Tailscale
            3 | server | Kubernetes
            1 | Grafona | Grafana
            NONE
            """
        let fixes = TranscriptCleanup.parse(answer, lines: lines, terms: terms)
        #expect(fixes == [
            .init(line: 1, heard: "Grafina", term: "Grafana"),
            .init(line: 2, heard: "Tail scale", term: "Tailscale"),
        ])
    }

    @Test("A fix keeps timings and punctuation; two words can become one")
    func apply() {
        let fixed = TranscriptCleanup.apply(.init(line: 1, heard: "data dog", term: "Datadog"),
                                            to: segment("we had data dog, then left"))
        #expect(fixed?.text == "we had Datadog, then left")
        #expect(fixed?.words?[2].start == 2 && fixed?.words?[2].end == 4)
        #expect(TranscriptCleanup.apply(.init(line: 1, heard: "Grafina", term: "Grafana"), to: segment("nothing here")) == nil)
    }
}

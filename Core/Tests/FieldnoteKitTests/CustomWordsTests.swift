import FieldnoteKit
import Testing

@Suite("Custom words")
struct CustomWordsTests {

    @Test("Typed list: lines or commas, trimmed, repeats dropped")
    func parse() {
        #expect(CustomWords.parse(" Kubernetes\nGrafana, grafana\n\n ,Tailscale ") == ["Kubernetes", "Grafana", "Tailscale"])
    }

    @Test("The user's words extend the built-in list; their spelling wins")
    func merged() {
        let words = CustomWords.merged(user: ["grafana", "Tailscale"], builtIn: ["Kubernetes", "Grafana"])
        #expect(words == ["Kubernetes", "grafana", "Tailscale"])
    }

    private func words(_ text: String) -> [TranscriptWord] {
        text.split(separator: " ").enumerated().map { index, word in
            TranscriptWord(text: word + " ", start: Double(index), end: Double(index) + 1)
        }
    }

    @Test("One word for one keeps its time and punctuation")
    func oneForOne() {
        let fixed = WordRevision.apply(["we", "use", "Grafana", "today"], to: words("we use Grafina, today"))
        #expect(fixed.map(\.text) == ["we ", "use ", "Grafana, ", "today "])
        #expect(fixed[2].start == 2 && fixed[2].end == 3)
    }

    @Test("Two words for one span both")
    func twoForOne() {
        let fixed = WordRevision.apply(["move", "to", "Tailscale."], to: words("move to tail scale."))
        #expect(fixed.map(\.text) == ["move ", "to ", "Tailscale. "])
        #expect(fixed[2].start == 2 && fixed[2].end == 4)
    }

    @Test("One word for two splits its time")
    func oneForTwo() {
        let fixed = WordRevision.apply(["the", "Halo", "PSA", "ticket"], to: words("the Halopia ticket"))
        #expect(fixed.map(\.text) == ["the ", "Halo ", "PSA ", "ticket "])
        #expect(fixed[1].start == 1 && fixed[1].end == 1.5)
        #expect(fixed[2].start == 1.5 && fixed[2].end == 2)
    }

    @Test("Same words, different punctuation: nothing changes")
    func unchanged() {
        let original = words("Hello, there. Okay")
        #expect(WordRevision.apply(["Hello", "there", "Okay"], to: original) == original)
    }

    @Test("Swaps only respellings or non-words, never real words (build 46)")
    func shouldReplace() {
        let dictionary: Set<String> = ["plan", "sure", "data", "dog", "tail", "scale", "hit", "enter"]
        let isWord = { dictionary.contains($0) }
        #expect(CustomWords.shouldReplace(["Data", "Dog"], with: ["Datadog"], isWord: isWord))
        #expect(CustomWords.shouldReplace(["tail", "scale,"], with: ["Tailscale,"], isWord: isWord))
        #expect(CustomWords.shouldReplace(["Grafina"], with: ["Grafana"], isWord: isWord))
        #expect(!CustomWords.shouldReplace(["plan"], with: ["VLAN"], isWord: isWord))
        #expect(!CustomWords.shouldReplace(["sure"], with: ["Azure"], isWord: isWord))
        #expect(!CustomWords.shouldReplace(["hit", "enter."], with: ["hit", "Entra."], isWord: isWord))
    }

    @Test("A rejected swap keeps the original words and times")
    func rejected() {
        let original = words("the protection plan here")
        let fixed = WordRevision.apply(["the", "protection", "VLAN", "here"], to: original) { old, _ in old != ["plan "] }
        #expect(fixed == original)
    }
}

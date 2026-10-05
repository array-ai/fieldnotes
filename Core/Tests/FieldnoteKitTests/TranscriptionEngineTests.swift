import FieldnoteKit
import Foundation
import Testing

@Suite("Transcription engine")
struct TranscriptionEngineTests {

    private func words(_ text: String, gapAfter: [Int: Double] = [:]) -> [TranscriptWord] {
        var time = 0.0
        return text.split(separator: " ").enumerated().map { i, token in
            let word = TranscriptWord(text: token + " ", start: time, end: time + 0.3)
            time += 0.4 + (gapAfter[i] ?? 0)
            return word
        }
    }

    @Test("Lines end at sentences, once they have a few words")
    func sentences() {
        let lines = WordLines.lines(from: words("We need a new switch. Okay. Who orders it? I will do it today."))
        #expect(lines.map(\.text) == ["We need a new switch.", "Okay. Who orders it?", "I will do it today."])
    }

    @Test("A pause starts a new line")
    func pauses() {
        let lines = WordLines.lines(from: words("so that is settled then right", gapAfter: [2: 1.5]))
        #expect(lines.map(\.text) == ["so that is", "settled then right"])
    }

    @Test("Long runs are capped")
    func cap() {
        let lines = WordLines.lines(from: words(Array(repeating: "word", count: 90).joined(separator: " ")), maxWords: 40)
        #expect(lines.map { $0.words?.count ?? 0 } == [40, 40, 10])
    }

    @Test("Lines keep their words and timings")
    func timings() {
        let lines = WordLines.lines(from: words("hello there everyone."))
        #expect(lines.first?.words?.count == 3)
        #expect(lines.first?.start == 0)
        #expect(abs((lines.first?.end ?? 0) - 1.1) < 1e-9)
    }

    @Test("Parakeet covers European languages, not others")
    func languages() {
        #expect(TranscriptionEngine.parakeetSupports("en_AU"))
        #expect(TranscriptionEngine.parakeetSupports("de-DE"))
        #expect(!TranscriptionEngine.parakeetSupports("ja_JP"))
        #expect(!TranscriptionEngine.parakeetSupports("zh-Hans"))
        #expect(!TranscriptionEngine.parakeetSupports("sr_RS"))
        #expect(TranscriptionEngine.parakeetLanguages.count == 25)
    }

    @Test("English-only models only take English")
    func englishOnly() {
        #expect(TranscriptionEngine.parakeetV2.supports("en_AU"))
        #expect(!TranscriptionEngine.parakeetV2.supports("de_DE"))
        #expect(TranscriptionEngine.parakeetCtc110m.supports("en-US"))
        #expect(TranscriptionEngine.apple.supports("ja_JP"))
    }

    @Test("Every downloadable engine has a pack, and the stored v3 value still decodes")
    func packs() {
        #expect(TranscriptionEngine.apple.modelPack == nil)
        #expect(TranscriptionEngine.allCases.filter { $0 != .apple }.allSatisfy { $0.modelPack != nil })
        #expect(TranscriptionEngine(storedValue: "parakeet") == .parakeet)
        #expect(SummaryEngine(storedValue: nil) == .apple)
        #expect(SummaryEngine.minicpm5.modelPack == .minicpm5)
    }

    @Test("A chip family picks its compiled summary model; others get the portable one")
    func compiledPacks() {
        #expect(ModelPack.ID.minicpm5.compiled(for: "h17g") == .minicpm5H17g)
        #expect(ModelPack.ID.minicpm5.compiled(for: "h18p") == .minicpm5H18p)
        #expect(ModelPack.ID.minicpm5.compiled(for: "h16p") == nil)
        #expect(ModelPack.ID.minicpm5.compiled(for: nil) == nil)
        #expect(ModelPack.pack(.minicpm5).bundleFolder == "ios-static")
        #expect(ModelPack.ID.minicpm5_2b.compiled(for: "h17p") == .minicpm5_2bH17p)
        #expect(ModelPack.ID.minicpm5_2b.compiled(for: "h17g") == nil)
        #expect(ModelPack.pack(.minicpm5_2bH17p).bundleFolder == "minicpm5-2b/ios-h17p")
        #expect(ModelPack.pack(.minicpm5H17p).bundleFolder == "ios-h17p")
    }

    @Test("Cards rate every model within 0...1")
    func cards() {
        let cards = TranscriptionEngine.allCases.map(\.card) + DiarizationMethod.allCases.map(\.card)
            + SummaryEngine.allCases.map(\.card)
        #expect(cards.allSatisfy { (0...1).contains($0.accuracy) && (0...1).contains($0.speed) && !$0.title.isEmpty })
    }

    @Test("The model catalog is pinned and hashed")
    func catalog() {
        for pack in ModelPack.catalog {
            #expect(pack.revision.count == 40, "\(pack.id) must pin a full commit, not a branch")
            #expect(!pack.files.isEmpty)
            #expect(pack.files.allSatisfy { $0.sha256.count == 64 && $0.size > 0 })
            #expect(pack.url(for: pack.files[0]).absoluteString.contains("/resolve/\(pack.revision)/"))
        }
        #expect(Set(ModelPack.catalog.map(\.id)) == Set(ModelPack.ID.allCases))
    }
}

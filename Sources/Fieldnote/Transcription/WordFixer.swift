import FieldnoteKit
import FluidAudio
import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Puts custom words into a Parakeet transcript ("Grafina" → "Grafana").
///
/// Parakeet can't be told words in advance. Once it has written the transcript, a
/// small CTC model (the optional "custom words" download) listens to the audio
/// again, and FluidAudio's rescorer swaps a word only when the sound supports the
/// custom one. Even then a real word is never swapped ("plan" sounds like "VLAN"):
/// see `CustomWords.shouldReplace`. Runs after Parakeet's models are
/// released, a window of about a minute at a time, so the meeting is never in
/// memory whole.
enum WordFixer {

    static var isInstalled: Bool { ModelDownloads.installedDirectory(for: .parakeetCtcWords) != nil }

    /// The words with custom words put in, or nil when there's nothing to do or the
    /// fixer failed (the transcript is used as Parakeet wrote it).
    static func fix(_ tokenTimings: [TokenTiming], meetingID: UUID, localeIdentifier: String) async -> [TranscriptWord]? {
        guard let directory = ModelDownloads.installedDirectory(for: .parakeetCtcWords),
              !tokenTimings.isEmpty else { return nil }
        let terms = MSPVocabulary.current
        guard !terms.isEmpty else { return nil }
        let debug = DebugLog.shared
        let id = DebugLog.short(meetingID)
        let started = ContinuousClock.now
        do {
            try placeTokenizer(from: directory)
            let models = try await CtcModels.loadDirect(from: directory, variant: .ctc110m)
            let session = try await VocabularyBoostingSession(
                vocabulary: CustomVocabularyContext(terms: terms.map { CustomVocabularyTerm(text: $0) }),
                ctcModels: models
            )
            let audio = try AudioSamples(meetingID: meetingID)
            let language = String(localeIdentifier.prefix(2)).lowercased()
            var fixed: [TranscriptWord] = []
            var replaced = 0, kept = 0
            for window in windows(tokenTimings) {
                guard let first = window.first, let last = window.last else { continue }
                let words = words(from: window)
                // A little audio either side, so a word at the edge is heard whole.
                let from = max(0, first.startTime - 0.5)
                let samples = try audio.slice(Int(from * 16_000)..<Int((last.endTime + 0.5) * 16_000))
                // The rescorer's clock starts at the slice.
                let local = window.map {
                    TokenTiming(token: $0.token, tokenId: $0.tokenId, startTime: $0.startTime - from,
                                endTime: $0.endTime - from, confidence: $0.confidence)
                }
                let text = words.map { $0.text.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
                if let output = await session.rescore(text: text, tokenTimings: local, audioSamples: samples),
                   output.wasModified {
                    let revised = output.text.split(separator: " ").map(String.init)
                    let result = await MainActor.run {
                        var swaps = 0, refusals = 0
                        let words = WordRevision.apply(revised, to: words) { old, new in
                            let ok = CustomWords.shouldReplace(old, with: new) { isWord($0, language: language) }
                            if ok { swaps += 1 } else { refusals += 1 }
                            return ok
                        }
                        return (words, swaps, refusals)
                    }
                    fixed += result.0
                    replaced += result.1
                    kept += result.2
                } else {
                    fixed += words
                }
            }
            // Counts only: the words themselves are meeting content.
            debug.log("transcript", "\(id): custom words: \(terms.count) term(s), \(replaced) swap(s) made, \(kept) refused (real words), in \(DebugLog.elapsed(since: started))")
            return fixed
        } catch {
            debug.log("transcript", "\(id): custom words skipped after \(DebugLog.elapsed(since: started)): \(error)")
            return nil
        }
    }

    /// Whether the system dictionary knows the word. Without a dictionary for the
    /// language, every word counts as real, so only respellings go through.
    @MainActor
    private static func isWord(_ word: String, language: String) -> Bool {
        #if canImport(UIKit)
        guard UITextChecker.availableLanguages.contains(where: { $0.hasPrefix(language) }) else { return true }
        let range = UITextChecker().rangeOfMisspelledWord(
            in: word, range: NSRange(location: 0, length: (word as NSString).length),
            startingAt: 0, wrap: false, language: language
        )
        return range.location == NSNotFound
        #else
        return true
        #endif
    }

    static func words(from tokenTimings: [TokenTiming]) -> [TranscriptWord] {
        buildWordTimings(from: tokenTimings).map {
            TranscriptWord(text: $0.word + " ", start: $0.startTime, end: $0.endTime)
        }
    }

    /// Runs of tokens about 40–60 s long, each starting at a word. A window ends after
    /// a sentence once it's 40 s long, or at any word at 60 s.
    private static func windows(_ tokens: [TokenTiming]) -> [[TokenTiming]] {
        var windows: [[TokenTiming]] = []
        var current: [TokenTiming] = []
        for token in tokens {
            let startsWord = token.token.hasPrefix("▁") || token.token.hasPrefix(" ")
            if startsWord, let first = current.first, let previous = current.last {
                let length = token.startTime - first.startTime
                let sentenceEnded = previous.token.last.map { ".?!".contains($0) } ?? false
                if length >= 60 || (length >= 40 && sentenceEnded) {
                    windows.append(current)
                    current = []
                }
            }
            current.append(token)
        }
        if !current.isEmpty { windows.append(current) }
        return windows
    }

    /// FluidAudio reads the CTC tokenizer from its own cache folder, whatever folder
    /// the models load from. Copied there from the verified download; nothing is
    /// fetched.
    private static func placeTokenizer(from directory: URL) throws {
        let manager = FileManager.default
        let target = CtcModels.defaultCacheDirectory(for: .ctc110m)
        let source = directory.appendingPathComponent("tokenizer.json")
        let copy = target.appendingPathComponent("tokenizer.json")
        if let have = try? manager.attributesOfItem(atPath: copy.path)[.size] as? Int,
           let want = try? manager.attributesOfItem(atPath: source.path)[.size] as? Int, have == want { return }
        try manager.createDirectory(at: target, withIntermediateDirectories: true)
        try? manager.removeItem(at: copy)
        try manager.copyItem(at: source, to: copy)
    }
}

import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// iOS's spelling dictionary: whether a word is a real word, so custom words never
/// replace one by sound alone (see `CustomWords` and `TranscriptCleanup`).
enum SpellingDictionary {

    /// The words that are real, from those given (lowercase letters and digits).
    /// Without a dictionary for the language, every word counts as real.
    @MainActor
    static func realWords(_ words: Set<String>, language: String) -> Set<String> {
        #if canImport(UIKit)
        guard UITextChecker.availableLanguages.contains(where: { $0.hasPrefix(language) }) else { return words }
        let checker = UITextChecker()
        return words.filter { word in
            checker.rangeOfMisspelledWord(
                in: word, range: NSRange(location: 0, length: (word as NSString).length),
                startingAt: 0, wrap: false, language: language
            ).location == NSNotFound
        }
        #else
        return words
        #endif
    }

    /// The language of the transcripts, from Settings ("en_AU" → "en").
    static var transcriptLanguage: String {
        String((UserDefaults.standard.string(forKey: "locale") ?? "en").prefix(2)).lowercased()
    }
}

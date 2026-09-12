import Foundation

/// Deterministic self-introduction detection, independent of the on-device LLM.
///
/// The LLM-based extraction in `DraftChunkNotes.speakerNames` (Fieldnote target) can
/// miss an obvious "My name is X" on a very short excerpt -- there is no way to verify
/// or tune an on-device model's compliance from outside a real device, and stacking
/// several "don't report X as a name" guardrails into the same prompt (to stop speaker
/// labels leaking into `mentionedSystems`) plausibly makes it over-cautious about
/// genuine names too. This runs directly against diarized segments instead: no
/// citation to resolve, since the segment's own `speakerID` is already ground truth.
///
/// Deliberately narrow. A wrong guess here is worse than a miss (the same reasoning as
/// `SpeakerAlignment`'s "don't guess" rule) -- covers only the highest-precision
/// phrasing, not every way a person might name themselves.
public enum SpeakerNameHeuristics {

    /// Speaker label to name, for every speaker whose first self-introduction this
    /// recognises. First introduction per speaker wins.
    public static func selfIntroductions(in segments: [TranscriptSegment]) -> [String: String] {
        var result: [String: String] = [:]
        for segment in segments {
            guard let speakerID = segment.speakerID, result[speakerID] == nil else { continue }
            if let name = extractName(from: segment.text) {
                result[speakerID] = name
            }
        }
        return result
    }

    private static let triggers = ["my name is ", "my name's ", "my names "]

    static func extractName(from text: String) -> String? {
        let lowered = text.lowercased()
        for trigger in triggers {
            guard let range = lowered.range(of: trigger) else { continue }
            // Map the match back onto the original (still-cased) text so the
            // extracted name keeps its real capitalisation.
            let offset = lowered.distance(from: lowered.startIndex, to: range.upperBound)
            let start = text.index(text.startIndex, offsetBy: offset)
            if let name = capitalizedNamePrefix(of: text[start...]) {
                return name
            }
        }
        return nil
    }

    /// Takes up to two consecutive capitalised words (first name, optional last name)
    /// immediately following the trigger phrase. Stops at the first word that isn't
    /// capitalised -- "my name is really confusing" stops at "really" and yields
    /// nothing, rather than guessing.
    private static func capitalizedNamePrefix(of text: Substring) -> String? {
        var words: [String] = []
        for word in text.split(separator: " ") {
            let cleaned = word.trimmingCharacters(in: .punctuationCharacters)
            guard let first = cleaned.first, first.isUppercase else { break }
            words.append(cleaned)
            if words.count == 2 { break }
        }
        guard !words.isEmpty else { return nil }
        return words.joined(separator: " ")
    }
}

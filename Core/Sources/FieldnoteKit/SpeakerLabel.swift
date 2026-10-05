import Foundation

/// How an unnamed speaker is shown to people: "Speaker A", "Speaker B", …
///
/// Diarization labels speakers "S1", "S2" in order of first appearance, and those
/// stay the stored IDs. This is display only: every screen, export and prompt shows
/// the letter form unless the speaker has been given a name.
public enum SpeakerLabel {

    /// "S1" → "Speaker A", "S26" → "Speaker Z", "S27" → "Speaker AA". Anything that
    /// isn't an `S<number>` label is returned unchanged; nil is "Unknown".
    public static func display(_ id: String?) -> String {
        guard let id else { return "Unknown" }
        guard id.hasPrefix("S"), let number = Int(id.dropFirst()), number > 0 else { return id }
        return "Speaker \(letters(number))"
    }

    /// The name to show: the speaker's given name if there is one, else the letter form.
    public static func name(_ id: String?, names: [String: String]) -> String {
        guard let id else { return "Unknown" }
        return names[id] ?? display(id)
    }

    /// Spreadsheet-style column letters: 1 → A, 26 → Z, 27 → AA.
    static func letters(_ number: Int) -> String {
        var n = number
        var result = ""
        while n > 0 {
            let remainder = (n - 1) % 26
            result = String(UnicodeScalar(UInt8(65 + remainder))) + result
            n = (n - 1) / 26
        }
        return result
    }
}

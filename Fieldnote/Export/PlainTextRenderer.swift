import Foundation

/// Plain text for the share targets that mangle Markdown — Teams' message box, SMS,
/// a ticket note field.
public enum PlainTextRenderer {

    public static func from(markdown: String) -> String {
        markdown
            .components(separatedBy: .newlines)
            .map(transform)
            .joined(separator: "\n")
            .replacingOccurrences(of: "\n\n\n", with: "\n\n")
    }

    private static func transform(_ line: String) -> String {
        var text = line

        if text.hasPrefix("# ") { text = String(text.dropFirst(2)).uppercased() }
        else if text.hasPrefix("## ") { text = String(text.dropFirst(3)).uppercased() }
        else if text.hasPrefix("### ") { text = String(text.dropFirst(4)) }
        else if text.hasPrefix("> ") { text = "Note: " + String(text.dropFirst(2)) }

        text = text
            .replacingOccurrences(of: "- [ ] ", with: "☐ ")
            .replacingOccurrences(of: "- [x] ", with: "☑ ")
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")

        // Italics are marked with single underscores around a whole line in our output.
        if text.hasPrefix("_"), text.hasSuffix("_"), text.count > 2 {
            text = String(text.dropFirst().dropLast())
        }
        return text
    }
}

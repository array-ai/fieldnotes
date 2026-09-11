import Foundation

/// `YYYY-MM-DD Folder - Title` (spec 6.4), with anything a filesystem or a share
/// target would object to removed.
public enum ExportFilename {

    public static func base(date: Date, folder: String?, title: String, calendar: Calendar = .current) -> String {
        var components = [isoDate(date, calendar: calendar)]
        if let folder = sanitise(folder ?? ""), !folder.isEmpty {
            components.append(folder)
        }
        let cleanTitle = sanitise(title) ?? ""
        let stem = components.joined(separator: " ")
        return cleanTitle.isEmpty ? stem : "\(stem) - \(cleanTitle)"
    }

    public static func name(
        date: Date,
        folder: String?,
        title: String,
        suffix: String? = nil,
        fileExtension: String,
        calendar: Calendar = .current
    ) -> String {
        var stem = base(date: date, folder: folder, title: title, calendar: calendar)
        if let suffix, !suffix.isEmpty { stem += " \(suffix)" }
        return "\(stem).\(fileExtension)"
    }

    static func isoDate(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// Strips path separators, colons and control characters, collapses whitespace,
    /// and keeps the result short enough to survive being emailed around.
    static func sanitise(_ text: String) -> String? {
        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t")
        let cleaned = text
            .components(separatedBy: forbidden)
            .joined(separator: " ")
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        return String(cleaned.prefix(80))
    }
}

public enum Timecode {
    /// `1:02:03` or `12:03`. For reading.
    public static func short(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }

    /// `00:01:02.345`. WebVTT.
    public static func vtt(_ seconds: TimeInterval) -> String {
        let clamped = max(0, seconds)
        let total = Int(clamped)
        let milliseconds = Int((clamped - Double(total)) * 1000)
        return String(format: "%02d:%02d:%02d.%03d", total / 3600, (total % 3600) / 60, total % 60, milliseconds)
    }

    /// `00:01:02,345`. SRT, which uses a comma.
    public static func srt(_ seconds: TimeInterval) -> String {
        vtt(seconds).replacingOccurrences(of: ".", with: ",")
    }
}

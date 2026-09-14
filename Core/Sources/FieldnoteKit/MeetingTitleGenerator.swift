import Foundation

/// The default title a new meeting starts with, before anything is known about its
/// content. Deterministic and offline: date/time and, optionally, coordinates. An
/// LLM-refined title from the transcript is a later addition, not this one.
public enum MeetingTitleGenerator {

    public static func defaultTitle(
        type: MeetingType,
        date: Date = Date(),
        locale: Locale = .autoupdatingCurrent,
        coordinate: (latitude: Double, longitude: Double)? = nil
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate("d MMM, h:mm a")
        let when = formatter.string(from: date)

        let label = type == .general ? "Meeting" : type.displayName
        guard let coordinate else { return "\(label) – \(when)" }
        let lat = String(format: "%.3f", coordinate.latitude)
        let lon = String(format: "%.3f", coordinate.longitude)
        return "\(label) – \(when) (\(lat), \(lon))"
    }
}

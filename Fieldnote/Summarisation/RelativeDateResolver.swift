import Foundation

/// Resolves spoken due dates against the meeting's own date, not against generation
/// time (spec 4.5). A meeting recorded Friday and summarised on Monday must still
/// resolve "next Tuesday" the way the room meant it.
///
/// Deliberately conservative: it returns `nil` rather than guessing. An unresolved
/// phrase is still shown verbatim in the summary, so nothing is lost by declining —
/// whereas a wrong date lands in someone's Reminders and gets trusted.
public struct RelativeDateResolver: Sendable {
    /// Time of day assigned to a resolved date, in hours. 17:00 local: "Tuesday"
    /// means end of Tuesday, not midnight at the start of it.
    public var dueHour: Int
    public var calendar: Calendar

    public init(calendar: Calendar = .autoupdatingCurrent, dueHour: Int = 17) {
        var calendar = calendar
        // Australian working week. Affects "end of week" and weekday arithmetic.
        calendar.firstWeekday = 2
        self.calendar = calendar
        self.dueHour = dueHour
    }

    public func resolve(_ phrase: String?, relativeTo meetingDate: Date) -> Date? {
        guard let phrase else { return nil }
        let text = normalise(phrase)
        guard !text.isEmpty else { return nil }

        if let days = fixedOffsetDays(in: text) {
            return endOfDay(byAdding: .day, value: days, to: meetingDate)
        }
        if let interval = numericInterval(in: text) {
            return endOfDay(byAdding: interval.unit, value: interval.value, to: meetingDate)
        }
        if let weekday = weekdayTarget(in: text) {
            return resolveWeekday(weekday, wantsNextWeek: text.contains("next"), from: meetingDate)
        }
        if text.contains("end of the month") || text.contains("end of month") || text.contains("month end") {
            return endOfMonth(containing: meetingDate)
        }
        if text.contains("next month") {
            guard let shifted = calendar.date(byAdding: .month, value: 1, to: meetingDate) else { return nil }
            return endOfMonth(containing: shifted)
        }
        if text.contains("end of the week") || text.contains("end of week") {
            return resolveWeekday(6, wantsNextWeek: false, from: meetingDate) // Friday
        }
        if text.contains("next week") {
            guard let shifted = calendar.date(byAdding: .weekOfYear, value: 1, to: meetingDate) else { return nil }
            return resolveWeekday(6, wantsNextWeek: false, from: startOfWeek(for: shifted))
        }
        if text.contains("end of the quarter") || text.contains("end of quarter") {
            return endOfQuarter(containing: meetingDate)
        }
        return nil
    }

    // MARK: - Pieces

    private func normalise(_ phrase: String) -> String {
        phrase
            .lowercased()
            .replacingOccurrences(of: "cob", with: "")
            .replacingOccurrences(of: "eod", with: "")
            .replacingOccurrences(of: "close of business", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func fixedOffsetDays(in text: String) -> Int? {
        if text == "today" || text == "this afternoon" || text == "tonight" { return 0 }
        if text == "tomorrow" || text.hasPrefix("tomorrow") { return 1 }
        if text.contains("day after tomorrow") { return 2 }
        return nil
    }

    private struct Interval { var unit: Calendar.Component; var value: Int }

    /// "in 3 days", "in two weeks", "within 5 business days".
    private func numericInterval(in text: String) -> Interval? {
        let words: [String: Int] = [
            "a": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
            "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10, "couple of": 2, "couple": 2
        ]
        let unitMap: [(String, Calendar.Component)] = [
            ("day", .day), ("week", .weekOfYear), ("month", .month), ("fortnight", .weekOfYear)
        ]

        for (needle, component) in unitMap where text.contains(needle) {
            let scale = needle == "fortnight" ? 2 : 1
            if let digits = firstInteger(in: text) {
                return Interval(unit: component, value: digits * scale)
            }
            for (word, value) in words where text.contains("\(word) \(needle)") {
                return Interval(unit: component, value: value * scale)
            }
            if needle == "fortnight" { return Interval(unit: .weekOfYear, value: 2) }
        }
        return nil
    }

    private func firstInteger(in text: String) -> Int? {
        let scanner = Scanner(string: text)
        scanner.charactersToBeSkipped = CharacterSet.decimalDigits.inverted
        var value = 0
        return scanner.scanInt(&value) ? value : nil
    }

    /// 1 = Sunday ... 7 = Saturday, matching `Calendar.component(.weekday:)`.
    private func weekdayTarget(in text: String) -> Int? {
        let names: [(String, Int)] = [
            ("sunday", 1), ("monday", 2), ("tuesday", 3), ("wednesday", 4),
            ("thursday", 5), ("friday", 6), ("saturday", 7)
        ]
        return names.first { text.contains($0.0) }?.1
    }

    private func resolveWeekday(_ weekday: Int, wantsNextWeek: Bool, from date: Date) -> Date? {
        let current = calendar.component(.weekday, from: date)
        var delta = (weekday - current + 7) % 7
        // "Tuesday" spoken on a Tuesday means the coming Tuesday, not today.
        if delta == 0 { delta = 7 }
        if wantsNextWeek {
            // "next Tuesday" means the Tuesday of the following week. If the coming
            // Tuesday is already in the following week, that is the one.
            let candidate = calendar.date(byAdding: .day, value: delta, to: date)
            if let candidate, calendar.isDate(candidate, equalTo: date, toGranularity: .weekOfYear) {
                delta += 7
            }
        }
        return endOfDay(byAdding: .day, value: delta, to: date)
    }

    private func startOfWeek(for date: Date) -> Date {
        calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? date
    }

    private func endOfDay(byAdding component: Calendar.Component, value: Int, to date: Date) -> Date? {
        guard let shifted = calendar.date(byAdding: component, value: value, to: date) else { return nil }
        return calendar.date(bySettingHour: dueHour, minute: 0, second: 0, of: shifted)
    }

    private func endOfMonth(containing date: Date) -> Date? {
        guard let interval = calendar.dateInterval(of: .month, for: date),
              let last = calendar.date(byAdding: .day, value: -1, to: interval.end) else { return nil }
        return calendar.date(bySettingHour: dueHour, minute: 0, second: 0, of: last)
    }

    private func endOfQuarter(containing date: Date) -> Date? {
        let month = calendar.component(.month, from: date)
        let lastMonthOfQuarter = ((month - 1) / 3) * 3 + 3
        var components = calendar.dateComponents([.year], from: date)
        components.month = lastMonthOfQuarter
        components.day = 1
        guard let firstOfLastMonth = calendar.date(from: components) else { return nil }
        return endOfMonth(containing: firstOfLastMonth)
    }
}

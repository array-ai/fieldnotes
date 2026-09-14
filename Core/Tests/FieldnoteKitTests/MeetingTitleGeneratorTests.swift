import FieldnoteKit
import Foundation
import Testing

@Suite("Meeting title generator")
struct MeetingTitleGeneratorTests {

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Australia/Sydney")!
        return calendar
    }

    /// Tuesday 8 September 2026, 14:30.
    private var date: Date {
        DateComponents(calendar: calendar, year: 2026, month: 9, day: 8, hour: 14, minute: 30).date!
    }

    private var locale: Locale { Locale(identifier: "en_AU") }

    @Test("Neutral type reads as a plain meeting, not \"General\"")
    func neutralType() {
        let title = MeetingTitleGenerator.defaultTitle(type: .general, date: date, locale: locale)
        #expect(title.hasPrefix("Meeting"))
        #expect(!title.contains("General"))
    }

    @Test("A specific type names itself")
    func specificType() {
        let title = MeetingTitleGenerator.defaultTitle(type: .siteVisit, date: date, locale: locale)
        #expect(title.hasPrefix("Site visit"))
    }

    @Test("A coordinate is appended when present")
    func withCoordinate() {
        let title = MeetingTitleGenerator.defaultTitle(
            type: .general,
            date: date,
            locale: locale,
            coordinate: (latitude: -33.8688, longitude: 151.2093)
        )
        #expect(title.contains("-33.869"))
        #expect(title.contains("151.209"))
    }

    @Test("No coordinate means no parenthetical")
    func withoutCoordinate() {
        let title = MeetingTitleGenerator.defaultTitle(type: .general, date: date, locale: locale)
        #expect(!title.contains("("))
    }
}

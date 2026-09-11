import Foundation
import Testing

@Suite("Relative dates")
struct RelativeDateResolverTests {

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Australia/Sydney")!
        return calendar
    }

    /// Tuesday 8 September 2026, 10:00.
    private var meetingDate: Date {
        DateComponents(calendar: calendar, year: 2026, month: 9, day: 8, hour: 10).date!
    }

    private func resolve(_ phrase: String?) -> Date? {
        RelativeDateResolver(calendar: calendar).resolve(phrase, relativeTo: meetingDate)
    }

    private func day(_ date: Date?) -> Int? {
        date.map { calendar.component(.day, from: $0) }
    }

    @Test("Tomorrow is the next day at end of business")
    func tomorrow() {
        let resolved = try! #require(resolve("tomorrow"))
        #expect(day(resolved) == 9)
        #expect(calendar.component(.hour, from: resolved) == 17)
    }

    @Test("A weekday spoken on that same weekday means the next one, not today")
    func sameWeekdayMeansNextWeek() {
        // The meeting is on a Tuesday.
        #expect(day(resolve("Tuesday")) == 15)
    }

    @Test("'next Tuesday' from a Tuesday is a week and a bit out, not tomorrow")
    func nextTuesday() {
        #expect(day(resolve("next Tuesday")) == 15)
    }

    @Test("'Friday' resolves within the same week")
    func friday() {
        #expect(day(resolve("Friday")) == 11)
    }

    @Test("End of month is the last day of the meeting's month")
    func endOfMonth() {
        #expect(day(resolve("end of the month")) == 30)
    }

    @Test("Counted intervals work in words and digits")
    func countedIntervals() {
        #expect(day(resolve("in 3 days")) == 11)
        #expect(day(resolve("in two weeks")) == 22)
    }

    @Test("Business shorthand is stripped before parsing")
    func businessShorthand() {
        #expect(day(resolve("COB Friday")) == 11)
    }

    @Test("Anything unrecognised returns nil rather than a guess")
    func unknownPhrasesDecline() {
        #expect(resolve("when the parts land") == nil)
        #expect(resolve("") == nil)
        #expect(resolve(nil) == nil)
    }

    @Test("Resolution is relative to the meeting, not to now")
    func relativeToMeetingNotNow() {
        let old = DateComponents(calendar: calendar, year: 2026, month: 1, day: 5, hour: 9).date!
        let resolved = RelativeDateResolver(calendar: calendar).resolve("tomorrow", relativeTo: old)
        #expect(calendar.component(.month, from: try! #require(resolved)) == 1)
        #expect(day(resolved) == 6)
    }
}

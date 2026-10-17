import Foundation
import Testing
@testable import ClientCore

@Suite("Chat timestamp formatting")
struct ChatTimestampTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }()
    private let locale = Locale(identifier: "zh_Hans_CN")

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    @Test("same day renders only the clock")
    func sameDay() {
        let now = date(2026, 10, 17, 22, 30)
        let reply = date(2026, 10, 17, 22, 13)
        #expect(ChatTimestamp.string(reply, now: now, calendar: calendar, locale: locale) == "22:13")
    }

    @Test("earlier in the same week renders the weekday and clock")
    func sameWeek() {
        let now = date(2026, 10, 17, 22, 30)     // Saturday
        let reply = date(2026, 10, 12, 9, 5)     // Monday
        let rendered = ChatTimestamp.string(reply, now: now, calendar: calendar, locale: locale)
        #expect(rendered == "星期一 09:05")
    }

    @Test("a week or more old renders the month and day")
    func older() {
        let now = date(2026, 10, 17, 22, 30)
        let reply = date(2026, 10, 1, 7, 0)
        let rendered = ChatTimestamp.string(reply, now: now, calendar: calendar, locale: locale)
        #expect(rendered == "10月1日 07:00")
    }

    @Test("crossing a year boundary falls back to the date form")
    func acrossYear() {
        let now = date(2027, 1, 2, 10, 0)
        let reply = date(2026, 12, 31, 23, 59)
        let rendered = ChatTimestamp.string(reply, now: now, calendar: calendar, locale: locale)
        #expect(rendered == "12月31日 23:59")
    }

    @Test("completedAt wins over createdAt")
    func completedAtWins() throws {
        let completed = try #require(ChatTimestamp.parse("2026-10-17T14:13:00Z"))
        let created = try #require(ChatTimestamp.parse("2026-10-17T14:00:00Z"))
        #expect(ChatTimestamp.replyDate(completedAt: "2026-10-17T14:13:00Z",
                                        createdAt: "2026-10-17T14:00:00Z") == completed)
        #expect(ChatTimestamp.replyDate(completedAt: nil,
                                        createdAt: "2026-10-17T14:00:00Z") == created)
        #expect(ChatTimestamp.replyDate(completedAt: "2026-10-17T14:00:00Z",
                                        createdAt: "2026-10-17T14:13:00Z") == created)
    }

    @Test("an unparseable or missing value renders no clock")
    func missingValues() {
        #expect(ChatTimestamp.replyDate(completedAt: nil, createdAt: nil) == nil)
        #expect(ChatTimestamp.replyDate(completedAt: "not a date", createdAt: nil) == nil)
    }

    @Test("fractional seconds are accepted")
    func fractionalSeconds() {
        #expect(ChatTimestamp.parse("2026-10-17T14:13:00.123Z") != nil)
    }
}

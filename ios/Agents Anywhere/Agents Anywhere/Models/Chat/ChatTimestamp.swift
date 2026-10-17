import Foundation

/// Formats the reply time shown in the action row.
///
/// The reference capture showed only the same-day form (`22:10`). The weekly
/// and older forms follow the source implementation the reference was derived
/// from; they are marked as derived because no capture exercised them.
nonisolated enum ChatTimestamp {
    /// - Today: `22:13`
    /// - Same week: `星期一 22:13`
    /// - Older: `3月5日 22:13`
    static func string(_ date: Date, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> String {
        let time = formatter("HH:mm", locale: locale, calendar: calendar).string(from: date)
        if calendar.isDate(date, inSameDayAs: now) { return time }

        let elapsed = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: date),
            to: calendar.startOfDay(for: now)
        ).day ?? 0
        if elapsed < 7 {
            let weekday = formatter(weekdayTemplate(locale), locale: locale, calendar: calendar).string(from: date)
            return "\(weekday) \(time)"
        }
        let day = formatter(monthDayTemplate(locale), locale: locale, calendar: calendar).string(from: date)
        return "\(day) \(time)"
    }

    /// The reference derived its reply time from `completedAt`, falling back to
    /// `createdAt` while a turn is still running. Both are ISO 8601 strings on
    /// the wire; the domain model keeps them as strings so the storage format
    /// stays untouched.
    static func replyDate(completedAt: String?, createdAt: String?) -> Date? {
        completedAt.flatMap(parse) ?? createdAt.flatMap(parse)
    }

    static func parse(_ raw: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: raw) { return date }
        return ISO8601DateFormatter().date(from: raw)
    }

    private static func formatter(_ format: String, locale: Locale, calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.dateFormat = format
        return formatter
    }

    /// `EEEE` gives the localised full weekday name (`星期一` in zh-Hans).
    private static func weekdayTemplate(_ locale: Locale) -> String {
        DateFormatter.dateFormat(fromTemplate: "EEEE", options: 0, locale: locale) ?? "EEEE"
    }

    /// `MMMd` gives `3月5日` in zh-Hans and `Mar 5` elsewhere.
    private static func monthDayTemplate(_ locale: Locale) -> String {
        DateFormatter.dateFormat(fromTemplate: "MMMd", options: 0, locale: locale) ?? "MMM d"
    }
}

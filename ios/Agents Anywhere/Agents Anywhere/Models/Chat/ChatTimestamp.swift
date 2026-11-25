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
        let time = stamp(date, format: "HH:mm", locale: locale, calendar: calendar)
        if calendar.isDate(date, inSameDayAs: now) { return time }

        let elapsed = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: date),
            to: calendar.startOfDay(for: now)
        ).day ?? 0
        if elapsed < 7 {
            let weekday = stamp(date, format: template("EEEE", locale: locale),
                                locale: locale, calendar: calendar)
            return "\(weekday) \(time)"
        }
        let day = stamp(date, format: template("MMMd", locale: locale),
                        locale: locale, calendar: calendar)
        return "\(day) \(time)"
    }

    /// The reference derived its reply time from `completedAt`, falling back to
    /// `createdAt` while a turn is still running. Both are ISO 8601 strings on
    /// the wire; the domain model keeps them as strings so the storage format
    /// stays untouched.
    static func replyDate(completedAt: String?, createdAt: String?) -> Date? {
        completedAt.flatMap(parse) ?? createdAt.flatMap(parse)
    }

    /// Shared parsers, not a fresh `ISO8601DateFormatter` per call: building
    /// one costs far more than parsing with it, and the outline builder parses
    /// a timestamp for every message each time it rebuilds its rows
    /// (`outline.reload` measured 69–86 ms over ~264 parts, pp 2026-11-21).
    /// Formatters are mutable classes, so the shared instances are only ever
    /// touched under the lock.
    private static let parseLock = NSLock()
    private static let fractionalParser: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let plainParser = ISO8601DateFormatter()

    static func parse(_ raw: String) -> Date? {
        // An absent timestamp reaches this as "" (several wire rows carry no
        // createdAt); no formatter can parse it and the old code paid two
        // allocations to find that out.
        guard !raw.isEmpty else { return nil }
        parseLock.lock()
        defer { parseLock.unlock() }
        if let date = fractionalParser.date(from: raw) { return date }
        return plainParser.date(from: raw)
    }

    /// The action row formats one of these per materialized row. Building a
    /// `DateFormatter` costs far more than formatting with it, and a fresh one
    /// per call was left in place when the outline path was fixed
    /// (`ConversationOutlineRowContent`, 2026-11-21); the device probe caught
    /// this sibling call site at 16 ms in a single call during a pure scroll
    /// (2026-11-25). Formatters are mutable classes, so the cache is only ever
    /// touched under the lock — including the format call itself.
    private static let stampLock = NSLock()
    private nonisolated(unsafe) static var stampFormatters: [String: DateFormatter] = [:]

    /// Localised patterns are derived once per locale for the same reason
    /// (`dateFormat(fromTemplate:)` builds a formatter inside Foundation).
    private nonisolated(unsafe) static var stampTemplates: [String: String] = [:]

    private static func stamp(_ date: Date, format: String,
                              locale: Locale, calendar: Calendar) -> String {
        let key = "\(format)|\(locale.identifier)|\(calendar.identifier)|\(calendar.timeZone.identifier)"
        stampLock.lock()
        defer { stampLock.unlock() }
        if let formatter = stampFormatters[key] { return formatter.string(from: date) }
        // A reader that keeps switching locale or zone must not grow the table
        // without bound; one device holds a handful of live styles at once.
        if stampFormatters.count >= 16 { stampFormatters.removeAll() }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        // The reply date is rendered in the reader's own zone. Assigning the
        // calendar also assigns its zone, but `DateFormatter` otherwise falls
        // back to the process default, so it is set explicitly.
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = format
        stampFormatters[key] = formatter
        return formatter.string(from: date)
    }

    /// `EEEE` gives the localised full weekday name (`星期一` in zh-Hans);
    /// `MMMd` gives `3月5日` there and `Mar 5` elsewhere.
    private static func template(_ raw: String, locale: Locale) -> String {
        let key = "\(raw)|\(locale.identifier)"
        stampLock.lock()
        defer { stampLock.unlock() }
        if let cached = stampTemplates[key] { return cached }
        if stampTemplates.count >= 16 { stampTemplates.removeAll() }
        let pattern = DateFormatter.dateFormat(
            fromTemplate: raw, options: 0, locale: locale) ?? raw
        stampTemplates[key] = pattern
        return pattern
    }
}

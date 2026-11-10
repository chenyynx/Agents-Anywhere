import Foundation
import Testing
@testable import ClientCore

private final class DiagnosticsClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) { self.value = value }

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ date: Date) {
        lock.lock()
        value = date
        lock.unlock()
    }
}

private func diagnosticsDefaults(enabled: Bool) -> UserDefaults {
    let suite = "ClientDiagnosticsLogTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    defaults.set(enabled, forKey: ClientDiagnosticsLog.enabledKey)
    return defaults
}

private func diagnosticsDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("aa-diagnostics-\(UUID().uuidString)", isDirectory: true)
}

private func utcCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}

@Suite @MainActor struct ClientDiagnosticsLogTests {
    @Test func disabledLoggerWritesNothing() {
        let log = ClientDiagnosticsLog(
            directory: diagnosticsDirectory(),
            defaults: diagnosticsDefaults(enabled: false),
            calendar: utcCalendar()
        )
        log.record(kind: "timeline.order.duplicate", sessionID: "s")
        #expect(log.days().isEmpty)
    }

    @Test func rotatesToTheLastSevenDays() {
        let calendar = utcCalendar()
        let start = calendar.date(
            from: DateComponents(year: 2026, month: 1, day: 1)
        )!
        let clock = DiagnosticsClock(start)
        let log = ClientDiagnosticsLog(
            directory: diagnosticsDirectory(),
            defaults: diagnosticsDefaults(enabled: true),
            now: { clock.now },
            calendar: calendar
        )
        for offset in 0..<8 {
            clock.set(calendar.date(byAdding: .day, value: offset, to: start)!)
            log.record(
                kind: "timeline.order.duplicate",
                sessionID: "s",
                detail: ["orderSeq": String(offset)]
            )
        }
        let days = log.days()
        #expect(days.count == 7)
        let newest = calendar.startOfDay(
            for: calendar.date(byAdding: .day, value: 7, to: start)!
        )
        let oldest = calendar.startOfDay(
            for: calendar.date(byAdding: .day, value: 1, to: start)!
        )
        #expect(days.first?.date == newest)
        #expect(days.last?.date == oldest)
        #expect(!days.contains { $0.date == calendar.startOfDay(for: start) })
    }

    @Test func repeatsInsideTheWindowAreCollapsed() throws {
        let calendar = utcCalendar()
        let now = calendar.date(
            from: DateComponents(year: 2026, month: 1, day: 1, hour: 12)
        )!
        let log = ClientDiagnosticsLog(
            directory: diagnosticsDirectory(),
            defaults: diagnosticsDefaults(enabled: true),
            now: { now },
            calendar: calendar
        )
        for _ in 0..<100 {
            log.record(
                kind: "timeline.order.duplicate",
                sessionID: "s",
                detail: ["orderSeq": "7"]
            )
        }
        let day = try #require(log.days().first)
        #expect(log.entries(for: day).count == 1)
    }

    @Test func previewAndExportKeepTheEntries() throws {
        let calendar = utcCalendar()
        let start = calendar.date(
            from: DateComponents(year: 2026, month: 1, day: 1, hour: 10)
        )!
        let clock = DiagnosticsClock(start)
        let log = ClientDiagnosticsLog(
            directory: diagnosticsDirectory(),
            defaults: diagnosticsDefaults(enabled: true),
            now: { clock.now },
            calendar: calendar
        )
        log.record(kind: "timeline.order.duplicate", sessionID: "a")
        clock.set(calendar.date(byAdding: .day, value: 1, to: start)!)
        log.record(kind: "timeline.user_message.unrendered", sessionID: "b")

        #expect(log.days().count == 2)
        let firstDay = try #require(
            log.days().first(where: { $0.date == calendar.startOfDay(for: start) })
        )
        let entries = log.entries(for: firstDay)
        #expect(entries.count == 1)
        #expect(entries.first?.kind == "timeline.order.duplicate")
        #expect(log.rawText(for: firstDay).contains("timeline.order.duplicate"))

        let export = try #require(log.exportFile())
        let text = try String(contentsOf: export, encoding: .utf8)
        #expect(text.contains("# diagnostics"))
        #expect(text.contains("timeline.order.duplicate"))
        #expect(text.contains("timeline.user_message.unrendered"))
    }

    @Test func actionsDoNotRaiseTheAnomalyFlag() throws {
        let log = ClientDiagnosticsLog(
            directory: diagnosticsDirectory(),
            defaults: diagnosticsDefaults(enabled: true),
            calendar: utcCalendar()
        )
        log.record(
            kind: "session.open",
            sessionID: "s",
            detail: ["cached": "0"],
            dedupe: false
        )
        #expect(log.days().first?.hasEntries == false)
        log.record(
            kind: "timeline.order.duplicate",
            sessionID: "s",
            detail: ["orderSeq": "7"]
        )
        #expect(log.days().first?.hasEntries == true)
    }

    @Test func dailyFilesUseTheAppName() throws {
        let log = ClientDiagnosticsLog(
            directory: diagnosticsDirectory(),
            defaults: diagnosticsDefaults(enabled: true),
            calendar: utcCalendar()
        )
        log.record(kind: "session.open", sessionID: "s", dedupe: false)
        let day = try #require(log.days().first)
        #expect(day.fileURL.lastPathComponent.hasPrefix("Anywhere-"))
        #expect(day.fileURL.pathExtension == "log")
    }

    @Test func recognizesLegacyJSONLFiles() throws {
        let base = diagnosticsDirectory()
        let directory = base.appendingPathComponent(
            "ClientDiagnostics", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        try Data().write(
            to: directory.appendingPathComponent("diagnostics-2026-01-01.jsonl"))
        let calendar = utcCalendar()
        let now = calendar.date(
            from: DateComponents(year: 2026, month: 1, day: 1, hour: 12)
        )!
        let log = ClientDiagnosticsLog(
            directory: base,
            defaults: diagnosticsDefaults(enabled: true),
            now: { now },
            calendar: calendar
        )
        #expect(log.days().first?.fileURL.lastPathComponent
            == "diagnostics-2026-01-01.jsonl")
    }

    @Test func deleteRemovesOnlyTheChosenDay() throws {
        let calendar = utcCalendar()
        let start = calendar.date(
            from: DateComponents(year: 2026, month: 1, day: 1, hour: 10)
        )!
        let clock = DiagnosticsClock(start)
        let log = ClientDiagnosticsLog(
            directory: diagnosticsDirectory(),
            defaults: diagnosticsDefaults(enabled: true),
            now: { clock.now },
            calendar: calendar
        )
        log.record(kind: "timeline.order.duplicate", sessionID: "a")
        clock.set(calendar.date(byAdding: .day, value: 1, to: start)!)
        log.record(kind: "timeline.order.duplicate", sessionID: "b")

        let older = try #require(log.days().last)
        log.delete(older)

        let remaining = log.days()
        #expect(remaining.count == 1)
        #expect(remaining.first?.date == calendar.startOfDay(for: clock.now))
        #expect(!FileManager.default.fileExists(atPath: older.fileURL.path))
    }

    @Test func clearRemovesEveryDay() {
        let log = ClientDiagnosticsLog(
            directory: diagnosticsDirectory(),
            defaults: diagnosticsDefaults(enabled: true),
            calendar: utcCalendar()
        )
        log.record(kind: "timeline.order.duplicate", sessionID: "s")
        #expect(!log.days().isEmpty)
        log.clear()
        #expect(log.days().isEmpty)
    }
}

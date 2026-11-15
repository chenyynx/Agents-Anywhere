import Foundation
import Synchronization
import Testing
@testable import ClientCore

/// The diagnostics logger's two levels and its time-window export (pp
/// 2026-11-15: a verbose day must stay shareable). The export folds per-frame
/// `timeline.mover` scroll samples, keeps every state change, and opens with a
/// window/build header.
@Suite struct DiagnosticsLogTests {
    private func makeLog(_ clock: WindowExportClock) -> (ClientDiagnosticsLog, UserDefaults, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("diagnostics-test-\(UUID().uuidString)")
        let defaults = UserDefaults(suiteName: "diagnostics-test-\(UUID().uuidString)")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let log = ClientDiagnosticsLog(
            directory: directory,
            defaults: defaults,
            now: { clock.now },
            calendar: calendar)
        return (log, defaults, directory)
    }

    private func scroll(_ log: ClientDiagnosticsLog, placement: String, contentH: String,
                        position: String) {
        log.record(kind: "timeline.mover",
                   sessionID: "s1",
                   detail: ["action": "scroll", "placement": placement,
                            "contentH": contentH, "position": position,
                            "previous": position],
                   dedupe: false,
                   verbose: true)
    }

    @Test func verboseEntriesStayOutUntilTheReaderTurnsThemOn() {
        let clock = WindowExportClock(Date(timeIntervalSince1970: 1_760_000_000))
        let (log, defaults, _) = makeLog(clock)
        scroll(log, placement: "end", contentH: "100", position: "1")
        log.record(kind: "session.open", detail: ["rows": "3"], dedupe: false)
        var entries = log.days().flatMap { log.entries(for: $0) }
        #expect(entries.contains { $0.kind == "session.open" })
        #expect(!entries.contains { $0.kind == "timeline.mover" })

        defaults.set(true, forKey: ClientDiagnosticsLog.verboseKey)
        scroll(log, placement: "end", contentH: "100", position: "2")
        entries = log.days().flatMap { log.entries(for: $0) }
        #expect(entries.contains { $0.kind == "timeline.mover" })
    }

    @Test func aWindowExportKeepsOnlyLinesInsideIt() throws {
        let clock = WindowExportClock(Date(timeIntervalSince1970: 1_760_000_000))
        let (log, _, _) = makeLog(clock)
        log.record(kind: "session.open", detail: ["marker": "before"], dedupe: false)
        clock.advance(600)
        log.record(kind: "session.open", detail: ["marker": "after"], dedupe: false)

        let since = clock.now.addingTimeInterval(-60)
        let url = try #require(log.exportWindow(since: since))
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.hasPrefix("# window:"))
        #expect(text.contains("\"marker\":\"after\""))
        #expect(!text.contains("\"marker\":\"before\""))
    }

    @Test func aWindowExportFoldsPerFrameScrollSamples() throws {
        let clock = WindowExportClock(Date(timeIntervalSince1970: 1_760_000_000))
        let (log, defaults, _) = makeLog(clock)
        defaults.set(true, forKey: ClientDiagnosticsLog.verboseKey)
        for index in 0..<6 {
            clock.advance(0.02)
            scroll(log, placement: "end", contentH: "100", position: "\(index)")
        }
        log.record(kind: "timeline.mover",
                   sessionID: "s1",
                   detail: ["action": "inset", "insetBefore": "60", "insetAfter": "94"],
                   dedupe: false)

        let url = try #require(log.exportWindow(since: nil))
        let text = try String(contentsOf: url, encoding: .utf8)
        let lines = text.split(separator: "\n")
        #expect(lines.first?.hasPrefix("# window:") == true)
        // header + first sample + folded line + the inset = 4, not 8.
        #expect(lines.count == 4)
        #expect(text.contains("\"collapsed\":\"5\""))
        #expect(text.contains("\"action\":\"inset\""))
    }

    /// The menu's count is one shared pass over the files; it must keep
    /// matching the file the export actually writes, folding included.
    @Test func theReportedSizeMatchesTheExportedFile() throws {
        let clock = WindowExportClock(Date(timeIntervalSince1970: 1_760_000_000))
        let (log, defaults, _) = makeLog(clock)
        defaults.set(true, forKey: ClientDiagnosticsLog.verboseKey)
        log.record(kind: "session.open", detail: ["rows": "3"], dedupe: false)
        for index in 0..<6 {
            clock.advance(0.02)
            scroll(log, placement: "end", contentH: "100", position: "\(index)")
        }
        let size = log.exportWindowSize(since: nil)
        let url = try #require(log.exportWindow(since: nil))
        let bytes = try Data(contentsOf: url).count
        #expect(size == Int64(bytes))
    }

    @Test func anEmptyWindowExportsNothing() {
        let clock = WindowExportClock(Date(timeIntervalSince1970: 1_760_000_000))
        let (log, _, _) = makeLog(clock)
        #expect(log.exportWindow(since: nil) == nil)
        #expect(log.exportWindowSize(since: nil) == 0)
    }
}

/// A movable clock for the logger's injectable `now`.
nonisolated private final class WindowExportClock: Sendable {
    private let value: Mutex<Date>
    init(_ start: Date) { value = Mutex(start) }
    var now: Date { value.withLock { $0 } }
    func advance(_ seconds: TimeInterval) { value.withLock { $0 += seconds } }
}

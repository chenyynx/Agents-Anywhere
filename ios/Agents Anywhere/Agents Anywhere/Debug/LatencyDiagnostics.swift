import Foundation

/// Opt-in latency tracing for the send / stop / reply timelines.
///
/// Design rules (pp 2026-10-11):
/// - **Off by default; zero behavior when off.** Recording is gated by a
///   persistent toggle (`aa.diagnostics.enabled`, flipped from
///   Settings → 诊断) OR the `AA_DIAG=1` environment override for simulator runs.
///   The toggle — not a compile flag — is the gate because the on-device IPA the
///   tester installs is a **Release** build, where `#if DEBUG` is stripped and
///   the environment cannot be set. Reading the toggle at each write means it
///   takes effect with no relaunch.
/// - **One JSON line per event**, appended to
///   `Documents/aa-diagnostics/aa-diagnostics-<launch>.jsonl`. This file is the
///   "diagnostics package": share it back and the whole timeline can be
///   reconstructed second by second.
/// - **Wall clock + monotonic.** Each event carries both `at` (ISO-8601 wall
///   time, for cross-referencing nginx / server logs) and `t` (ms since process
///   launch, for measuring intervals without clock-skew noise).
/// - **No message content** is ever recorded — only event names, session ids and
///   durations — so a shared package leaks nothing.
///
/// Names are pinned in `.local-dev/latency-diagnostics-tasks.md`; callers pass a
/// `LatencyDiagnostics.Name` constant so the timeline stays greppable.
@MainActor
final class LatencyDiagnostics {

    /// The event vocabulary. Kept as constants so a typo cannot silently fork the
    /// timeline into two spellings of the same moment.
    enum Name {
        static let sendTap = "send_tap"
        static let sendEnqueued = "send_enqueued"
        static let sendHTTPStart = "send_http_start"
        static let sendHTTPEnd = "send_http_end"
        static let sendFail = "send_http_fail"
        static let sendReturn = "send_return"
        static let interruptTap = "interrupt_tap"
        static let interruptHTTPStart = "interrupt_http_start"
        static let interruptHTTPEnd = "interrupt_http_end"
        static let interruptPredicted = "interrupt_predicted"
        static let turnFrameFirst = "turn_first_frame"
        static let turnTextFirst = "turn_first_text"
        static let turnEnd = "turn_end"
    }

    /// The persistent toggle key, shared with `DiagnosticsSettingsView`.
    static let enabledKey = "aa.diagnostics.enabled"

    static let shared = LatencyDiagnostics()

    /// Whether the tracer is on. Static so non-record call sites can cheaply skip
    /// work (e.g. building an event payload) without touching the singleton.
    @MainActor static var isEnabled: Bool { shared.enabled }

    /// The env override is read once (it cannot change mid-launch); the toggle is
    /// read live so flipping it in Settings takes effect immediately.
    private let envOverride: Bool
    private let startUptime: Double
    private let iso = ISO8601DateFormatter()
    private var fileURL: URL?

    private(set) var count: Int = 0

    /// True when recording is currently on.
    var enabled: Bool {
        envOverride || UserDefaults.standard.bool(forKey: Self.enabledKey)
    }
    /// The file the "diagnostics package" export shares, created lazily on the
    /// first write after enabling.
    var exportURL: URL? { fileURL ?? existingFile() }

    private init() {
        envOverride = ProcessInfo.processInfo.environment["AA_DIAG"] == "1"
        startUptime = ProcessInfo.processInfo.systemUptime
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        fileURL = existingFile()
    }

    /// Record one event. Cheap no-op when off.
    @MainActor static func mark(_ name: String, session: String? = nil, detail: String? = nil) {
        shared.record(name, session: session, detail: detail)
    }

    /// A monotonic millisecond clock for measuring a span around an async hop.
    /// Returns a value only when enabled, so callers can skip work entirely.
    @MainActor static func now() -> Double? {
        shared.enabled ? ProcessInfo.processInfo.systemUptime * 1000 : nil
    }

    /// Record `name` with the milliseconds elapsed since `started` (as returned
    /// by `now()`). No-op when either side is absent.
    @MainActor static func markElapsed(_ name: String, since started: Double?, session: String? = nil, detail: String? = nil) {
        guard let started, shared.enabled else { return }
        let ms = ProcessInfo.processInfo.systemUptime * 1000 - started
        let extra = detail.map { "\($0) ms=\(Int(ms))" } ?? "ms=\(Int(ms))"
        shared.record(name, session: session, detail: extra)
    }

    func record(_ name: String, session: String?, detail: String?) {
        guard enabled else { return }
        count += 1
        let elapsedMs = (ProcessInfo.processInfo.systemUptime - startUptime) * 1000
        var line = #"{"at":"\#(iso.string(from: Date()))","t":\#(Int(elapsedMs)),"name":"\#(name)""#
        if let session { line += #","session":"\#(session)""# }
        if let detail { line += #","detail":"\#(escape(detail))""# }
        line += "}\n"
        append(line)
    }

    /// Deletes the recorded file(s) and zeroes the count.
    func clear() {
        if let dir = Self.directory() {
            let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            for file in files { try? FileManager.default.removeItem(at: file) }
        }
        fileURL = nil
        count = 0
    }

    // MARK: - Private

    private func append(_ line: String) {
        let url = fileURL ?? createFile()
        fileURL = url
        guard let url, let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        }
    }

    private func createFile() -> URL? {
        guard let dir = Self.directory() else { return nil }
        let url = dir.appendingPathComponent("aa-diagnostics-\(Int(Date().timeIntervalSince1970)).jsonl")
        _ = FileManager.default.createFile(atPath: url.path, contents: nil)
        return url
    }

    /// The most recent existing file for this app's diagnostics (used on launch
    /// so an export before the first write still has something to share).
    private func existingFile() -> URL? {
        guard let dir = Self.directory() else { return nil }
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files
            .filter { $0.pathExtension == "jsonl" }
            .max { ($0.modificationDate ?? .distantPast) < ($1.modificationDate ?? .distantPast) }
    }

    private func escape(_ value: String) -> String {
        var out = ""
        for ch in value.unicodeScalars {
            switch ch {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if ch.value < 0x20 { out += String(format: "\\u%04x", ch.value) } else { out.unicodeScalars.append(ch) }
            }
        }
        return out
    }

    private static func directory() -> URL? {
        guard let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        let dir = base.appendingPathComponent("aa-diagnostics", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }
}

private extension URL {
    var modificationDate: Date? {
        (try? resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}

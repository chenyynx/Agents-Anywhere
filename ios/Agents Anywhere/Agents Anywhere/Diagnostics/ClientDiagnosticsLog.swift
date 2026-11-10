import Foundation

/// One recorded client-side anomaly. Only ids, sequence numbers and counts are
/// stored; message content and attachments never enter this log.
nonisolated struct DiagnosticsEntry: Sendable, Identifiable, Equatable {
    let id: String
    let timestamp: Date
    let kind: String
    let severity: String
    let sessionID: String?
    let detail: [String: String]
}

/// One retained daily log file.
nonisolated struct DiagnosticsDay: Sendable, Identifiable, Equatable {
    let date: Date
    let fileURL: URL
    let hasEntries: Bool
    let size: Int64

    var id: String { fileURL.lastPathComponent }
}

/// Daily, opt-in client diagnostics with a seven-day rotation.
///
/// A disabled logger does no work: `record` returns before touching the disk.
/// Enabled, one JSON object per line is appended to
/// `diagnostics-YYYY-MM-DD.jsonl` under Application Support. Writes are
/// serialized on a private queue; reads take the same queue, so a preview or
/// export always sees the writes that happened before it.
///
/// The log is diagnostic, not telemetry: it never leaves the device unless the
/// reader exports it, and it never contains message bodies.
nonisolated final class ClientDiagnosticsLog: @unchecked Sendable {
    static let shared = ClientDiagnosticsLog()

    static let enabledKey = "diagnostics.log.enabled"
    static let serverKey = "diagnostics.log.server"
    static let retainedDays = 7
    static let maxBytesPerDay = 5 * 1024 * 1024
    /// The same anomaly in the same session is written once per window.
    static let repeatWindow: TimeInterval = 10 * 60
    static let fileNamePrefix = "diagnostics-"

    private let directory: URL
    private let defaults: UserDefaults
    private let now: @Sendable () -> Date
    private let calendar: Calendar
    private let queue = DispatchQueue(label: "com.agentsanywhere.client-diagnostics")
    private var seen: [String: (at: Date, count: Int)] = [:]
    private var cappedDays: Set<String> = []

    init(
        directory: URL? = nil,
        defaults: UserDefaults = .standard,
        now: @escaping @Sendable () -> Date = { Date() },
        calendar: Calendar = .current
    ) {
        let base = directory
            ?? FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first
            ?? FileManager.default.temporaryDirectory
        self.directory = base.appendingPathComponent(
            "ClientDiagnostics", isDirectory: true
        )
        self.defaults = defaults
        self.now = now
        self.calendar = calendar
    }

    var isEnabled: Bool {
        defaults.bool(forKey: Self.enabledKey)
    }

    /// The server shown in a day's header. The app sets it once the configured
    /// server is known; it is diagnostic metadata, not a credential.
    func setServer(_ description: String?) {
        if let description, !description.isEmpty {
            defaults.set(description, forKey: Self.serverKey)
        } else {
            defaults.removeObject(forKey: Self.serverKey)
        }
    }

    /// Called when the reader turns the toggle on, so today's file exists even
    /// before the first anomaly.
    func markEnabled() {
        guard isEnabled else { return }
        let stamp = now()
        queue.async { [weak self] in
            self?.ensureDayHeader(at: stamp)
        }
    }

    /// Record one anomaly. Non-blocking: the caller never waits for the disk.
    func record(
        kind: String,
        sessionID: String? = nil,
        detail: [String: String] = [:],
        severity: String = "warn"
    ) {
        guard isEnabled else { return }
        let stamp = now()
        let fingerprint = Self.fingerprint(
            kind: kind, sessionID: sessionID, detail: detail
        )
        queue.async { [weak self] in
            guard let self else { return }
            if let last = self.seen[fingerprint],
               stamp.timeIntervalSince(last.at) < Self.repeatWindow {
                self.seen[fingerprint] = (last.at, last.count + 1)
                return
            }
            var merged = detail
            if let last = self.seen[fingerprint], last.count > 0 {
                merged["repeats"] = String(last.count)
            }
            self.seen[fingerprint] = (stamp, 0)
            if self.seen.count > 512 {
                self.seen.removeAll(keepingCapacity: true)
            }
            self.append(
                kind: kind, sessionID: sessionID, detail: merged,
                severity: severity, at: stamp
            )
        }
    }

    // MARK: - Reading

    /// The retained days, newest first. Blocks until pending writes finish.
    func days() -> [DiagnosticsDay] {
        queue.sync { daysLocked() }
    }

    func hasRecentEntries() -> Bool {
        days().contains { $0.hasEntries }
    }

    /// The day's file exactly as stored, one JSON object per line. The day
    /// view shows this verbatim so a reader can copy or share the file rather
    /// than a re-rendered summary.
    func rawText(for day: DiagnosticsDay) -> String {
        queue.sync {
            guard let data = try? Data(contentsOf: day.fileURL) else {
                return ""
            }
            return String(data: data, encoding: .utf8) ?? ""
        }
    }

    func entries(for day: DiagnosticsDay) -> [DiagnosticsEntry] {
        queue.sync {
            guard let data = try? Data(contentsOf: day.fileURL),
                  let text = String(data: data, encoding: .utf8) else {
                return []
            }
            return text
                .split(separator: "\n", omittingEmptySubsequences: true)
                .compactMap { Self.decodeEntry(String($0)) }
                .sorted { $0.timestamp < $1.timestamp }
        }
    }

    /// Concatenate the retained days into one file for the share sheet.
    func exportFile() -> URL? {
        queue.sync {
            let retained = daysLocked()
            guard !retained.isEmpty else { return nil }
            var output = ""
            for day in retained.sorted(by: { $0.date < $1.date }) {
                output += "# diagnostics \(Self.dayString(day.date, calendar: calendar))\n"
                if let data = try? Data(contentsOf: day.fileURL),
                   let text = String(data: data, encoding: .utf8) {
                    output += text
                    if !output.hasSuffix("\n") { output += "\n" }
                }
            }
            let stamp = Self.exportString(now(), calendar: calendar)
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("aa-diagnostics-\(stamp).jsonl")
            do {
                try Data(output.utf8).write(to: url, options: .atomic)
                return url
            } catch {
                return nil
            }
        }
    }

    func clear() {
        queue.sync {
            for day in daysLocked() {
                try? FileManager.default.removeItem(at: day.fileURL)
            }
            cappedDays.removeAll()
            seen.removeAll()
        }
    }

    // MARK: - Writing

    private func append(
        kind: String,
        sessionID: String?,
        detail: [String: String],
        severity: String,
        at stamp: Date
    ) {
        let day = calendar.startOfDay(for: stamp)
        ensureDayHeader(at: stamp)
        let url = fileURL(for: day)
        let size = fileSize(url)
        if size >= Self.maxBytesPerDay {
            let key = Self.dayString(day, calendar: calendar)
            if cappedDays.insert(key).inserted {
                write(
                    kind: "log.capped", sessionID: nil,
                    detail: ["bytes": String(size)],
                    severity: "info", at: stamp, to: url
                )
            }
            return
        }
        write(
            kind: kind, sessionID: sessionID, detail: detail,
            severity: severity, at: stamp, to: url
        )
        prune(retaining: day)
    }

    private func ensureDayHeader(at stamp: Date) {
        let day = calendar.startOfDay(for: stamp)
        let url = fileURL(for: day)
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        var detail: [String: String] = [
            "build": Bundle.main.object(
                forInfoDictionaryKey: "CFBundleVersion"
            ) as? String ?? "?",
            "version": Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String ?? "?",
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "device": Self.deviceDescription,
        ]
        if let server = defaults.string(forKey: Self.serverKey), !server.isEmpty {
            detail["server"] = server
        } else if let raw = defaults.string(
            forKey: "agentsAnywhere.serverURL"
        ), let url = URL(string: raw), let host = url.host {
            detail["server"] = host
        }
        write(
            kind: "day.started", sessionID: nil, detail: detail,
            severity: "info", at: stamp, to: url
        )
    }

    private func write(
        kind: String,
        sessionID: String?,
        detail: [String: String],
        severity: String,
        at stamp: Date,
        to url: URL
    ) {
        var object: [String: Any] = [
            "ts": Self.isoString(stamp, calendar: calendar),
            "kind": kind,
            "severity": severity,
            "detail": detail,
        ]
        if let sessionID, !sessionID.isEmpty { object["session"] = sessionID }
        guard let data = try? JSONSerialization.data(
            withJSONObject: object, options: [.sortedKeys]
        ) else { return }
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        excludeFromBackup(directory)
        let line = data + Data("\n".utf8)
        if !FileManager.default.fileExists(atPath: url.path) {
            try? line.write(to: url, options: .atomic)
            return
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: line)
    }

    private func daysLocked() -> [DiagnosticsDay] {
        prune(retaining: calendar.startOfDay(for: now()))
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let days: [DiagnosticsDay] = urls.compactMap { url in
            guard let date = Self.date(fromFileName: url.lastPathComponent,
                                       calendar: calendar) else { return nil }
            let size = Int64(
                (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            )
            return DiagnosticsDay(
                date: date,
                fileURL: url,
                hasEntries: fileHasEntries(url),
                size: size
            )
        }
        return Array(days.sorted { $0.date > $1.date }.prefix(Self.retainedDays))
    }

    private func fileHasEntries(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else {
            return false
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let object = Self.jsonObject(String(line)) else { continue }
            if (object["kind"] as? String) != "day.started" { return true }
        }
        return false
    }

    private func prune(retaining day: Date) {
        guard let cutoff = calendar.date(
            byAdding: .day, value: -(Self.retainedDays - 1), to: day
        ) else { return }
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        for url in urls {
            guard let date = Self.date(fromFileName: url.lastPathComponent,
                                       calendar: calendar),
                  date < cutoff else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Helpers

    private func fileURL(for day: Date) -> URL {
        directory.appendingPathComponent(
            "\(Self.fileNamePrefix)\(Self.dayString(day, calendar: calendar)).jsonl"
        )
    }

    private func fileSize(_ url: URL) -> Int64 {
        Int64(
            (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]
                as? NSNumber)?.int64Value ?? 0
        )
    }

    private func excludeFromBackup(_ url: URL) {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutable = url
        try? mutable.setResourceValues(values)
    }

    private static func fingerprint(
        kind: String, sessionID: String?, detail: [String: String]
    ) -> String {
        let body = detail.keys.sorted()
            .map { "\($0)=\(detail[$0] ?? "")" }
            .joined(separator: "&")
        return "\(kind)|\(sessionID ?? "")|\(body)"
    }

    private static func decodeEntry(_ line: String) -> DiagnosticsEntry? {
        guard let object = jsonObject(line),
              let kind = object["kind"] as? String,
              kind != "day.started" else { return nil }
        let detail = (object["detail"] as? [String: Any] ?? [:]).mapValues {
            String(describing: $0)
        }
        return DiagnosticsEntry(
            id: UUID().uuidString,
            timestamp: isoDate(object["ts"] as? String) ?? Date.distantPast,
            kind: kind,
            severity: object["severity"] as? String ?? "warn",
            sessionID: object["session"] as? String,
            detail: detail
        )
    }

    private static func jsonObject(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any] else { return nil }
        return object
    }

    private static func date(fromFileName name: String,
                             calendar: Calendar) -> Date? {
        guard name.hasPrefix(fileNamePrefix), name.hasSuffix(".jsonl") else {
            return nil
        }
        let start = name.index(name.startIndex, offsetBy: fileNamePrefix.count)
        let end = name.index(name.endIndex, offsetBy: -".jsonl".count)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: String(name[start..<end])) else {
            return nil
        }
        return calendar.startOfDay(for: date)
    }

    private static func dayString(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func exportString(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    private static func isoString(_ date: Date, calendar: Calendar) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = calendar.timeZone
        return formatter.string(from: date)
    }

    private static func isoDate(_ string: String?) -> Date? {
        guard let string else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }

    private static var deviceDescription: String {
        #if os(iOS)
        return "iOS " + ProcessInfo.processInfo.operatingSystemVersionString
        #else
        return ProcessInfo.processInfo.operatingSystemVersionString
        #endif
    }
}

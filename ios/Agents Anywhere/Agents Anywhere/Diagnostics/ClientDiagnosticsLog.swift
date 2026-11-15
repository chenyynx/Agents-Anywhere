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

/// Daily client diagnostics with a seven-day rotation, recording by default
/// (pp 2026-11-13).
///
/// A disabled logger does no work: `record` returns before touching the disk.
/// Enabled, one JSON object per line is appended to
/// `Anywhere-YYYY-MM-DD.log` (one JSON object per line) under Application
/// Support. Legacy `diagnostics-*` files from the first builds stay readable.
/// Writes are
/// serialized on a private queue; reads take the same queue, so a preview or
/// export always sees the writes that happened before it.
///
/// The log is diagnostic, not telemetry: it never leaves the device unless the
/// reader exports it, and it never contains message bodies.
nonisolated final class ClientDiagnosticsLog: @unchecked Sendable {
    static let shared = ClientDiagnosticsLog()

    static let enabledKey = "diagnostics.log.enabled"
    /// The second, independent level: per-frame samples, per-row updates and
    /// per-refresh gate decisions that are too noisy to keep on by default.
    /// Standard (off) records state changes only; verbose (on) adds the
    /// detail used to explain "this row did not redraw" and "the page moved
    /// on its own". Export by time window keeps a verbose day shareable.
    static let verboseKey = "diagnostics.log.verbose"
    static let serverKey = "diagnostics.log.server"
    static let retainedDays = 7
    static let maxBytesPerDay = 5 * 1024 * 1024
    /// The same anomaly in the same session is written once per window.
    static let repeatWindow: TimeInterval = 10 * 60
    static let fileNamePrefix = "Anywhere-"
    static let fileExtension = "log"
    /// The first builds wrote `diagnostics-*.jsonl`; keep listing and rotating
    /// those so an upgrade never hides a day the reader already has.
    static let legacyFileNamePrefixes = ["diagnostics-"]
    static let recognizedPrefixes = [fileNamePrefix] + legacyFileNamePrefixes
    static let recognizedExtensions = ["log", "jsonl"]
    static let schemaVersion = "1"

    /// Written as the second line of every daily file. It lets a fresh reader
    /// reconstruct the file without this codebase: stable kind names and the
    /// meaning of every detail key used by the action trail and the checks.
    static let schemaLegend: [String: String] = [
        "schemaVersion": schemaVersion,
        "about": "Client diagnostics, one JSON object per line. Session ids and row ids only; no message content.",
        "kinds": "app.launch|app.foreground|app.background; diagnostics.enabled|diagnostics.disabled|diagnostics.verbose|diagnostics.export; cache.clear; ui.screen; session.open|session.open.ready|session.refresh; timeline.snapshot.fetch|timeline.snapshot.applied|timeline.latest.fetch|timeline.grouping; timeline.row.inserted|timeline.row.moved; timeline.recovery; timeline.step.pose_after_stop|timeline.tool.after_stop|timeline.queue.handoff|timeline.interrupt.card|timeline.anchor.placement|timeline.mover|timeline.working.row|timeline.compact.row|timeline.footer.gate|timeline.apply|timeline.row.update|timeline.height.delta|timeline.haptic; ws.connect|ws.disconnect; timeline.event.gap; timeline.order.duplicate|timeline.order.nonpositive; timeline.user_message.unrendered; timeline.decode.dropped",
        "fields": "ts=local ISO8601; kind; severity=info for actions and the gap note / warn for anomalies (derived from kind); session=session id; detail=string map. after/next=event cursor; rows=held row count; minOrder/maxOrder=window bounds; firstId/lastId=window edges; nextSeq=server high watermark; trigger=open|refresh|reconnect|recovery|rebuild|reconcile|fill|live|batch|history; limit=requested page size; status/bytes/deferred on fetches; eventTypes/eventIds on recovery; units/stepGroups/messageUnits/userRows/userUnrendered on grouping; ids/orderSeq/count for anomalies; prevId/nextId=nearest held neighbours, prevOrder/nextOrder=their orderSeq, rowsBefore=held rows before the merge, windowMin/windowMax=window bounds before the merge; oldOrder/newOrder=a held row's orderSeq change; group=step-group id; liveTail/allowsPose/fresh/stopRequested/predictedIdle=0/1 pose gates; status=runtime status; steps=step count; item=row id, from/to=status before/after, revival=1 when to=running, revision/updatedSeq=row version; from/to=send-queue roster before/after a change; head=head id:state; offsetY/contentH/visibleH/atBottom=viewport numbers at the change; running/streaming/placeholder/statusLine=drawn working gates; liveTail=the group drawing the live tail; posing=groups the pose gate would animate, posingRunning=their running subset; state/title=the compact row's wire state and the divider label it draws; open/suppress/running/compacting/hasActive=footer gate inputs; items/changed/reconfigured=apply sizes; estimate/measured=height correction; name/action=page breadcrumb; window/bytes/n=an export request; collapsed=folded timeline.mover scroll samples.",
    ]

    /// Kinds recorded at info level: reader actions plus the cursor note
    /// (`timeline.event.gap`). Session revisions are leased in ranges on the
    /// server (4096 at a time), so the client legitimately sees sequence
    /// numbers skip; that is not by itself an anomaly. Recovery still runs and
    /// its `timeline.recovery` entry shows whether any timeline event was
    /// actually missed. Anything not listed here stays `warn`, so a new kind
    /// is never silently downgraded to informational.
    static let infoKinds: Set<String> = [
        "app.launch", "app.foreground", "app.background",
        "diagnostics.enabled", "diagnostics.disabled",
        "diagnostics.verbose", "diagnostics.export",
        "cache.clear", "ui.screen",
        "session.open", "session.open.ready", "session.refresh",
        "timeline.snapshot.fetch", "timeline.snapshot.applied",
        "timeline.latest.fetch",
        "timeline.grouping", "timeline.recovery",
        "timeline.row.inserted", "timeline.row.moved",
        "timeline.interrupt.card", "timeline.anchor.placement", "timeline.mover",
        "timeline.working.row", "timeline.haptic",
        "timeline.compact.row", "timeline.footer.gate",
        "timeline.apply", "timeline.row.update", "timeline.height.delta",
        "ws.connecting", "ws.connect", "ws.disconnect",
        "timeline.event.gap",
    ]

    static func severity(for kind: String) -> String {
        infoKinds.contains(kind) ? "info" : "warn"
    }

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

    /// On unless the reader turned it off (pp 2026-11-13). Only the settings
    /// toggle writes this key, so an absent key is a fresh install, which
    /// records by default.
    var isEnabled: Bool {
        defaults.object(forKey: Self.enabledKey) == nil
            || defaults.bool(forKey: Self.enabledKey)
    }

    /// Off unless the reader turned it on: the detailed level is opt-in.
    var isVerbose: Bool { defaults.bool(forKey: Self.verboseKey) }

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

    /// Record one entry. Non-blocking: the caller never waits for the disk.
    ///
    /// Anomalies use the default `dedupe` so a stuck window cannot flood the
    /// file. User actions (`session.open`, `cache.clear`, a fetch) pass
    /// `dedupe: false` because the trail must preserve every occurrence.
    /// `verbose` marks the detailed level; without `isVerbose` the call
    /// returns before the fingerprint work.
    /// `force` is only for the event that turns recording off: it is written
    /// after the flag already reads false.
    func record(
        kind: String,
        sessionID: String? = nil,
        detail: [String: String] = [:],
        severity: String? = nil,
        dedupe: Bool = true,
        verbose: Bool = false,
        force: Bool = false
    ) {
        guard force || (isEnabled && (!verbose || isVerbose)) else { return }
        let resolvedSeverity = severity ?? Self.severity(for: kind)
        let stamp = now()
        guard dedupe else {
            queue.async { [weak self] in
                self?.append(
                    kind: kind, sessionID: sessionID, detail: detail,
                    severity: resolvedSeverity, at: stamp
                )
            }
            return
        }
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
                severity: resolvedSeverity, at: stamp
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

    /// Export the retained lines at or after `since` (nil = every retained
    /// day) into one temporary file for the share sheet.
    ///
    /// The file opens with a `# window: … | build … | device …` comment so a
    /// slice always carries the build that produced it. Runs of identical
    /// `timeline.mover` scroll samples collapse into one folded line — they
    /// are per-frame noise and a verbose day is mostly them — while every
    /// other kind is written verbatim.
    func exportWindow(since: Date?) -> URL? {
        queue.sync {
            let text = exportTextLocked(since: since)
            guard !text.isEmpty else { return nil }
            let stamp = Self.exportString(now(), calendar: calendar)
            let tag = since.map { "-since-" + Self.exportString($0, calendar: calendar) } ?? "-all"
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("Anywhere-diagnostics-\(stamp)\(tag).log")
            do {
                try Data(text.utf8).write(to: url, options: .atomic)
                return url
            } catch {
                return nil
            }
        }
    }

    /// The byte count `exportWindow(since:)` would write, for the export menu.
    func exportWindowSize(since: Date?) -> Int64 {
        exportWindowSizes(sinces: [since]).first ?? 0
    }

    /// One folded `timeline.mover` scroll run while sizing an export.
    private struct ExportRun {
        let key: String
        let first: String
        let firstBytes: Int
        var last: String
        var lastBytes: Int
        var totalBytes: Int
        var count: Int
    }

    /// Exact byte counts for several slices in one read/parse pass.
    ///
    /// The export menu asks for five windows. Building each slice's text
    /// separately re-parsed every retained day five times; on a verbose day
    /// (up to 5 MB) that held the log queue long enough to stall the page and
    /// every queued write (pp 2026-11-15: opening the log page loaded for a
    /// long time and hung). The counters mirror `exportTextLocked` exactly —
    /// header, the same folding, the same skipped rows — so the menu's size
    /// stays the size of the file it produces.
    func exportWindowSizes(sinces: [Date?]) -> [Int64] {
        queue.sync {
            let retained = daysLocked().sorted { $0.date < $1.date }
            guard !retained.isEmpty else { return sinces.map { _ in 0 } }
            var sizes = sinces.map {
                Int64(exportHeader(since: $0, firstDay: retained[0].date).utf8.count + 1)
            }
            var emitted = sinces.map { 1 }
            var runs: [ExportRun?] = Array(repeating: nil, count: sinces.count)

            func flushRun(_ index: Int) {
                defer { runs[index] = nil }
                guard let run = runs[index] else { return }
                if run.count <= 2 {
                    sizes[index] += Int64(run.count == 2 ? run.totalBytes : run.firstBytes)
                    emitted[index] += run.count
                    return
                }
                sizes[index] += Int64(run.firstBytes)
                if let folded = Self.foldedMoverLine(first: run.first, last: run.last,
                                                     collapsed: run.count - 1) {
                    sizes[index] += Int64(folded.utf8.count + 1)
                } else {
                    // The text export falls back to every raw line.
                    sizes[index] += Int64(run.totalBytes - run.firstBytes)
                }
                emitted[index] += 2
            }

            for day in retained {
                guard let data = try? Data(contentsOf: day.fileURL),
                      let text = String(data: data, encoding: .utf8) else { continue }
                for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                    let line = String(line)
                    let lineBytes = line.utf8.count + 1
                    guard let object = Self.jsonObject(line) else {
                        for index in sinces.indices where sinces[index] == nil {
                            sizes[index] += Int64(lineBytes)
                            emitted[index] += 1
                        }
                        continue
                    }
                    let kind = object["kind"] as? String
                    guard kind != "day.started", kind != "log.schema" else { continue }
                    let stamp = Self.isoDate(object["ts"] as? String)
                    let detail = object["detail"] as? [String: Any] ?? [:]
                    let isScroll = kind == "timeline.mover"
                        && detail["action"] as? String == "scroll"
                    let key = isScroll ? [
                        object["session"] as? String ?? "",
                        detail["placement"] as? String ?? "",
                        detail["contentH"] as? String ?? "",
                    ].joined(separator: "|") : ""
                    for index in sinces.indices {
                        guard let stamp else {
                            // Unparseable timestamps survive only the full export.
                            if sinces[index] == nil {
                                sizes[index] += Int64(lineBytes)
                                emitted[index] += 1
                            }
                            continue
                        }
                        if let since = sinces[index], stamp < since { continue }
                        if isScroll {
                            if var run = runs[index], run.key == key {
                                run.last = line
                                run.lastBytes = lineBytes
                                run.totalBytes += lineBytes
                                run.count += 1
                                runs[index] = run
                                continue
                            }
                            flushRun(index)
                            runs[index] = ExportRun(key: key, first: line, firstBytes: lineBytes,
                                              last: line, lastBytes: lineBytes,
                                              totalBytes: lineBytes, count: 1)
                            continue
                        }
                        flushRun(index)
                        sizes[index] += Int64(lineBytes)
                        emitted[index] += 1
                    }
                }
            }
            for index in sinces.indices { flushRun(index) }
            return sizes.indices.map { emitted[$0] > 1 ? sizes[$0] : 0 }
        }
    }

    /// The requested slice as one file body: the window header, then the
    /// filtered lines with mover scroll runs folded.
    private func exportTextLocked(since: Date?) -> String {
        let retained = daysLocked().sorted { $0.date < $1.date }
        guard !retained.isEmpty else { return "" }
        var output: [String] = [
            exportHeader(since: since, firstDay: retained[0].date)
        ]
        // A run of identical scroll samples: the period between two state
        // changes, which is all a reader needs from them.
        var run: [String] = []
        var runKey: String?

        func flushRun() {
            defer { run = []; runKey = nil }
            guard !run.isEmpty else { return }
            if run.count <= 2 {
                output.append(contentsOf: run)
                return
            }
            output.append(run[0])
            if let folded = Self.foldedMoverLine(first: run[0], last: run[run.count - 1],
                                                 collapsed: run.count - 1) {
                output.append(folded)
            } else {
                output.append(contentsOf: run.dropFirst())
            }
        }

        for day in retained {
            guard let data = try? Data(contentsOf: day.fileURL),
                  let text = String(data: data, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                let line = String(line)
                guard let object = Self.jsonObject(line) else {
                    // Legacy or comment lines: only kept by a full export.
                    if since == nil { output.append(line) }
                    continue
                }
                let kind = object["kind"] as? String
                guard kind != "day.started", kind != "log.schema" else { continue }
                guard let stamp = Self.isoDate(object["ts"] as? String) else {
                    if since == nil { output.append(line) }
                    continue
                }
                if let since, stamp < since { continue }
                let detail = object["detail"] as? [String: Any] ?? [:]
                let isScroll = kind == "timeline.mover"
                    && detail["action"] as? String == "scroll"
                if isScroll {
                    let key = [
                        object["session"] as? String ?? "",
                        detail["placement"] as? String ?? "",
                        detail["contentH"] as? String ?? "",
                    ].joined(separator: "|")
                    if key == runKey {
                        run.append(line)
                        continue
                    }
                    flushRun()
                    runKey = key
                    run = [line]
                    continue
                }
                flushRun()
                output.append(line)
            }
        }
        flushRun()
        guard output.count > 1 else { return "" }
        return output.joined(separator: "\n") + "\n"
    }

    private func exportHeader(since: Date?, firstDay: Date) -> String {
        var parts = [
            "# window: \(Self.isoString(since ?? firstDay, calendar: calendar)) – \(Self.isoString(now(), calendar: calendar))"
        ]
        parts.append("build \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?")")
        parts.append("version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")")
        parts.append("device \(Self.deviceDescription)")
        if let server = serverDescription() { parts.append("server \(server)") }
        return parts.joined(separator: " | ")
    }

    /// The first line of a folded mover run plus one synthetic line carrying
    /// the hidden count and the run's last position/time. JSON-encoded so a
    /// placement string's quotes survive.
    private static func foldedMoverLine(first: String, last: String,
                                        collapsed: Int) -> String? {
        guard let firstObject = jsonObject(first),
              let lastObject = jsonObject(last),
              let firstDetail = firstObject["detail"] as? [String: Any],
              let lastDetail = lastObject["detail"] as? [String: Any] else {
            return nil
        }
        var detail = firstDetail
        detail["collapsed"] = String(collapsed)
        detail["firstPosition"] = firstDetail["position"]
        detail["lastPosition"] = lastDetail["position"]
        var object: [String: Any] = [
            "ts": lastObject["ts"] ?? "",
            "kind": "timeline.mover",
            "severity": "info",
            "detail": detail,
        ]
        if let session = lastObject["session"] { object["session"] = session }
        guard let data = try? JSONSerialization.data(
            withJSONObject: object, options: [.sortedKeys]
        ) else { return nil }
        return String(decoding: data, as: UTF8.self)
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

    /// Remove the file the reader picked. A later event for the same day
    /// starts a fresh file with a new header.
    func delete(_ day: DiagnosticsDay) {
        queue.sync {
            try? FileManager.default.removeItem(at: day.fileURL)
            cappedDays.remove(Self.dayString(day.date, calendar: calendar))
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
            "schemaVersion": Self.schemaVersion,
        ]
        if let server = serverDescription() {
            detail["server"] = server
        }
        write(
            kind: "day.started", sessionID: nil, detail: detail,
            severity: "info", at: stamp, to: url
        )
        write(
            kind: "log.schema", sessionID: nil, detail: Self.schemaLegend,
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

    /// The anomaly flag is a byte search, not a per-line parse: the writer
    /// emits compact JSON with sorted keys, so an anomaly line always contains
    /// `"severity":"warn"`. Parsing every line here ran on the main thread via
    /// `days()` and froze the log page once a verbose day grew (pp 2026-11-15:
    /// opening the log page loaded for a long time and hung).
    private func fileHasEntries(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url) else { return false }
        return data.range(of: Data("\"severity\":\"warn\"".utf8)) != nil
            || data.range(of: Data("\"severity\" : \"warn\"".utf8)) != nil
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

    /// The configured server, as the host shown in day and export headers.
    private func serverDescription() -> String? {
        if let server = defaults.string(forKey: Self.serverKey), !server.isEmpty {
            return server
        }
        if let raw = defaults.string(forKey: "agentsAnywhere.serverURL"),
           let url = URL(string: raw), let host = url.host {
            return host
        }
        return nil
    }

    private func fileURL(for day: Date) -> URL {
        directory.appendingPathComponent(
            "\(Self.fileNamePrefix)\(Self.dayString(day, calendar: calendar)).\(Self.fileExtension)"
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
              kind != "day.started", kind != "log.schema" else { return nil }
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
        guard let prefix = recognizedPrefixes
            .first(where: { name.hasPrefix($0) }) else {
            return nil
        }
        guard let suffix = recognizedExtensions
            .map({ ".\($0)" })
            .first(where: { name.hasSuffix($0) }) else {
            return nil
        }
        let start = name.index(name.startIndex, offsetBy: prefix.count)
        let end = name.index(name.endIndex, offsetBy: -suffix.count)
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

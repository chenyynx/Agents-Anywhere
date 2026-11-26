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
    static let serverKey = "diagnostics.log.server"
    /// The build the last process logged under. Overwrite installs keep this
    /// defaults store, so a new build announces itself with one
    /// `build.changed` line instead of leaving the day looking like one build.
    static let lastBuildKey = "diagnostics.log.lastBuild"
    /// One `log.burst` summary per flooded second once a single `kind|session`
    /// passes this many records. A full re-sync lands as hundreds of ordinary
    /// row updates (pp 2026-11-19); without the summary they read as unrelated
    /// singles.
    static let burstThreshold = 30
    static let retainedDays = 7
    /// A busy day filled the old 5 MB cap by 21:02 and silently dropped the
    /// rest of the evening — exactly the window being investigated (pp
    /// 2026-11-19). 30 MB covers a whole normal day (~6–10 MB here); the
    /// seven-day window stays bounded at ~210 MB worst case.
    static let maxBytesPerDay = 30 * 1024 * 1024
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
        "kinds": "app.launch|app.foreground|app.background; diagnostics.enabled|diagnostics.disabled; cache.clear; session.open|session.open.ready|session.open.state_wait|session.refresh; timeline.snapshot.fetch|timeline.snapshot.applied|timeline.latest.fetch|timeline.grouping; timeline.row.inserted|timeline.row.moved|timeline.row.overlap; timeline.update.path|timeline.update.summary|timeline.height.estimate|timeline.leaf.partial|timeline.turnfacts.reset; timeline.recovery; timeline.recovery.turn_boundary_repair; timeline.step.pose_after_stop|timeline.tool.after_stop|timeline.queue.handoff|timeline.interrupt.card|timeline.anchor.placement|timeline.mover|timeline.bottom.request|timeline.pill.tap|timeline.working.row|timeline.rows.frame|timeline.compact.row|timeline.turn.footer|timeline.footer.gate|timeline.turn.footer.build|timeline.haptic|timeline.state|timeline.ws.state; ws.connect|ws.disconnect; timeline.event.gap; timeline.order.duplicate|timeline.order.nonpositive; timeline.user_message.unrendered; timeline.decode.dropped; build.changed; log.burst; selection.autoscroll; outline.open|outline.close|outline.frame|outline.reload|outline.keyboard|outline.scroll|outline.jump; shell.tabs.state|shell.tabs.duplicate|shell.tabs.transition|shell.tabs.active|shell.tabs.write|shell.tabs.frame; session.page.appear|session.page.disappear|session.page.active; composer.focus|composer.send.blocked|composer.keyboard.hide_focused; timeline.anchor.capture|timeline.anchor.capture.skip|timeline.anchor.restore|timeline.anchor.restore.start|timeline.anchor.restore.abandoned|timeline.anchor.fallback; session.live.start|session.open.failed|session.open.retry_pending; device.tab.open|device.tab.session|device.tab.delete|device.pair.open; nav.back.indicator",
        "fields": "ts=local ISO8601; kind; severity=info for actions and the gap note / warn for anomalies (derived from kind); session=session id; detail=string map. after/next=event cursor; rows=held row count; minOrder/maxOrder=window bounds; firstId/lastId=window edges; nextSeq=server high watermark; trigger=open|refresh|reconnect|recovery|rebuild|reconcile|fill|live|batch|history; limit=requested page size; status/bytes/deferred on fetches; eventTypes/eventIds on recovery; units/stepGroups/messageUnits/userRows/userUnrendered on grouping; ids/orderSeq/count for anomalies; prevId/nextId=nearest held neighbours, prevOrder/nextOrder=their orderSeq, rowsBefore=held rows before the merge, windowMin/windowMax=window bounds before the merge; oldOrder/newOrder=a held row's orderSeq change; overlap/upper/lower/heightChanges=the explicit-return overlap probe (first adjacent rows whose frames intersect, and the height corrections applied during that fly); group=step-group id; liveTail/allowsPose/fresh/stopRequested/predictedIdle=0/1 pose gates; status=runtime status; steps=step count; item=row id, from/to=status before/after, revival=1 when to=running, revision/updatedSeq=row version; from/to=send-queue roster before/after a change; head=head id:state; offsetY/contentH/visibleH/atBottom=viewport numbers at the change; running/streaming/placeholder/statusLine=drawn working gates; workingText=1 when the standalone working row draws its text, 0 while the send is still unacknowledged; liveTail=the group drawing the live tail; posing=groups the pose gate would animate, posingRunning=their running subset; state/title=the compact row's wire state and the divider label it draws; added/removed=item ids a refresh inserted or removed (one line per change); pendingSession/pendingTimeline=the two pending sources' message ids at that refresh; working=the standalone working row is drawn; timeline.state: from/to=runtime status before/after an applied state, seq=the state's updatedSeq, fresh=0/1 live-facts freshness after the apply, turnEnds=the authoritative end count after the apply, hasState/connection=input gate for that apply; timeline.ws.state: phase=recv|waited|barrier|apply for a runtime.state.updated frame, seq=its wire sequence, cursor=wire cursor, projSeq=timeline cursor at that moment, barrierSet=projection barrier already set, stateSeqBefore/After=the applied state's updatedSeq around the merge, status=status after the merge; timeline.footer.gate (all keys ride packed inside one `state=` value): suppress=the latest turn's footer is suppressed (0/1), gate=the footer gate stands open on a user bubble (0/1), pending=an outgoing bubble is awaiting its echo (0/1), echo=its echo row has landed (0/1), running=the runtime reports a turn in flight (0/1), status=runtime status, liveGroup=whether the live turn's group is resolved (set/nil), active=ids of the rows after the last visible user bubble that still count as live activity (the resolution's own collection and predicate; up to 3, every refresh; a background dispatch already seen keeps its exemption), ignored=ids in the same window that are status-active but exempt from activity (background hand-off / sub-agent child / compaction; up to 3), lastUser=that bubble's row id — the inputs that decide whether a footer can commit; timeline.turn.footer.build (one `state=` value, change-only): suppress=whether build withheld the latest bucket, gate=the footer gate stands open, running/newer/fresh/conn=the runtime inputs, hasState=whether a runtime state exists, stateSeq=the applied state's updatedSeq, mainMax/bgMax/anyMax=the newest row that can move the main turn, the newest background hand-off row excluded from it, and the whole-window sequence, coversMain=the state covers every main row (sub-agent children and background hand-off cards excluded), active=the final bucket's rows that counted as activity, hasActive=whether they blocked the commit, end=the host the bucket would have used, replies/changes=the copied rows it held, commit=whether the final commit wrote an action; timeline.state also carries runtimeId=the runtime instance the state came from (a new id means the connector restarted) and runtime=its family; build.changed: from/to=CFBundleVersion before/after an overwrite install; log.burst: hot=top flooded `kind|session=count` entries inside windowMs (a full re-sync shows up here instead of reading as unrelated row moves). outline.*: the conversation-outline sheet's own measurements (pp 2026-11-21). outline.open/outline.close bracket the sheet (rows/live/cached at open, openSec at close); outline.frame is written once a second while it is open: fps, hitches=frames with a gap over 33.4 ms, worstMs, builds/buildMs=row-content builds aggregated in that second, rows, status=runtime status during that second (a hitch that only appears while status=running points at the streaming transcript behind the sheet); outline.reload=one entry-list rebuild (ms, rows, live, cached); outline.keyboard=the search keyboard appearing or hiding (phase, height) — a downward drag that never yields a hide did not reach the list's interactive dismissal; outline.scroll=one scroll phase change inside the sheet's list (from/to); outline.jump=a row was chosen (searching=1 when it was a search hit) — a close without a following outline.keyboard hide means the keyboard outlived the sheet. timeline.update.path: item/path(fast|snapshot)/reason — written only when an item's update channel changes; timeline.update.summary: fast/apply counts plus lastFastItem and lastApplyReason, one line per backgrounding; timeline.height.estimate: a visible row still has no measured height 2 s after it appeared (item/heldMs); timeline.leaf.partial: a code row is still filling in more than 1 s after its spread build started (built/total/width); timeline.turnfacts.reset: the per-group turn-facts memo was dropped (cleared/latch); timeline.bottom.request: animated/forced/the placement the request saw (end|anchor), tracking/decelerating, offsetY and atBottom — the only record of a programmatic pull to the bottom when the reader did not gesture; timeline.pill.tap: the reader's own tap on the scroll-down indicator (pane) — a forced bottom request with no pill tap beside it is the app's doing. selection.autoscroll: the body-selection interaction and auto-scroll trail; action=began|began-pending|pending-wait|ended|tick-start|tick-stop|should-begin-reject|range-gesture-captured|range-begin|range-drive|range-end|interaction-begin|interaction-end; end=the moving handle (start|end), range=selection offsets, direction=-1/1, hasSelection=0/1, state=gesture state. shell.tabs.state: reason/tab/chat/device/path/visible = the pane navigation snapshot; shell.tabs.duplicate: tab/parkedChat/parkedDevices; session.page.*: pane=chat|devices, model, others, mount = the page-mount trail; others lists the panes still live for the session (both tabs may show it by design); mount is a per view-instance token — the same token across a disappear/appear pair means the tab switch only hid a mounted page, a new token means the page was rebuilt; session.page.active: active=0/1 as the tab becomes visible or hidden; session.page.disappear also carries active=the page's last isActive and reason=active|inactive (the shell's commit can land after the hidden page's onDisappear, so compare mount tokens, not the reason, to spot a rebuild); shell.tabs.transition: phase=start|settle around a tab change; shell.tabs.active: the tab the pages treat as active, committed in the same update as the bar's write; shell.tabs.write: every selection write the bar makes (to=t), including transient ones; shell.tabs.frame: one line per switch after a 0.7 s display-link window: frames, hitches=gaps over 33.4 ms, worstMs=the longest main-thread gap measured from the tap, ms=window length — a hitching switch dropped frames, a clean one with a late active points at the activation policy; composer.focus: pane/focused/keyboardOnScreen/windowKeyboard; composer.send.blocked: reason/shape/enabled/streaming; composer.keyboard.hide_focused: pane (a hide while the draft still owned focus); timeline.anchor.*: pane/item/offset/attempts/controller = reader-position capture and restore; session.live.start; session.open.failed/retry_pending: error; device.tab.*: device/previous/session; nav.back.indicator: asset=ok|missing.",
    ]

    /// Kinds recorded at info level: reader actions plus the cursor note
    /// (`timeline.event.gap`). Session revisions are leased in ranges on the
    /// server (4096 at a time), so the client legitimately sees sequence
    /// numbers skip; that is not by itself an anomaly. Recovery still runs and
    /// its `timeline.recovery` entry shows whether any timeline event was
    /// actually missed. Anything not listed here stays `warn`, so a new kind
    /// is never silently downgraded to informational.
    static let infoKinds: Set<String> = [
        "app.launch", "app.foreground", "app.background", "build.changed",
        "log.burst",
        "diagnostics.enabled", "diagnostics.disabled",
        "cache.clear",
        "session.open", "session.open.ready", "session.open.state_wait",
        "session.live.start",
        "session.page.appear", "session.page.disappear", "session.page.active",
        "shell.tabs.state", "shell.tabs.duplicate", "shell.tabs.transition", "shell.tabs.active",
        "shell.tabs.write", "shell.tabs.frame",
        "device.tab.open", "device.tab.session", "device.pair.open", "device.tab.delete",
        "composer.focus",
        "timeline.anchor.capture", "timeline.anchor.capture.skip",
        "timeline.anchor.restore", "timeline.anchor.restore.start",
        "timeline.anchor.restore.abandoned",
        "session.refresh",
        "timeline.snapshot.fetch", "timeline.snapshot.applied",
        "timeline.latest.fetch",
        "timeline.grouping", "timeline.recovery",
        "timeline.row.inserted", "timeline.row.moved", "timeline.row.overlap",
        "timeline.interrupt.card", "timeline.anchor.placement", "timeline.mover",
        "timeline.bottom.request", "timeline.pill.tap",
        "timeline.working.row", "timeline.rows.frame", "timeline.haptic",
        "timeline.compact.row", "timeline.turn.footer", "timeline.footer.gate",
        "timeline.turn.footer.build",
        "timeline.state",
        "ws.connecting", "ws.connect", "ws.disconnect",
        "timeline.event.gap",
        "selection.autoscroll",
        "outline.open", "outline.close", "outline.frame", "outline.reload",
        "outline.keyboard", "outline.scroll", "outline.jump",
        // The 2026-11-25 performance diagnostics: actions, not anomalies.
        "timeline.update.path", "timeline.update.summary",
        "timeline.height.estimate", "timeline.leaf.partial",
        "timeline.turnfacts.reset",
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
    private var burstWindowStart: Date?
    private var burstCounts: [String: Int] = [:]

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
    /// `force` is only for the event that turns recording off: it is written
    /// after the flag already reads false.
    func record(
        kind: String,
        sessionID: String? = nil,
        detail: [String: String] = [:],
        severity: String? = nil,
        dedupe: Bool = true,
        force: Bool = false
    ) {
        guard force || isEnabled else { return }
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
                .appendingPathComponent("Anywhere-diagnostics-\(stamp).log")
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

    /// Remove the file the reader picked. A later event for the same day
    /// starts a fresh file with a new header.
    func delete(_ day: DiagnosticsDay) {
        queue.sync {
            try? FileManager.default.removeItem(at: day.fileURL)
            cappedDays.remove(Self.dayString(day.date, calendar: calendar))
        }
    }

    // MARK: - Writing

    /// Counts records per `kind|session` inside the current second. A flooded
    /// second is summarised by one `log.burst` line so a full re-sync reads as
    /// one event instead of hundreds of unrelated row moves.
    private func noteBurst(kind: String, sessionID: String?, at stamp: Date) {
        let key = sessionID.map { "\(kind)|\($0)" } ?? kind
        if let start = burstWindowStart,
           stamp.timeIntervalSince(start) < 1 {
            burstCounts[key, default: 0] += 1
            return
        }
        flushBurst(at: stamp)
        burstWindowStart = stamp
        burstCounts = [key: 1]
    }

    private func flushBurst(at stamp: Date) {
        guard let start = burstWindowStart else { return }
        let hot = burstCounts.filter { $0.value >= Self.burstThreshold }
        burstCounts.removeAll(keepingCapacity: true)
        burstWindowStart = nil
        guard !hot.isEmpty else { return }
        let summary = hot.sorted { $0.value > $1.value }
            .prefix(4)
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ";")
        let day = calendar.startOfDay(for: stamp)
        ensureDayHeader(at: stamp)
        let url = fileURL(for: day)
        guard fileSize(url) < Self.maxBytesPerDay else { return }
        write(
            kind: "log.burst", sessionID: nil,
            detail: [
                "hot": summary,
                "windowMs": String(Int(stamp.timeIntervalSince(start) * 1000)),
            ],
            severity: "info", at: stamp, to: url
        )
    }

    private func append(
        kind: String,
        sessionID: String?,
        detail: [String: String],
        severity: String,
        at stamp: Date
    ) {
        noteBurst(kind: kind, sessionID: sessionID, at: stamp)
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

    private func fileHasEntries(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else {
            return false
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let object = Self.jsonObject(String(line)) else { continue }
            let kind = object["kind"] as? String
            let severity = object["severity"] as? String
            if kind != "day.started", kind != "log.schema", severity != "info" {
                return true
            }
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

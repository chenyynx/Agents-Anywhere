import Foundation

nonisolated struct V2SessionCachePolicy {
    /// Sessions resident at once, sized to the recently active working set so
    /// returning to a session after a background or app switch is served from
    /// cache instead of the network. Disk use is bounded by the user's cache
    /// limit (`LocalCachePolicy`) and the row store's per-session cap.
    var maximumSessions = 20
    var maximumTimelineItems = 1000
    static let defaultOpeningWindow = 300
    /// Rows read from the local store when a session opens.
    var openingWindow = Self.defaultOpeningWindow
    /// One history/latest page, aligned with the official Code events page.
    var networkPageSize = 200
    var catalogLifetime: TimeInterval = 30
}

/// The observed-session self-healing cadence. Doubling from `initial` up to
/// `maximum`, never beyond it. Injectable so tests pin the production schedule
/// instead of inheriting the 1 ms test sleep (red team F6).
nonisolated struct V2SessionHealBackoff: Equatable {
    var initial: Duration = .seconds(1)
    var maximum: Duration = .seconds(30)
    var mismatch: Duration = .milliseconds(600)

    func delay(step: Int) -> Duration {
        min(initial * (1 << min(step, 16)), maximum)
    }
}

/// Cadence of the newest-page fill that heals a window left behind by the
/// newer-window guard. The first attempt is a debounce; when a local-first
/// reconcile is already running it gets a longer grace before a second read.
/// Injectable so tests can pin the schedule instead of inheriting the 1 ms
/// test sleep.
nonisolated struct V2SessionLatestFillBackoff: Equatable {
    var initial: Duration = .milliseconds(300)
    var reconcileGrace: Duration = .milliseconds(1500)
    var maximum: Duration = .seconds(8)

    func delay(attempt: Int, reconcileRunning: Bool) -> Duration {
        if attempt == 0 { return reconcileRunning ? reconcileGrace : initial }
        return min(.seconds(1 << min(attempt, 4)), maximum)
    }
}

/// One recovery round that failed for a reason other than supersession.
///
/// The apply loop is all-or-nothing: a batch this build cannot apply leaves
/// the cursor parked where it was, so the same failure repeats on every read
/// (2026-10-07 stall). The record keeps the exact position of the failing
/// event — id, type, sequence and cursor — plus the cursor the round read
/// from, so a client-side stall is diagnosable without server logs.
nonisolated struct V2SessionRecoveryDiagnostic: Codable, Equatable {
    var eventId: String?
    var eventType: String?
    var eventSequence: Int?
    /// The cursor the failing event carries (where the batch would have moved to).
    var eventCursor: String?
    /// The cursor the round read from (`after:`), or the projection's cursor
    /// when the failure happened before any event could be touched.
    var fromCursor: String?
    var message: String
    var at: Date
}

/// An event the recovery batch could not apply, with the position it holds in
/// the batch. The round's catch classifies and reports `underlying` (the real
/// failure) while the event itself feeds the diagnostic record.
struct V2SessionRecoveryApplyFailure: Error {
    let event: V2SessionEvent
    let fromCursor: String
    let nextCursor: String
    let underlying: Error
}

/// One repository per authenticated server/account. Views observe values and invoke
/// operations; this layer owns request coalescing, bounded caches and live recovery.
@MainActor
final class V2SessionRepository {
    let scope: V2ClientScope
    private let detail: V2SessionDetailService
    private let interactions: V2RuntimeInteractionService
    private let localStore: V2LocalStore?
    private var persistenceTask: Task<Void, Never>?
    private let policy: V2SessionCachePolicy
    private let now: () -> Date
    private let sleep: (Duration) async throws -> Void
    /// Bounded window an attempt waits for the path monitor's first report
    /// before opening a socket anyway (see `waitUntilConnectionReady`).
    private let connectionReadinessWindow: Duration
    private let healBackoff: V2SessionHealBackoff
    private let latestFillBackoff: V2SessionLatestFillBackoff
    private var entries: [V2SessionID: Entry] = [:]
    /// Last dashboard pin value per session, so a remote pin change is mirrored
    /// into the row store even when the session is not open.
    private var lastKnownPins: [V2SessionID: Bool] = [:]
    private var accessCounter = 0
    private var suspended = false
    private(set) var network = V2NetworkStatus()

    init(
        scope: V2ClientScope,
        detail: V2SessionDetailService,
        interactions: V2RuntimeInteractionService,
        policy: V2SessionCachePolicy = V2SessionCachePolicy(),
        localStore: V2LocalStore? = nil,
        now: @escaping () -> Date = Date.init,
        sleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        connectionReadinessWindow: Duration = .milliseconds(1500),
        healBackoff: V2SessionHealBackoff = V2SessionHealBackoff(),
        latestFillBackoff: V2SessionLatestFillBackoff = V2SessionLatestFillBackoff()
    ) {
        self.scope = scope
        self.detail = detail
        self.interactions = interactions
        self.policy = policy
        self.localStore = localStore
        self.now = now
        self.sleep = sleep
        self.connectionReadinessWindow = connectionReadinessWindow
        self.healBackoff = healBackoff
        self.latestFillBackoff = latestFillBackoff
    }

    /// Bound on how long a not-ready path delays one connection attempt.
    private static let readinessProbeInterval: Duration = .milliseconds(100)
    /// Retry delay while the path itself is not usable, instead of the longer
    /// transient backoff that a reachable server earns.
    private static let notReadyRetryDelay: Duration = .milliseconds(500)
    /// Consecutive real recovery failures that justify a snapshot rebuild. One
    /// failure alone can be a transient read; two in a row with a usable path
    /// mean the batch itself is what cannot be applied.
    private static let recoveryFailureThreshold = 2
    /// Minimum interval between two snapshot rebuilds (the frequency gate on
    /// attempts, so a rebuild that fails cannot be retried every round).
    private static let recoveryRebuildInterval: TimeInterval = 300
    /// Failures kept per session in the diagnostic ring.
    private static let recoveryDiagnosticLimit = 8

    var cachedSessionIDs: Set<V2SessionID> { Set(entries.keys) }

    func session(id: V2SessionID) -> V2SessionModel {
        let entry = entry(for: id)
        evict(protecting: entry)
        return entry.model
    }

    func cached(sessionId: V2SessionID) -> V2SessionData? {
        guard let entry = entries[sessionId] else { return nil }
        touch(entry)
        return entry.projection?.data
    }

    /// The recovery failures booked on one session, oldest first (a bounded
    /// ring). The disclosure path does not read this; it exists so a stall can
    /// be diagnosed — in tests and in the field — without server logs.
    func recoveryDiagnostics(sessionId: V2SessionID) -> [V2SessionRecoveryDiagnostic] {
        entries[sessionId]?.recoveryDiagnostics ?? []
    }

    /// Clears the self-heal disclosure once the view has shown it. The notice
    /// is one-shot: dropping the entry field and emitting makes the model
    /// observe nil, so re-entering the session page cannot replay a notice
    /// already acknowledged. `snapshotRecoveryCount` is left untouched, so a
    /// later rebuild publishes a fresh, higher-numbered payload as before.
    func clearRecoveryNotice(sessionId: V2SessionID) {
        guard let entry = entries[sessionId], entry.recoveryNotice != nil else { return }
        entry.recoveryNotice = nil
        emit(entry)
    }

    /// Records a notification as acknowledged within its current open episode
    /// once its toast is closed. The notice is one-shot per episode: recording
    /// the id (and emitting so the model observes it) means a page rebuild or a
    /// relaunch cannot replay a notice already closed, while the next episode
    /// at the same id — after `reconcileNotificationAcknowledgements` drops this
    /// bar — surfaces again. No-op when already acknowledged.
    func acknowledgeNotification(sessionId: V2SessionID, noticeId: String) {
        guard let entry = entries[sessionId] else { return }
        guard !entry.acknowledgedNotifications.contains(noticeId) else { return }
        entry.acknowledgedNotifications.acknowledge(noticeId)
        emit(entry)
    }

    /// Ends the episodes of notification notices no longer open, so a fresh
    /// episode at the same id can surface again, and drops the acknowledgement
    /// of any notice that left the open set. Only an authoritative notice list
    /// may end an episode: while the projection's live facts are not fresh (a
    /// cold cache restore, an offline session) `notices` is empty for lack of
    /// data, not because every notice resolved, and reconciling against it would
    /// wrongly wipe a durable acknowledgement. So the reconcile is gated on
    /// `liveStateIsFresh`; a notice that resolved while the facts were stale is
    /// reconciled on the first fresh read instead.
    private func reconcileNotificationAcknowledgements(_ entry: Entry) {
        guard entry.projection?.data.liveStateIsFresh == true else { return }
        let open = Set((entry.projection?.data.notices ?? []).filter(\.isOpenNotification).map(\.noticeId))
        entry.acknowledgedNotifications.retain(open)
    }

    /// Returns cached durable content immediately. Observe to keep live facts fresh.
    func load(sessionId: V2SessionID) async throws -> V2SessionData {
        let entry = entry(for: sessionId)
        await restoreCachedSession(id: sessionId)
        try requireCurrent(entry)
        if let data = entry.projection?.data { return data }
        try requireNetwork()
        return try await hydrate(entry)
    }

    /// A page visit starts with the opening window, including cached visits.
    /// Explicit history loads may then accumulate additional pages.
    func open(sessionId: V2SessionID) async throws -> V2SessionData {
        let signpost = PerfSignpost.begin("session.open")
        defer { PerfSignpost.end("session.open", signpost) }
        let entry = entry(for: sessionId)
        _ = try await load(sessionId: sessionId)
        try Task.checkCancellation()
        try requireCurrent(entry)
        entry.readVersion += 1
        entry.historyTask?.cancel()
        entry.historyTask = nil
        entry.latestRefreshTask?.cancel()
        entry.latestRefreshTask = nil
        // Opening keeps the restored window: the row store and the in-memory
        // cap already bound it, and a trim here was what re-loaded history.
        let window = entry.projection?.data
        // A cached window can hold only SubAgent child rows: the server used
        // to return them inside the latest page, and L2.1 drops all of them
        // from the main timeline, so the page would open blank. One latest
        // read re-anchors the window on visible rows. Offline keeps the cached
        // window — the C0 fallback renders its rows.
        let windowHoldsNoMainRow = window?.items.contains { SubAgentProgress.parentItemID($0) == nil } == false
        // An evicted row store restores metadata without rows. The latest
        // page for such a session can be many megabytes (the device report's
        // session measured 11 MB for 200 rows), so the bounded snapshot is
        // the opening read: the server caps its timeline at about 2 MB plus
        // the newest row, it carries the runtime state, and it is one request
        // instead of a fill loop. `refresh` replaces the window and
        // re-establishes live recovery, so a frame in flight cannot land on
        // the old shell. The flag is only set by a restore, so a session that
        // is genuinely empty is not snapshotted twice; it stays set when the
        // read fails (offline or transient) so the retry path runs the same
        // read again.
        let restoredEmptyWindow = entry.restoredEmptyWindow
        if window?.items.isEmpty == true, restoredEmptyWindow,
           !entry.model.isLocalCreation {
            do {
                try requireNetwork()
                let data = try await refresh(sessionId: sessionId)
                entry.restoredEmptyWindow = false
                entry.needsSnapshot = false
                return data
            } catch {
                // The empty window has no self-heal trigger left: the saved
                // newer flag is cleared and there is no row to page from. Hand
                // the read to the connection loop, which hydrates whenever the
                // session reconnects (offline → online included).
                entry.needsSnapshot = true
                throw error
            }
        }
        entry.restoredEmptyWindow = false
        // A window cached before this client knew about `deferActivity` is
        // narrower than the deferred window and holds no summary rows. One
        // latest page re-reads it deferred; the response's echo decides
        // whether that read can ever help, so a server without the feature is
        // asked at most once per process (`deferredWindowUnsupported`).
        let needsDeferredWindow = window?.windowExcludesAgentChildren == true
            && window?.windowDeferredActivity == false
            && network.availability != .offline
            && window?.hasOlderItems == true
            && !entry.deferredWindowUnsupported
        if window?.hasNewerItems == true
            || (network.availability != .offline && window?.hasOlderItems == true && windowHoldsNoMainRow)
            || needsDeferredWindow {
            // Keep the instant local return, but the stale branch of the local
            // latest read now also schedules the guaranteed newest-page fill;
            // the page catches up without waiting for a network round trip.
            return try await loadLatest(sessionId: sessionId, limit: policy.networkPageSize)
        }
        return entry.projection!.data
    }

    func stageCreation(_ submission: NewSessionSubmission) {
        let entry = entry(for: submission.session.id)
        entry.projection = V2SessionProjection.placeholder(submission.session, maximumItems: policy.maximumTimelineItems, now: now)
        entry.model.stage(submission.pending)
        emit(entry)
    }

    func bindCreation(_ submission: NewSessionSubmission, response: V2SessionCreateResponse) {
        let entry = entry(for: response.session.id)
        if entry.projection == nil {
            entry.projection = V2SessionProjection.placeholder(response.session, maximumItems: policy.maximumTimelineItems, now: now)
            entry.needsSnapshot = true
        }
        for (attachment, uploaded) in zip(submission.pending.attachments, response.attachments ?? []) {
            submission.pending.bindUpload(uploaded.reference(sessionID: response.session.id), localID: attachment.id)
        }
        submission.pending.update(.accepted)
        entry.model.stage(submission.pending)
        emit(entry)
        remove(sessionIds: [submission.session.id])
    }

    func restoreCachedSession(id: String) async {
        guard let localStore else { return }
        let entry = entry(for: id)
        guard entry.projection == nil, !entry.hasReadLocal else { return }
        if entry.localReadTask == nil {
            entry.localReadTask = Task { await localStore.restoreSession(id, window: policy.openingWindow) }
        }
        let signpost = PerfSignpost.begin("session.restore")
        defer { PerfSignpost.end("session.restore", signpost) }
        let saved = await entry.localReadTask?.value
        guard isCurrent(entry), entry.projection == nil, !entry.hasReadLocal else { return }
        entry.hasReadLocal = true; entry.localReadTask = nil
        guard let saved, saved.archive.session.id == id else { return }
        let archive = saved.archive
        guard let projection = try? archive.projection(items: saved.items,
                                                       maximumItems: policy.maximumTimelineItems, now: now) else { return }
        entry.projection = projection
        // The row store keeps the session metadata when its rows are evicted;
        // an empty restored window must not inherit the saved newer flag (see
        // `settleEmptyWindow`). The flag tells `open` to take the bounded
        // snapshot instead of the multi-megabyte latest page; an archive that
        // was simply empty from birth does not qualify.
        entry.restoredEmptyWindow = saved.items.isEmpty
            && (archive.hasOlderItems || saved.localHasOlderRows)
        entry.projection?.settleEmptyWindow()
        entry.projection?.setLocalOlderAvailable(saved.localHasOlderRows)
        // A failure that outlived the process is still on record: the ring is
        // restored beside the projection it belongs to.
        entry.recoveryDiagnostics = archive.recoveryDiagnostics ?? []
        entry.acknowledgedNotifications = archive.acknowledgedNotifications ?? V2NotificationAcknowledgements()
        entry.model.restoreLocal(archive, subAgentActivity: saved.subAgentActivity)
        emit(entry, persist: false)
    }

    /// Writes only sessions whose durable state changed since their last save.
    /// Passing a session ID flushes just that session, e.g. before a send.
    func flushCache(sessionID: V2SessionID? = nil) async {
        if sessionID == nil { persistenceTask?.cancel(); persistenceTask = nil }
        guard let localStore else { return }
        let dirty = entries.values.filter { $0.isDirty && (sessionID == nil || $0.id == sessionID) }
            .sorted { $0.lastAccess < $1.lastAccess }
        for entry in dirty {
            guard let projection = entry.projection else { continue }
            entry.isDirty = false
            var archive = V2SessionArchive(data: projection.data, model: entry.model)
            archive.recoveryDiagnostics = entry.recoveryDiagnostics.isEmpty ? nil : entry.recoveryDiagnostics
            archive.acknowledgedNotifications = entry.acknowledgedNotifications.isEmpty ? nil : entry.acknowledgedNotifications
            await localStore.saveSession(archive)
        }
    }

    /// Streaming emits several times per second; a 2.5 s window coalesces them
    /// into one archive write per session instead of one per batch.
    private func schedulePersistence() {
        guard localStore != nil, persistenceTask == nil else { return }
        persistenceTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(2500)) } catch { return }
            await self?.flushCache()
        }
    }

    /// Multiple observers share one socket; removing the last observer closes it.
    func observe(sessionId: V2SessionID) -> AsyncStream<V2SessionObservation> {
        let entry = entry(for: sessionId)
        let observerID = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            entry.observers[observerID] = continuation
            continuation.yield(observation(entry))
            continuation.onTermination = { [weak self, weak entry] _ in
                Task { @MainActor [weak self, weak entry] in
                    guard let self, let entry else { return }
                    entry.observers.removeValue(forKey: observerID)
                    if entry.observers.isEmpty {
                        self.stop(entry)
                        self.evict()
                    }
                }
            }
            start(entry)
            // An observed session whose window is behind heals even when no
            // live row arrives to trigger the fill.
            if entry.projection?.data.hasNewerItems == true {
                scheduleLatestFill(entry)
            }
        }
    }

    /// Explicit refresh replaces the aggregate and then re-establishes live recovery.
    func refresh(sessionId: V2SessionID) async throws -> V2SessionData {
        try requireNetwork()
        let entry = entry(for: sessionId)
        stop(entry)
        entry.loadTask?.cancel()
        entry.loadTask = nil
        entry.readVersion += 1
        entry.historyTask?.cancel()
        entry.historyTask = nil
        defer { if isCurrent(entry) { start(entry) } }
        return try await hydrate(entry)
    }

    func loadOlder(sessionId: V2SessionID, limit: Int? = nil,
                   anchorOrderSeq: Int? = nil) async throws -> V2SessionData {
        let pageLimit = limit ?? policy.networkPageSize
        _ = try await load(sessionId: sessionId)
        let entry = entry(for: sessionId)
        // Browsing history supersedes a background latest reconcile: the
        // replacement must not land while the reader is moving away.
        entry.latestRefreshTask?.cancel()
        entry.latestRefreshTask = nil
        if let task = entry.historyTask { return try await task.value }
        guard let data = entry.projection?.data,
              data.canLoadOlder, let before = data.items.first?.orderSeq else {
            return entry.projection!.data
        }
        let version = entry.readVersion
        let task = Task { [self] in
            defer { if entry.readVersion == version { entry.historyTask = nil } }
            // Disk first: a seen page must not pay the network again. The
            // server flag stays untouched; localOlderAvailable carries the
            // disk's own boundary.
            if let localStore,
               let local = await localStore.olderRows(sessionID: sessionId,
                                                      beforeOrderSeq: before, limit: pageLimit),
               !local.items.isEmpty {
                // A page from the archive can carry a step the server has
                // already finished: its terminal update was missed, and the
                // disk copy would otherwise serve the stale status on every
                // visit. Read the server's page for this range instead; the
                // disk page stays the fallback when the read fails.
                if local.items.contains(where: { $0.status.isActive }) {
                    do {
                        try requireNetwork()
                        let page = try await detail.loadOlderItems(
                            sessionId: sessionId, beforeOrderSeq: before, limit: pageLimit,
                            excludeAgentChildren: data.windowExcludesAgentChildren)
                        try requireCurrent(entry, version: version)
                        entry.projection?.applyHistory(page, anchorOrderSeq: anchorOrderSeq)
                        if let first = entry.projection?.data.items.first?.orderSeq {
                            let hasMoreLocal = await localStore.hasOlderRows(
                                sessionID: sessionId, beforeOrderSeq: first)
                            entry.projection?.setLocalOlderAvailable(hasMoreLocal)
                        }
                        emit(entry)
                        return entry.projection!.data
                    } catch {
                        // Offline/transient: the disk page is still usable.
                        // Cancellation/invalidation re-surface below.
                    }
                }
                try requireCurrent(entry, version: version)
                let page = V2SessionTimelinePage(
                    sessionId: sessionId, items: local.items,
                    nextSeq: entry.projection?.sequence ?? 0,
                    hasMore: data.hasOlderItems,
                    serverTime: nil,
                    excludesAgentChildren: data.windowExcludesAgentChildren)
                entry.projection?.applyHistory(page, anchorOrderSeq: anchorOrderSeq)
                entry.projection?.setLocalOlderAvailable(local.hasMore)
                emit(entry)
                return entry.projection!.data
            }
            guard data.hasOlderItems else {
                entry.projection?.setLocalOlderAvailable(false)
                emit(entry)
                return entry.projection!.data
            }
            try requireNetwork()
            let page = try await detail.loadOlderItems(sessionId: sessionId, beforeOrderSeq: before,
                limit: pageLimit, excludeAgentChildren: true, deferActivity: true)
            try requireCurrent(entry, version: version)
            entry.projection?.applyHistory(page, anchorOrderSeq: anchorOrderSeq)
            if let localStore,
               let first = entry.projection?.data.items.first?.orderSeq {
                let hasMoreLocal = await localStore.hasOlderRows(sessionID: sessionId,
                                                                 beforeOrderSeq: first)
                entry.projection?.setLocalOlderAvailable(hasMoreLocal)
            }
            emit(entry)
            return entry.projection!.data
        }
        entry.historyTask = task
        return try await task.value
    }

    /// The reader is back at the newest edge of the held window. History
    /// paging stops anchoring there, so live creates append normally instead
    /// of being deferred until an explicit latest page.
    func followLatest(sessionId: V2SessionID) {
        guard let entry = entries[sessionId] else { return }
        entry.projection?.followLatest()
        // Back at the newest edge with a window the server already got past:
        // the deferred rows cannot be recovered by scrolling, only by a read.
        if entry.projection?.data.hasNewerItems == true {
            scheduleLatestFill(entry)
        }
    }

    /// `authoritative` is for callers whose result decides a visible row: a
    /// composer send and the echo watchdog. They skip the local-first shortcut
    /// and read the newest page from the server; a failed read still falls
    /// back to the store so the page stays usable, with the newer flag kept
    /// for the retry. The opening and the scroll-return path stay local-first
    /// and heal through `scheduleLatestFill`.
    func loadLatest(sessionId: V2SessionID, limit: Int? = nil,
                    authoritative: Bool = false) async throws -> V2SessionData {
        let pageLimit = limit ?? policy.networkPageSize
        _ = try await load(sessionId: sessionId)
        let entry = entry(for: sessionId)
        entry.readVersion += 1
        entry.historyTask?.cancel()
        entry.historyTask = nil
        entry.latestRefreshTask?.cancel()
        entry.latestRefreshTask = nil
        let version = entry.readVersion
        // Local first, online included: a return-to-bottom must not wait for
        // the network when the row store already holds the newest page. The
        // local page is applied immediately; if its saved cursor is behind the
        // live projection (or it says its tail is incomplete), a background
        // network read reconciles it without blocking the return.
        if !authoritative,
           let local = try await applyUsableLocalLatest(entry, limit: pageLimit, version: version) {
            return local
        }
        // An opening latest read and the observed-lifecycle fill would
        // otherwise issue the same multi-megabyte page concurrently. The fill
        // is dropped while this read owns the newest side; if this read leaves
        // the window behind (a failed or still-stale page), it schedules the
        // debounced follow-up itself.
        entry.latestReadInFlight += 1
        defer {
            entry.latestReadInFlight -= 1
            if entry.latestReadInFlight == 0, entry.projection?.data.hasNewerItems == true {
                scheduleLatestFill(entry)
            }
        }
        do {
            try requireNetwork()
            let page = try await detail.latestItems(
                sessionId: sessionId, limit: pageLimit,
                excludeAgentChildren: true, deferActivity: true)
            try requireCurrent(entry, version: version)
            entry.projection?.applyLatest(page)
            // The echo is the only proof this server honours the deferred
            // read. A `false` retires the open-time repair for the rest of
            // the process instead of re-asking on every visit.
            if page.sessionId == sessionId { entry.deferredWindowUnsupported = !page.deferredActivity }
            emit(entry)
            return entry.projection!.data
        } catch {
            guard authoritative else { throw error }
            if let fallback = try? await applyUsableLocalLatest(entry, limit: pageLimit, version: version) {
                return fallback
            }
            // The entry moved on while the read was in flight; its current
            // window is already at least as new as the local page we could
            // not apply. Never fail an opening for a stale local read.
            if let current = entry.projection?.data { return current }
            throw error
        }
    }

    /// Applies the store's newest page when it reaches the held window's end.
    /// Returns nil when the disk page cannot stand in for a latest read.
    ///
    /// `>=`, not `>`: browsing history keeps both sides of the reader
    /// (V2SessionProjection.browseMaximumItems), so the projection's last
    /// row can already be the store's newest row. Requiring a strictly
    /// newer local row sent that equal-end case to the network and made
    /// the return-to-bottom block on it (and hang when the read was held).
    private func applyUsableLocalLatest(_ entry: Entry, limit: Int,
                                        version: Int) async throws -> V2SessionData? {
        guard let localStore,
              let local = await localStore.latestRows(sessionID: entry.id, limit: limit),
              let newest = local.items.last?.orderSeq,
              let end = entry.projection?.data.items.last?.orderSeq,
              newest >= end else { return nil }
        try requireCurrent(entry, version: version)
        let localIsCurrent = !local.hasNewerRows
            && V2SessionProjection.sequence(local.cursor) >= (entry.projection?.sequence ?? 0)
        let page = V2SessionTimelinePage(
            sessionId: entry.id, items: local.items,
            nextSeq: local.items.map(\.updatedSeq).max() ?? 0,
            hasMore: entry.projection?.data.hasOlderItems ?? false,
            serverTime: nil,
            excludesAgentChildren: entry.projection?.data.windowExcludesAgentChildren ?? false,
            deferredActivity: entry.projection?.data.windowDeferredActivity ?? false)
        entry.projection?.applyLatest(page, hasNewerAfterApply: !localIsCurrent)
        entry.projection?.setLocalOlderAvailable(local.hasMore)
        emit(entry)
        if !localIsCurrent {
            startLatestReconcile(entry, limit: limit, version: version)
            // The background reconcile can be canceled or invalidated (the
            // 2026-11-01 freeze). The debounced fill is the guaranteed retry;
            // it no-ops as soon as the flag clears.
            scheduleLatestFill(entry)
        }
        return entry.projection!.data
    }

    /// A local latest page is on screen; the network read updates it in the
    /// background. A failure keeps the local content and the newer prompt.
    private func startLatestReconcile(_ entry: Entry, limit: Int, version: Int) {
        guard network.availability != .offline else {
#if AA_TIMELINE_PROBE
            entry.latestSkipped += 1
            entry.lastLatest = "skipped-offline"
            emit(entry, persist: false)
#endif
            return
        }
        entry.latestRefreshTask?.cancel()
#if AA_TIMELINE_PROBE
        entry.latestStarted += 1
        entry.lastLatest = "started"
        emit(entry, persist: false)
#endif
        entry.latestRefreshTask = Task { @MainActor [weak self, weak entry] in
            guard let self, let entry else { return }
            defer {
                if entry.readVersion == version { entry.latestRefreshTask = nil }
            }
            do {
                let page = try await self.detail.latestItems(
                    sessionId: entry.id, limit: limit, excludeAgentChildren: true)
                try self.requireCurrent(entry, version: version)
                // A background fill, not a reader return: if the reader is
                // paged into history, keep their anchor and only add the
                // newest rows the stale local page was missing.
                entry.projection?.applyLatest(page, keepingAnchor: true)
#if AA_TIMELINE_PROBE
                entry.latestApplied += 1
                entry.lastLatest = "applied rows=\(page.items.count) end=\(page.items.last?.orderSeq ?? 0)"
#endif
                self.emit(entry)
            } catch {
                // The local page is already displayed. Keep `hasNewerItems`
                // set so the prompt remains available; the next connection
                // recovery will reconcile the same rows.
#if AA_TIMELINE_PROBE
                entry.latestFailed += 1
                entry.lastLatest = "failed: \(V2ClientFailure(error).message.prefix(48))"
                self.emit(entry, persist: false)
#endif
            }
        }
    }

    /// A live row was refused because it sits beyond a window the projection
    /// already knows is incomplete. The row cannot be inserted without the
    /// missing span, so read the newest page once the burst settles. Debounced
    /// and single-flight per session, and only while the reader is at the
    /// newest edge: a history reader's window is completed by the bottom path.
    private func scheduleLatestFill(_ entry: Entry) {
        guard TimelineStaleWindowHeal.enabled else { return }
        guard isCurrent(entry), !suspended else { return }
        // The fill belongs to the observed lifecycle: a session nobody is
        // looking at must not poll large pages (the entry may outlive the
        // page visit that triggered the read).
        guard !entry.observers.isEmpty else { return }
        // A history reader's window is completed by the bottom-return path;
        // filling it here would move content under the reader.
        guard entry.projection?.isFollowingLatest == true else { return }
        // A latest read already owns the newest side (the opening path); its
        // own completion schedules the follow-up if it left the window behind.
        guard entry.latestReadInFlight == 0 else { return }
        guard entry.latestFillTask == nil else { return }
#if AA_TIMELINE_PROBE
        entry.deferredNewer += 1
        entry.latestStarted += 1
        entry.lastLatest = "fill-started"
        emit(entry, persist: false)
#endif
        entry.latestFillID = UUID()
        let fillID = entry.latestFillID
        entry.latestFillTask = Task { @MainActor [weak self, weak entry] in
            defer {
                if entry?.latestFillID == fillID { entry?.latestFillTask = nil }
            }
            var attempt = 0
            while let self, let entry, self.isCurrent(entry), !Task.isCancelled {
                // Give an in-flight local-first reconcile the first window; a
                // second read is only issued when it is not running.
                let delay = self.latestFillBackoff.delay(
                    attempt: attempt, reconcileRunning: entry.latestRefreshTask != nil)
                do { try await self.sleep(delay) } catch { return }
                guard let projection = entry.projection,
                      projection.data.hasNewerItems,
                      projection.isFollowingLatest else { return }
                if self.network.availability == .offline {
                    attempt += 1
                    continue
                }
                // A direct read may have started while this fill slept; it
                // owns the newest side now, and its own completion schedules
                // the follow-up if the window is still behind.
                if entry.latestReadInFlight > 0 {
                    attempt += 1
                    continue
                }
                do {
                    try await self.fillNewestWindow(entry)
                } catch {
                    attempt += 1
#if AA_TIMELINE_PROBE
                    entry.latestFailed += 1
                    entry.lastLatest = "fill-failed"
                    self.emit(entry, persist: false)
#endif
                    continue
                }
                if entry.projection?.data.hasNewerItems != true {
#if AA_TIMELINE_PROBE
                    entry.latestApplied += 1
                    entry.lastLatest = "fill-applied"
                    self.emit(entry, persist: false)
#endif
                    return
                }
                attempt += 1
            }
        }
    }

    /// Reads and merges the newest page without touching the reader's anchor:
    /// the caller has already checked that the reader is at the newest edge.
    private func fillNewestWindow(_ entry: Entry) async throws {
        try requireNetwork()
        // A snapshot or refresh that replaced the projection while this read
        // was in flight owns the window now; an older page must not be merged
        // into it (it could reintroduce rows the snapshot deleted).
        let version = entry.readVersion
        let page = try await detail.latestItems(
            sessionId: entry.id, limit: policy.networkPageSize, excludeAgentChildren: true)
        try requireCurrent(entry, version: version)
        guard let projection = entry.projection, projection.isFollowingLatest else { return }
        entry.projection?.applyLatest(page)
        // The echo is the only proof this server honours the deferred read. A
        // `false` (or absent, from an old server) retires the open-time
        // repair for the rest of the process instead of re-asking on every
        // visit.
        if page.sessionId == sessionId { entry.deferredWindowUnsupported = !page.deferredActivity }
        emit(entry)
    }

    /// The reader left the bottom before a local-first latest page finished
    /// reconciling; its replacement must not land under a history reader.
    func cancelLatestReconcile(sessionId: V2SessionID) {
        guard let entry = entries[sessionId] else { return }
        guard entry.latestRefreshTask != nil else { return }
        entry.latestRefreshTask?.cancel()
        entry.latestRefreshTask = nil
#if AA_TIMELINE_PROBE
        entry.latestCanceled += 1
        entry.lastLatest = "canceled"
        emit(entry, persist: false)
#endif
    }

    /// Reads one row's complete payload and replaces its summary in place.
    /// Isolated from paging and live recovery: only the addressed row changes,
    /// and only when the window still holds it. A failure propagates unchanged
    /// so the caller owns the visible retry state.
    func loadDeferredItem(sessionId: V2SessionID, itemId: V2TimelineItemID) async throws {
        try requireNetwork()
        let entry = entry(for: sessionId)
        let item = try await detail.timelineItem(sessionId: sessionId, itemId: itemId)
        try requireCurrent(entry)
        guard item.sessionId == sessionId else { throw CacheError.invalidated }
        guard entry.projection?.replaceDeferredItem(item) == true else { return }
        emit(entry)
    }

    /// One SubAgent card's child rows (C3) for a main-only window. Kept out of
    /// the projection on purpose: the panel's on-demand read must never touch
    /// the timeline window, whose paging boundaries and live/recovery rules
    /// belong to the repository. A 422 propagates unchanged — the caller reads
    /// it as "server does not support this read" and does not retry.
    func loadSubAgentChildren(
        sessionId: V2SessionID,
        parentItemId: String,
        beforeOrderSeq: Int? = nil,
        limit: Int = 100
    ) async throws -> V2SessionTimelinePage {
        try requireNetwork()
        return try await detail.childrenItems(
            sessionId: sessionId, parentItemId: parentItemId, beforeOrderSeq: beforeOrderSeq, limit: limit)
    }

    func catalogs(sessionId: V2SessionID, force: Bool = false, capabilities: V2RuntimeCapabilitySnapshot? = nil) async throws -> V2SessionCatalogs {
        let entry = entry(for: sessionId)
        let scopes = capabilities.map { value in Set(["model", "permission"].filter { value.allows("catalog.\($0)") }) }
        if entry.catalogScopes != scopes {
            invalidateCatalogs(entry)
            entry.catalogScopes = scopes
        }
        if !force, let cached = entry.catalogs, let readAt = entry.catalogReadAt,
           now().timeIntervalSince(readAt) < policy.catalogLifetime { return cached }
        try requireNetwork()
        if let task = entry.catalogTask { return try await task.value }
        let version = entry.catalogVersion
        let task = Task { [self] in
            defer {
                if entry.catalogVersion == version { entry.catalogTask = nil }
                evict()
            }
            let catalogs = try await detail.catalogs(sessionId: sessionId, scopes: scopes)
            try requireCurrent(entry)
            guard version == entry.catalogVersion else { throw CacheError.invalidated }
            entry.catalogs = catalogs
            entry.catalogReadAt = now()
            evict()
            return catalogs
        }
        entry.catalogTask = task
        return try await task.value
    }

    /// The command catalog is read once per live connection; it is dropped with
    /// the option catalogs when the connection stops or selections change.
    func commands(sessionId: V2SessionID, force: Bool = false) async throws -> [V2RuntimeCommand] {
        let entry = entry(for: sessionId)
        if !force, let cached = entry.commands { return cached }
        try requireNetwork()
        let version = entry.catalogVersion
        let commands = try await interactions.commands(sessionId: sessionId)
        try requireCurrent(entry)
        guard version == entry.catalogVersion else { throw CacheError.invalidated }
        entry.commands = commands
        return commands
    }

    func executeCommand(sessionId: V2SessionID, request: RuntimeCommandRequest) async throws -> V2RuntimeCommandExecuteResponse {
        try requireNetwork()
        let entry = entry(for: sessionId)
        let response = try await interactions.executeCommand(sessionId: sessionId, command: request.command, arguments: request.args, raw: request.raw)
        try requireCurrent(entry)
        if let session = response.session { entry.projection?.applyMeta(session); emit(entry) }
        return response
    }

    func draftDidChange(sessionID: V2SessionID) {
        entries[sessionID]?.isDirty = true
        schedulePersistence()
    }

    func localWorkDidChange(sessionID: V2SessionID) {
        if let entry = entries[sessionID] { emit(entry) }
    }

    func send(sessionId: V2SessionID, content: String, attachmentIDs: [V2AttachmentID] = [], clientMessageID: String) async throws -> V2RuntimeActionResponse {
        try requireNetwork()
        let entry = entry(for: sessionId)
        let response = try await detail.sendMessage(sessionId: sessionId, content: content, attachmentIds: attachmentIDs, clientMessageId: clientMessageID)
        try requireCurrent(entry)
        // Timeline echoes reconcile by clientMessageId; sending never refetches the snapshot.
        return response
    }

    func steer(sessionId: V2SessionID, content: String, attachmentIDs: [V2AttachmentID] = [], clientMessageID: String) async throws -> V2RuntimeActionResponse {
        try requireNetwork()
        let entry = entry(for: sessionId)
        let response = try await detail.steer(sessionId: sessionId, content: content, attachmentIds: attachmentIDs, clientMessageId: clientMessageID)
        try requireCurrent(entry)
        return response
    }

    func interrupt(sessionId: V2SessionID, preserveBackground: Bool = false) async throws {
        try requireNetwork()
        let entry = entry(for: sessionId)
        do { _ = try await detail.interrupt(sessionId: sessionId, preserveBackground: preserveBackground) }
        catch {
            // The capability gate refuses an interrupt exactly when there is
            // no turn to stop ("session capability is unavailable:
            // session.interrupt" — server/agent_server/services/session_run.py).
            // That is the outcome the caller asked for, and the second half of
            // a double send lands here; both are success. Every other failure
            // is real and keeps propagating.
            if !meansNoActiveTurnInterrupt(error, entry: entry) { throw error }
        }
        try requireCurrent(entry)
        // The accepted interrupt is proof the runtime is stopping the turn,
        // but its ack carries no state and the frames that would report the
        // idle turn can be late or lost. Flow the composer to the post-stop
        // turn window now; a background round calibrates it against
        // authoritative facts (and a failed round rolls it back).
        entry.predictedIdleSequence = entry.recoverySequence
        entry.model.runtime.beginPredictedIdle()
        emit(entry)
        launchFollowUpReconcile(entry)
    }

    /// Stops one SubAgent task (§A3). Deliberately not an interrupt: a
    /// background task lives outside any turn, so this never plays with the
    /// turn window and never predicts an idle — the card converges from the
    /// task's own terminal event. An unknown task id is a non-event (the
    /// server answers `stopped: false` inside a successful envelope), so it
    /// is not an error; every real failure keeps propagating.
    func stopSubagent(sessionId: V2SessionID, taskId: String) async throws {
        try requireNetwork()
        let entry = entry(for: sessionId)
        _ = try await detail.stopSubagent(sessionId: sessionId, taskId: taskId)
        try requireCurrent(entry)
    }

    /// Recognises the one 409 that means "already stopped" rather than "the
    /// stop failed": the session capability gate refusing `session.interrupt`
    /// because no turn is active. The server answers the same sentence for
    /// every capability refusal — `supported=false`, `available=false` and
    /// `allowed=false` alike (`session_run.py:762-767`) — so the text alone
    /// cannot tell "nothing to stop" from "this runtime has no interrupt at
    /// all"; only a last-known interrupt capability the runtime supports and
    /// permits lets the refusal count as success. Everything else, including
    /// read-only and offline conflicts, keeps failing loudly (red team F2).
    private func meansNoActiveTurnInterrupt(_ error: Error, entry: Entry) -> Bool {
        guard let http = error as? HTTPError, case let .server(status, message, _) = http, status == 409 else { return false }
        guard message.contains("session capability is unavailable") && message.contains("session.interrupt") else { return false }
        guard let capability = entry.projection?.data.capabilities.capability(id: "session.interrupt") else { return false }
        return capability.supported && capability.allowed
    }

    func setTakeover(sessionId: V2SessionID, enabled: Bool) async throws {
        try requireNetwork()
        let entry = entry(for: sessionId)
        let session = try await detail.setTakeover(sessionId: sessionId, enabled: enabled)
        try requireCurrent(entry)
        entry.projection?.applyMeta(session)
        entry.projection?.markStale()
        emit(entry)
        // Takeover was confirmed by the write response. A failed following read
        // must not invite a duplicate toggle or claim the write was rejected.
        // The read must also start after the write: joining a round that was
        // already in flight could apply live facts that predate it.
        do { try await reconcile(entry, requiringRoundAfter: entry.recoverySequence) }
        catch { if isCurrent(entry) { entry.error = V2ClientFailure(error); emit(entry) } }
    }

    func setSelection(sessionId: V2SessionID, scope: V2RuntimeSelectionScope, selectionId: V2SelectionID?) async throws {
        try requireNetwork()
        let entry = entry(for: sessionId)
        let state = try await detail.updateSelection(sessionId: sessionId, scope: scope, selectionId: selectionId)
        try requireCurrent(entry)
        // Only the selections come from this response; its status is not a
        // fact (see V2SessionProjection.applySelections), so a switch made
        // while a turn runs can no longer rewrite the projection to idle.
        if let state { entry.projection?.applySelections(state) }
        invalidateCatalogs(entry)
        emit(entry)
        // Aligned with setTakeover/respond: the confirmed write is followed by
        // a recovery round whether or not a frame arrives, so the projection
        // holds live facts again. The write is already confirmed; a failed
        // read reports itself without making the write look rejected.
        launchFollowUpReconcile(entry)
    }

    /// The write's follow-up recovery, run as a *background* round: the caller
    /// returns as soon as the write is confirmed, so neither the options sheet
    /// nor the composer's `isWorking` gate ever waits on network reads (red
    /// team F1 — an awaited round put a read with HTTP-level retries inside
    /// the stop path). The round keeps the single-flight/epoch discipline:
    /// `performRecovery` joins a suitable in-flight round or launches one that
    /// `stop()` can supersede. On failure the optimistic turn end rolls back
    /// and the failure lands on the entry's existing error channel; on success
    /// the live facts end the prediction themselves.
    ///
    /// The wrapper Task itself is registered on the entry (`stop()` cancels it
    /// with the rest of the lifecycle — review F-I): without that, a failure
    /// landing after the entry was stopped still passed the `isCurrent` check
    /// (a stopped entry stays registered) and wrote an error into a dead
    /// lifecycle. Only the wrapper that still owns the slot may clear it or
    /// write back, so a superseded or stopped wrapper can never touch a newer
    /// lifecycle's state.
    private func launchFollowUpReconcile(_ entry: Entry) {
        let sequence = entry.recoverySequence
        let id = UUID()
        entry.followUpReconcileTask?.cancel()
        entry.followUpReconcileID = id
        entry.followUpReconcileTask = Task { [weak self] in
            guard let self else { return }
            let failure = await self.performRecovery(entry, requiringRoundAfter: sequence)
            guard entry.followUpReconcileID == id else { return }
            entry.followUpReconcileTask = nil
            guard let failure, !Task.isCancelled, self.isCurrent(entry) else { return }
            entry.predictedIdleSequence = nil
            entry.model.runtime.endPredictedIdle()
            entry.error = V2ClientFailure(failure)
            emit(entry)
        }
    }

    func respond(sessionId: V2SessionID, noticeId: V2NoticeID, actionId: String, input: JSONValue? = nil) async throws {
        try requireNetwork()
        let entry = entry(for: sessionId)
        _ = try await interactions.respond(sessionId: sessionId, noticeId: noticeId, actionId: actionId, input: input)
        try requireCurrent(entry)
        // Response acceptance is not notice resolution; wait for authoritative
        // live facts, read after the write (never joining an older round).
        entry.projection?.markStale()
        emit(entry)
        do { try await reconcile(entry, requiringRoundAfter: entry.recoverySequence) }
        catch {
            // The action already succeeded. A failed read must not turn an
            // accepted approval into a retryable write failure in the UI.
            if isCurrent(entry) { entry.error = V2ClientFailure(error); emit(entry) }
        }
    }

    func sync(sessionId: V2SessionID) async throws {
        try requireNetwork()
        let entry = entry(for: sessionId)
        _ = try await detail.sync(sessionId: sessionId)
        try requireCurrent(entry)
        try await reconcile(entry, requiringRoundAfter: entry.recoverySequence)
    }

    func applyMetadata(_ sessions: [V2SessionMeta]) {
        var pinUpdates: [V2SessionID: Bool] = [:]
        for session in sessions {
            if let known = lastKnownPins[session.id], known != session.pinned {
                pinUpdates[session.id] = session.pinned
            }
            lastKnownPins[session.id] = session.pinned
        }
        if !pinUpdates.isEmpty, let localStore {
            Task { await localStore.updatePinned(pinUpdates) }
        }
        for session in sessions {
            guard let entry = entries[session.id] else { continue }
            let previous = entry.projection?.data.session
            // Dashboard pushes repeat every session on each tick; unchanged
            // metadata must not re-project and re-persist every open session.
            let changed = entry.projection?.applyMeta(session) ?? false
            let invalidates = session.connectorStatus != .online || previous?.effectiveRuntimeId != session.effectiveRuntimeId
            if invalidates { invalidateCatalogs(entry) }
            if changed || invalidates { emit(entry) }
            if session.connectorStatus == .online,
               previous?.connectorStatus != .online || previous?.effectiveRuntimeId != session.effectiveRuntimeId {
                // A dashboard projection can arrive before the session socket frame.
                // Restart observed sessions so their runtime facts match the new binding.
                stop(entry)
                start(entry)
            }
        }
    }

    func suspend() {
        suspended = true
        for entry in entries.values { stop(entry); emit(entry, persist: false) }
    }

    func resume() {
        suspended = false
        for entry in entries.values { start(entry, catchUp: true) }
        // A window left behind while the app was away heals on resume even
        // when neither an opening nor a bottom trigger runs. Only observed
        // sessions: the fill belongs to the same lifecycle as the socket.
        for entry in entries.values
        where !entry.observers.isEmpty && entry.projection?.data.hasNewerItems == true {
            scheduleLatestFill(entry)
        }
    }

    func updateConnectivity(_ status: V2NetworkStatus) {
        let wasOffline = network.availability == .offline
        network = status
        for entry in entries.values {
            if status.availability == .offline {
                stop(entry)
                entry.readVersion += 1
                entry.loadTask?.cancel()
                entry.loadTask = nil
                entry.historyTask?.cancel()
                entry.historyTask = nil
                entry.connection = .offline
            } else if wasOffline {
                start(entry, catchUp: true)
                // Recovery replays events after the cursor; a window whose
                // missing rows are older than the cursor needs a latest read.
                // Only observed sessions, like the socket recovery itself.
                if !entry.observers.isEmpty, entry.projection?.data.hasNewerItems == true {
                    scheduleLatestFill(entry)
                }
            }
            emit(entry, persist: false)
        }
    }

    private func requireNetwork() throws {
        if network.availability == .offline {
            throw V2ClientFailure(kind: .offline, message: String(localized: "You are offline. Cached content is still available."))
        }
    }

    func remove(sessionIds: [V2SessionID]) {
        for id in sessionIds {
            if let localStore { Task { await localStore.removeSession(id) } }
            guard let entry = entries.removeValue(forKey: id) else { continue }
            dispose(entry)
        }
    }

    /// Cancellation plus identity checks prevent late responses from repopulating a signed-out cache.
    func reset() {
        persistenceTask?.cancel(); persistenceTask = nil
        let old = Array(entries.values)
        entries.removeAll()
        for entry in old { dispose(entry) }
    }

    private func hydrate(_ entry: Entry) async throws -> V2SessionData {
        if let task = entry.loadTask { return try await task.value }
        entry.readVersion += 1
        entry.historyTask?.cancel()
        entry.historyTask = nil
        entry.latestRefreshTask?.cancel()
        entry.latestRefreshTask = nil
        let version = entry.readVersion
        let task = Task { [self] in
            defer {
                if entry.readVersion == version { entry.loadTask = nil }
                evict()
            }
            let snapshot = try await detail.load(sessionId: entry.id, excludeAgentChildren: true)
            try requireCurrent(entry, version: version)
            guard snapshot.session.id == entry.id else { throw CacheError.invalidated }
            entry.projection = V2SessionProjection(snapshot: snapshot, maximumItems: policy.maximumTimelineItems, now: now)
            // The snapshot is already a window read with `deferActivity`; its
            // echo settles whether a later open-time repair could ever help.
            entry.deferredWindowUnsupported = !snapshot.deferredActivity
            invalidateCatalogs(entry)
            entry.error = nil
            emit(entry)
            evict()
            return entry.projection!.data
        }
        entry.loadTask = task
        return try await task.value
    }

    private func start(_ entry: Entry, catchUp: Bool = false) {
        guard isCurrent(entry), !entry.model.isLocalCreation, !suspended, network.availability != .offline,
              !entry.observers.isEmpty, entry.connectionTask == nil else { return }
        // Healing rides the observed lifecycle: it needs an entry someone is
        // looking at, and stop() ends both. It starts *after* the guards so an
        // entry nobody observes (a cached session, a suspended one) is never
        // given a spinning task (red team F5).
        startHealing(entry)
        let connectionID = UUID()
        entry.connectionID = connectionID
        entry.connectionTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if entry.connectionID == connectionID { entry.connectionTask = nil }
            }
            var attempt = 0
            while self.isCurrent(entry), entry.connectionID == connectionID, !Task.isCancelled {
                do {
                    // A path that is known to be down must not burn the first
                    // attempt. A missing monitor report only delays the attempt
                    // for a bounded window; request success stays the only
                    // proof that the server is reachable.
                    guard await self.waitUntilConnectionReady() else {
                        do { try await self.sleep(Self.notReadyRetryDelay) }
                        catch { return }
                        continue
                    }
                    entry.connection = attempt == 0 ? .connecting : .reconnecting
                    self.emit(entry, persist: false)
                    _ = try await self.load(sessionId: entry.id)
                    if entry.needsSnapshot {
                        _ = try await self.hydrate(entry)
                        entry.needsSnapshot = false
                    }
                    if catchUp, self.beginCatchUp(entry) {
                        // Ordering only: let the incremental recovery reads reach
                        // the transport before the socket ticket is requested.
                        // The round keeps running on its own.
                        await Task.yield()
                    }
                    let events = try await self.detail.updates(sessionId: entry.id, clientId: "ios-session-\(connectionID)")
                    for try await event in events {
                        try self.requireCurrent(entry)
                        guard entry.connectionID == connectionID else { return }
                        if event.type == "session.subscribed" {
                            // The socket is registered before recovery, closing
                            // the snapshot/subscribe race. Only a round launched
                            // after this frame can stand in for that read; an
                            // older in-flight round is awaited, then replaced.
                            let sequenceAtSubscribe = entry.recoverySequence
                            try await self.reconcile(entry, requiringRoundAfter: sequenceAtSubscribe)
                            try self.requireCurrent(entry)
                            guard entry.connectionID == connectionID else { return }
                            entry.connection = .connected
                            attempt = 0
                            self.emit(entry, persist: false)
                        } else {
                            try await self.receive(event, entry: entry)
                        }
                    }
                    throw CacheError.connectionClosed
                } catch {
                    guard self.isCurrent(entry), entry.connectionID == connectionID, !Task.isCancelled else { return }
                    entry.projection?.markStale()
                    self.invalidateCatalogs(entry)
                    let failure = V2ClientFailure(error)
                    entry.error = failure
                    guard failure.permitsAutomaticReconnect else {
                        entry.connection = .failed(failure.message)
                        self.emit(entry, persist: false)
                        return
                    }
                    entry.connection = .reconnecting
                    self.emit(entry, persist: false)
                    attempt += 1
                    // Failures while the path itself is not usable retry at a
                    // short fixed delay instead of the long transient backoff.
                    let delay: Duration = self.network.availability == .online
                        ? .seconds(min(1 << min(attempt - 1, 4), 15))
                        : Self.notReadyRetryDelay
                    do { try await self.sleep(delay) }
                    catch { return }
                }
            }
        }
    }

    /// Bounded wait for a usable path before an attempt opens a socket. A path
    /// that is positively offline never issues requests. When the monitor has
    /// not reported yet (`.unknown`) the attempt is delayed only for the
    /// window: path status is a scheduling hint, not proof of reachability.
    private func waitUntilConnectionReady() async -> Bool {
        if network.availability == .online { return true }
        var remaining = connectionReadinessWindow
        while remaining > .zero, !Task.isCancelled {
            if network.availability == .online { return true }
            if network.availability == .offline { return false }
            do { try await sleep(Self.readinessProbeInterval) }
            catch { return false }
            remaining -= Self.readinessProbeInterval
        }
        return !Task.isCancelled && network.availability != .offline
    }

    private func receive(_ event: V2SessionEvent, entry: Entry) async throws {
        guard event.sessionId == entry.id else { return }
        if let pending = entry.loadTask { _ = try await pending.value }
        // Let an in-flight recovery finish before merging this frame; a failed
        // round has already been quieted or reported to its own caller.
        if let pending = entry.recoveryTask { _ = await pending.value }
        if event.type == "session.refetch_required" || event.sequence > (entry.projection?.sequence ?? 0) + 1 {
            try await reconcile(entry)
        }
        try requireCurrent(entry)
        let readTypes = ["runtime.state.updated", "runtime.capability.updated", "runtime.notice.snapshot", "runtime.notice.updated"]
        if readTypes.contains(event.type), event.receivedAt < entry.projectionBarrier { return }
        let wasOnline = entry.projection?.data.session.connectorStatus == .online
        let previousRuntime = entry.projection?.data.session.effectiveRuntimeId
        if event.type == "timeline.snapshot", event.sequence >= (entry.projection?.sequence ?? 0) {
            entry.readVersion += 1
            entry.historyTask?.cancel()
            entry.historyTask = nil
            entry.latestRefreshTask?.cancel()
            entry.latestRefreshTask = nil
        }
        let mergedOutcome = try entry.projection?.apply(event)
        // Confirm a pending send only from the row the projection actually
        // merged. Half-applied sends used to be confirmed straight from the
        // event payload while the window guard dropped the row; the bubbles
        // then stayed visible forever waiting for an echo that never landed.
        if let merged = mergedOutcome {
            if merged.deferredNewer {
                // The window is behind the stream; opening the gap is a read,
                // not an insert.
                scheduleLatestFill(entry)
            } else {
                entry.model.confirmEcho(merged.item)
            }
        }
        if event.type == "runtime.catalog.updated" || entry.projection?.data.session.connectorStatus != .online {
            invalidateCatalogs(entry)
        }
        if event.type == "runtime.state.updated" || event.type == "runtime.capability.updated" {
            scheduleMismatchHeal(entry)
        }
        // A catch-up backlog arrives back-to-back without suspending; publishing
        // once the main queue turns again applies the whole burst before the
        // model and rows re-project. Restores upstream 5536261b, whose call site
        // the 2.1.0 merge (fde5785c) dropped while keeping the helper.
        emitAfterBacklog(entry)
        // The orb's receive pulse: only this live path consumes a merge
        // outcome — replay, snapshot, paging and cache restores never reach
        // this code, so nothing else can ring the orb (§6.3).
        if let merged = mergedOutcome, !merged.deferredNewer {
            let decision = OrbPulsePolicy.decide(item: merged.item, wasInserted: merged.wasInserted,
                                                 now: event.receivedAt, lastStreamPulseAt: entry.lastStreamPulseAt)
            entry.lastStreamPulseAt = decision.streamPulseAt
            if let pulse = decision.pulse { entry.model.noteIncomingPulse(pulse) }
        }
        if entry.projection?.data.session.connectorStatus == .online,
           !wasOnline || previousRuntime != entry.projection?.data.session.effectiveRuntimeId {
            try await reconcile(entry)
        }
    }

    private func reconcile(_ entry: Entry, requiringRoundAfter sequence: Int? = nil) async throws {
        if let error = await performRecovery(entry, requiringRoundAfter: sequence) { throw error }
    }

    // MARK: - Self-healing

    /// Watches one observed session for a projection that needs healing and
    /// nudges a recovery round. It starts with the socket lifecycle and ends
    /// with it; failures are quiet here (the socket path reports its own
    /// failures), and the condition is re-checked before every attempt so a
    /// session that healed keeps costing nothing.
    ///
    /// The cadence is the injected `healBackoff` — doubling from its initial
    /// delay to its cap, and never abandoned: past the cap the retry continues
    /// at the capped interval so a session the user can see cannot sit grey
    /// forever (U6). The cap also keeps a persistently failing read at one
    /// attempt per interval instead of a storm.
    private func startHealing(_ entry: Entry) {
        guard entry.healTask == nil else { return }
        let healID = UUID()
        entry.healID = healID
        entry.healTask = Task { [weak self] in
            defer { if entry.healID == healID { entry.healTask = nil } }
            var step = 0
            while !Task.isCancelled {
                guard let self, self.isCurrent(entry) else { return }
                do { try await self.sleep(self.healBackoff.delay(step: step)) } catch { return }
                guard !Task.isCancelled, self.isCurrent(entry) else { return }
                guard self.needsHealing(entry) else { step = 0; continue }
                let failure = await self.performRecovery(entry)
                step = failure == nil && !self.needsHealing(entry) ? 0 : min(step + 1, 16)
            }
        }
    }

    /// Whether this projection needs a heal round. Staleness is only one of
    /// the cases: the state and capability frames of one turn window are
    /// delivered independently, so a fresh projection can also be internally
    /// contradictory, and that state has no frame of its own to wait for.
    ///
    /// Healing waits for a settled connection: the connect and reconnect
    /// paths run their own recovery, and a write that fails a round while the
    /// socket is up is exactly the hole this fills. A failed connection and
    /// an offline connector are their own, explainable states; the reconnect
    /// paths re-run recovery when either returns.
    private func needsHealing(_ entry: Entry) -> Bool {
        guard let projection = entry.projection, !entry.model.isLocalCreation else { return false }
        guard entry.connection == .connected else { return false }
        guard projection.data.session.connectorStatus == .online else { return false }
        if !projection.data.liveStateIsFresh { return true }
        return hasStateCapabilityMismatch(entry)
    }

    /// The documented turn-window contract keeps `session.send_message` and
    /// `session.interrupt` complementary while a turn is active
    /// (docs/api/capabilities.md). When a fresh projection has a complementary
    /// pair that contradicts the state status, one of the two independently
    /// delivered frames is stale. Only complementary pairs are judged, so a
    /// runtime that does not follow the contract is never second-guessed, and
    /// the remedy is a read, never a local rewrite.
    private func hasStateCapabilityMismatch(_ entry: Entry) -> Bool {
        guard let projection = entry.projection, projection.data.liveStateIsFresh,
              let state = projection.data.state else { return false }
        let capabilities = projection.data.capabilities
        guard let send = capabilities.capability(id: "session.send_message"),
              let interrupt = capabilities.capability(id: "session.interrupt"),
              send.supported, interrupt.supported else { return false }
        let turnActiveByCapability = interrupt.available && !send.available
        let turnIdleByCapability = !interrupt.available && send.available
        guard turnActiveByCapability || turnIdleByCapability else { return false }
        return state.status.isTurnInFlight != turnActiveByCapability
    }

    /// A contradiction observed on a frame gets its own trigger, debounced so
    /// the frame's sibling can land first; the periodic heal above is the
    /// backstop for one that is never re-observed.
    private func scheduleMismatchHeal(_ entry: Entry) {
        guard hasStateCapabilityMismatch(entry), entry.mismatchHealTask == nil else { return }
        let healID = UUID()
        entry.mismatchHealID = healID
        let delay = healBackoff.mismatch
        entry.mismatchHealTask = Task { [weak self] in
            defer { if entry.mismatchHealID == healID { entry.mismatchHealTask = nil } }
            guard let self else { return }
            do { try await self.sleep(delay) } catch { return }
            guard !Task.isCancelled, self.isCurrent(entry), self.hasStateCapabilityMismatch(entry) else { return }
            _ = await self.performRecovery(entry)
        }
    }

    /// Runs, or joins, the single recovery round for this entry.
    ///
    /// Rounds are owned by the entry's recovery epoch rather than by a socket
    /// generation, so the socket handshake can start, or restart, while a
    /// foreground catch-up is in flight without invalidating it. A round that
    /// a `stop()` superseded finishes quietly and applies nothing, and a later
    /// caller starts its own round instead of inheriting that outcome.
    ///
    /// `requiringRoundAfter` is the recovery sequence observed before a socket
    /// subscribed: only a round launched after that point can prove the
    /// snapshot/subscribe race is closed, so an older in-flight round is
    /// awaited quietly and a fresh round runs instead.
    private func performRecovery(_ entry: Entry, requiringRoundAfter sequence: Int? = nil) async -> Error? {
        if let task = entry.recoveryTask {
            let joins = sequence.map { entry.recoveryTaskSequence > $0 } ?? true
            if joins { return await task.value }
            _ = await task.value
        }
        launchRecoveryRound(entry)
        guard let task = entry.recoveryTask else { return nil }
        return await task.value
    }

    /// Foreground catch-up: start the recovery round before the socket
    /// handshake, so incremental events and live facts never queue behind the
    /// ticket and subscribe round trips. Failure stays internal; the socket's
    /// post-subscribe recovery is the authority and is idempotent with this
    /// round. Returns whether a round was launched.
    @discardableResult
    private func beginCatchUp(_ entry: Entry) -> Bool {
        guard isCurrent(entry), !suspended, network.availability != .offline,
              entry.projection != nil, entry.recoveryTask == nil else { return false }
        launchRecoveryRound(entry)
        return true
    }

    private func launchRecoveryRound(_ entry: Entry) {
        entry.recoverySequence += 1
        let sequence = entry.recoverySequence
        let epoch = entry.recoveryEpoch
        entry.recoveryTaskSequence = sequence
        entry.recoveryTask = Task { [self] () -> Error? in
            let outcome = await self.runRecovery(entry, epoch: epoch, sequence: sequence)
            // Only the round that owns the slot may clear it, so a superseded
            // round can never erase a newer round's registration.
            if entry.recoveryEpoch == epoch, entry.recoveryTaskSequence == sequence {
                entry.recoveryTask = nil
            }
            return outcome
        }
    }

    /// One recovery round, owned by `epoch`:
    /// - reads durable events and authoritative live facts concurrently,
    /// - applies recovered events first so a meta update they carry lands
    ///   before the runtimeId check inside `applyLive`,
    /// - captures the projection barrier before either read starts, so socket
    ///   frames received during the window are never suppressed by an older
    ///   read.
    ///
    /// The round reports failure to its caller — the socket path surfaces it,
    /// the catch-up path ignores it — and writes `entry.error` itself in
    /// exactly one case: a snapshot rebuild whose own fetch failed, which must
    /// be visible whichever path ran the round (see `handleRecoveryFailure`).
    private func runRecovery(_ entry: Entry, epoch: UUID, sequence: Int) async -> Error? {
        do {
            try requireRecoveryEpoch(entry, epoch: epoch)
            try requireNetwork()
            if entry.projection == nil { _ = try await hydrate(entry) }
            try requireCurrent(entry)
            try requireRecoveryEpoch(entry, epoch: epoch)
            guard let projection = entry.projection else { throw CacheError.invalidated }
            let cursor = projection.data.cursor
            // Frames received before these reads must not overwrite their
            // newer projection; capturing the barrier first keeps frames that
            // arrive during the window.
            let barrier = now()
            // Live facts are only read while the connector is online; when it
            // is offline the socket path re-reads them once it returns. The
            // read runs concurrently with the recovery read below and is
            // consumed after recovered events have been applied, so a meta
            // update they carry lands before the runtimeId check in applyLive.
            let service = detail
            let sessionID = entry.id
            let liveTask: Task<V2SessionLiveState, Error>? = projection.data.session.connectorStatus == .online
                ? Task { try await service.liveState(sessionId: sessionID) }
                : nil
            defer { liveTask?.cancel() }
            let recovery = try await detail.recover(sessionId: entry.id, after: cursor)
            try requireCurrent(entry)
            try requireRecoveryEpoch(entry, epoch: epoch)
            if recovery.snapshotRequired {
                _ = try await hydrate(entry)
                try requireCurrent(entry)
                try requireRecoveryEpoch(entry, epoch: epoch)
            } else {
                for event in recovery.events.sorted(by: { $0.sequence < $1.sequence }) {
                    do {
                        let merged = try entry.projection?.apply(event)
                        // Same rule as the live path: an event only confirms
                        // the pending bubble when its row entered the window.
                        if let merged {
                            if merged.deferredNewer {
                                self.scheduleLatestFill(entry)
                            } else {
                                entry.model.confirmEcho(merged.item)
                            }
                        }
                    } catch {
                        // The batch is all-or-nothing, so this event's position
                        // is the whole story of the stall: carry it out of the
                        // loop instead of losing it with the throw.
                        throw V2SessionRecoveryApplyFailure(event: event, fromCursor: cursor,
                                                            nextCursor: recovery.nextCursor, underlying: error)
                    }
                }
                entry.projection?.advanceCursor(recovery.nextCursor)
            }
            entry.projection?.markStale()
            invalidateCatalogs(entry)
            if entry.projection?.data.session.connectorStatus == .online {
                var liveState: V2SessionLiveState?
                if let liveTask { liveState = try await liveTask.value }
                if recovery.snapshotRequired || liveState == nil {
                    // The snapshot just re-read is newer than the parallel
                    // read, and a connector that turned online during recovery
                    // was not read in parallel at all.
                    liveState = try await detail.liveState(sessionId: entry.id)
                }
                if let liveState {
                    try requireCurrent(entry)
                    try requireRecoveryEpoch(entry, epoch: epoch)
                    entry.projection?.applyLive(liveState)
                    entry.projectionBarrier = barrier
                    entry.error = nil
                    // Authoritative facts landed: the optimistic turn end has
                    // done its job and truth takes over, whatever it says. A
                    // round launched *before* the prediction carries a
                    // pre-write read, so it must not end the window the ack
                    // just opened (red team F4) — only a round the prediction
                    // ordered can.
                    if let predictedAt = entry.predictedIdleSequence, sequence > predictedAt {
                        entry.predictedIdleSequence = nil
                        entry.model.runtime.endPredictedIdle()
                    }
                }
            }
            entry.recoveryFailureStreak = 0
            emit(entry)
            return nil
        } catch {
            return await handleRecoveryFailure(error, entry: entry, epoch: epoch)
        }
    }

    /// Books one real recovery failure and runs the single automatic remedy.
    ///
    /// The apply loop is all-or-nothing, so a batch this build cannot apply
    /// would otherwise park the cursor forever: after
    /// `Self.recoveryFailureThreshold` consecutive failures with a usable path
    /// the projection is rebuilt from a fresh snapshot (`hydrate`, the same
    /// path a cold load uses), which resets the cursor to the snapshot's
    /// high-water mark. The rebuild is frequency-gated
    /// (`Self.recoveryRebuildInterval`) so a persistently failing session
    /// still costs at most one snapshot per window.
    ///
    /// Returns the error the round reports to its caller, or nil when the
    /// rebuild succeeded: a rebuilt projection is recovered state, and handing
    /// the stale batch failure to the socket path would tear the connection
    /// down (or leave it failed) right after the data was repaired. Live facts
    /// are re-read by the next round — the socket's or the heal loop's —
    /// exactly as after any snapshot hydrate.
    private func handleRecoveryFailure(_ error: Error, entry: Entry, epoch: UUID) async -> Error? {
        let apply = error as? V2SessionRecoveryApplyFailure
        let cause = apply?.underlying ?? error
        guard !isSuperseded(cause) else { return nil }
        // A path that is positively down says nothing about this batch: the
        // offline gate refused the read, the reconnect/heal paths own the
        // outage, and the rebuild is left to the heal retry once it returns.
        guard network.availability != .offline else { return cause }
        recordRecoveryDiagnostic(apply: apply, cause: cause, entry: entry)
        entry.recoveryFailureStreak += 1
        guard entry.recoveryFailureStreak >= Self.recoveryFailureThreshold else { return cause }
        let now = now()
        if let last = entry.lastSnapshotRecoveryAt, now.timeIntervalSince(last) < Self.recoveryRebuildInterval { return cause }
        // The gate covers attempts, not only successes: a rebuild that cannot
        // fetch either must not run on every single round.
        entry.lastSnapshotRecoveryAt = now
        do {
            _ = try await hydrate(entry)
        } catch {
            let rebuildCause = (error as? V2SessionRecoveryApplyFailure)?.underlying ?? error
            // A rebuild displaced by a competing read or a newer lifecycle is
            // not a failure to report: that read owns the projection now.
            guard !isRebuildSuperseded(rebuildCause), isCurrent(entry), entry.recoveryEpoch == epoch else { return nil }
            // The snapshot did not come either. Say so instead of hiding it —
            // the error channel is the visible disclosure and, unlike the
            // round's return value, it reaches the user whichever path ran the
            // round (the catch-up and heal paths discard round outcomes) —
            // keep the streak, and let the heal retry after the gate.
            entry.error = V2ClientFailure(rebuildCause)
            emit(entry)
            return cause
        }
        guard isCurrent(entry), entry.recoveryEpoch == epoch else { return nil }
        entry.recoveryFailureStreak = 0
        entry.snapshotRecoveryCount += 1
        entry.recoveryNotice = V2SessionRecoveryNotice(
            title: String(localized: "同步已自动恢复"),
            message: String(localized: "会话数据曾多次同步失败，已重建到最新状态（第 \(entry.snapshotRecoveryCount) 次自动恢复）。"))
        emit(entry)
        return nil
    }

    /// Records one failed round. The failing event's position is captured
    /// verbatim when the apply loop is where it broke; a failure before any
    /// event (the read itself) still records the cursor it read from.
    private func recordRecoveryDiagnostic(apply: V2SessionRecoveryApplyFailure?, cause: Error, entry: Entry) {
        let record = V2SessionRecoveryDiagnostic(
            eventId: apply?.event.eventId,
            eventType: apply?.event.type,
            eventSequence: apply?.event.sequence,
            eventCursor: apply?.event.cursor ?? apply?.nextCursor,
            fromCursor: apply?.fromCursor ?? entry.projection?.data.cursor,
            message: V2ClientFailure(cause).message,
            at: now()
        )
        entry.recoveryDiagnostics.append(record)
        let excess = entry.recoveryDiagnostics.count - Self.recoveryDiagnosticLimit
        if excess > 0 { entry.recoveryDiagnostics.removeFirst(excess) }
        // Diagnostics ride on the archive, so recording one is a durable change:
        // mark the entry dirty even on the sub-threshold path that returns
        // without publishing. Otherwise an entry whose dirty flag a prior flush
        // just cleared would drop the first diagnostic of a failure streak.
        entry.isDirty = true
        schedulePersistence()
    }

    private func requireRecoveryEpoch(_ entry: Entry, epoch: UUID) throws {
        try Task.checkCancellation()
        guard entry.recoveryEpoch == epoch else { throw CacheError.superseded }
    }

    private func isSuperseded(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let cache = error as? CacheError, cache == .superseded { return true }
        return false
    }

    /// A rebuild can also be displaced by a competing read of the same entry
    /// (`CacheError.invalidated`): that is the same silence as a superseded
    /// round, because the newer read owns the projection now.
    private func isRebuildSuperseded(_ error: Error) -> Bool {
        if isSuperseded(error) { return true }
        if let cache = error as? CacheError, cache == .invalidated { return true }
        return false
    }

    private func entry(for id: V2SessionID) -> Entry {
        // A view may look up its stable model while a containing sidebar moves.
        // Re-projecting here walks every historical item and also registers all
        // of those observable values as dependencies of the caller's view body.
        if let entry = entries[id] { touch(entry); return entry }
        let entry = Entry(id: id, model: V2SessionModel(id: id, scope: scope, repository: self))
        entries[id] = entry
        touch(entry)
        if network.availability == .offline { entry.connection = .offline }
        entry.model.update(observation(entry), network: network)
        return entry
    }

    private func touch(_ entry: Entry) { accessCounter += 1; entry.lastAccess = accessCounter }
    private func isCurrent(_ entry: Entry) -> Bool { entries[entry.id] === entry }

    private func requireCurrent(_ entry: Entry, version: Int? = nil) throws {
        try Task.checkCancellation()
        guard isCurrent(entry), version == nil || version == entry.readVersion else { throw CacheError.invalidated }
    }

    private func observation(_ entry: Entry) -> V2SessionObservation {
        V2SessionObservation(sessionId: entry.id, data: entry.projection?.data, connection: entry.connection, error: entry.error,
                             recoveryNotice: entry.recoveryNotice,
                             acknowledgedNotifications: entry.acknowledgedNotifications)
    }

    /// Frames buffered during a reconnect or a long reconcile are delivered
    /// back-to-back without suspending. Publishing once the main queue turns
    /// again lets the whole backlog apply before the model and rows re-project,
    /// so catch-up cost is frames × log n instead of frames × n.
    private func emitAfterBacklog(_ entry: Entry) {
        guard !entry.emitScheduled else { return }
        entry.emitScheduled = true
        DispatchQueue.main.async { [weak self, weak entry] in
            guard let self, let entry else { return }
            entry.emitScheduled = false
            self.emit(entry)
        }
    }

    /// `persist` marks durable changes (timeline, metadata, cursor, local work).
    /// Connection and connectivity transitions republish without an archive write.
    private func emit(_ entry: Entry, persist: Bool = true) {
        guard isCurrent(entry) else { return }
        // End any notification episode that resolved before publishing, so the
        // observation (and the page that reads it) never carries a stale
        // acknowledgement for a notice that is no longer open.
        reconcileNotificationAcknowledgements(entry)
#if AA_TIMELINE_PROBE
        entry.model.updateWindowSnapshot(windowSnapshot(entry))
#endif
        entry.model.update(observation(entry), network: network)
        for observer in entry.observers.values { observer.yield(observation(entry)) }
        if persist, entry.projection != nil {
            entry.isDirty = true
            schedulePersistence()
        }
    }

#if AA_TIMELINE_PROBE
    private func windowSnapshot(_ entry: Entry) -> V2TimelineWindowSnapshot {
        var snapshot = V2TimelineWindowSnapshot()
        if let projection = entry.projection {
            snapshot.endOrderSeq = projection.data.items.last?.orderSeq ?? 0
            snapshot.cursorSequence = projection.sequence
            snapshot.hasNewerItems = projection.data.hasNewerItems
            snapshot.anchoredToHistory = !projection.isFollowingLatest
        }
        snapshot.latestStarted = entry.latestStarted
        snapshot.latestApplied = entry.latestApplied
        snapshot.latestSkipped = entry.latestSkipped
        snapshot.latestCanceled = entry.latestCanceled
        snapshot.latestFailed = entry.latestFailed
        snapshot.deferredNewer = entry.deferredNewer
        snapshot.lastLatest = entry.lastLatest
        return snapshot
    }
#endif

    private func invalidateCatalogs(_ entry: Entry) {
        entry.catalogVersion += 1
        entry.catalogs = nil
        entry.catalogReadAt = nil
        entry.commands = nil
        entry.catalogTask?.cancel()
        entry.catalogTask = nil
    }

    private func stop(_ entry: Entry) {
        entry.connectionID = UUID()
        entry.connectionTask?.cancel()
        entry.connectionTask = nil
        entry.healID = UUID()
        entry.healTask?.cancel()
        entry.healTask = nil
        entry.mismatchHealID = UUID()
        entry.mismatchHealTask?.cancel()
        entry.mismatchHealTask = nil
        // The follow-up reconcile belongs to the lifecycle too: its write-back
        // must not land after the stop (review F-I).
        entry.followUpReconcileID = UUID()
        entry.followUpReconcileTask?.cancel()
        entry.followUpReconcileTask = nil
        // Recovery identity belongs to the lifecycle, not to a socket
        // generation: rotating it here makes an in-flight round abandon its
        // results quietly, while a later start() runs a round of its own.
        entry.recoveryEpoch = UUID()
        entry.recoveryTask?.cancel()
        entry.recoveryTask = nil
        entry.latestRefreshTask?.cancel()
        entry.latestRefreshTask = nil
        // The newest-page fill belongs to the observed lifecycle too; it must
        // not keep polling a session nobody is looking at.
        entry.latestFillID = UUID()
        entry.latestFillTask?.cancel()
        entry.latestFillTask = nil
        entry.connection = .inactive
        // A stopped or disconnected entry cannot carry a live prediction: the
        // optimistic turn end belongs to the connection lifecycle that proved
        // it (red team F4).
        entry.predictedIdleSequence = nil
        entry.model.runtime.endPredictedIdle()
        entry.projection?.markStale()
        invalidateCatalogs(entry)
        emit(entry, persist: false)
    }

    private func dispose(_ entry: Entry) {
        stop(entry)
        entry.loadTask?.cancel()
        entry.historyTask?.cancel()
        entry.latestRefreshTask?.cancel()
        for observer in entry.observers.values { observer.finish() }
        entry.observers.removeAll()
        entry.model.invalidate()
    }

    private func evict(protecting protected: Entry? = nil) {
        let candidates = entries.values.filter {
            $0 !== protected && $0.observers.isEmpty && $0.loadTask == nil && $0.catalogTask == nil
                && $0.historyTask == nil && $0.latestRefreshTask == nil && $0.recoveryTask == nil
                && $0.followUpReconcileTask == nil && !$0.model.hasLocalWork
        }
            .sorted { $0.lastAccess < $1.lastAccess }
        for entry in candidates where entries.count > max(1, policy.maximumSessions) {
            entries.removeValue(forKey: entry.id)
            dispose(entry)
        }
    }
}

@MainActor
private final class Entry {
    let id: V2SessionID
    let model: V2SessionModel
    var needsSnapshot = false
    /// Set once a window read echoed `deferredActivity: false`, proving the
    /// server does not implement the deferred read. Process-local on purpose:
    /// a server upgrade is picked up by the next launch's single probe instead
    /// of needing a client update.
    var deferredWindowUnsupported = false
    var hasReadLocal = false
    var isDirty = false
    var emitScheduled = false
    var localReadTask: Task<V2SessionRestore?, Never>?
    var projection: V2SessionProjection?
    var connection = V2SessionConnectionState.inactive
    var error: V2ClientFailure?
    var lastAccess = 0
    var readVersion = 0
    var catalogVersion = 0
    var projectionBarrier = Date.distantPast
    /// The throttle anchor of the orb's stream pulse (OrbPulsePolicy). It only
    /// ever moves on the live receive path; recovery replay never touches it.
    var lastStreamPulseAt: Date?
    var connectionID = UUID()
    var observers: [UUID: AsyncStream<V2SessionObservation>.Continuation] = [:]
    var loadTask: Task<V2SessionData, Error>?
    var historyTask: Task<V2SessionData, Error>?
    /// A local-first latest page was applied and a network read is reconciling
    /// it in the background. Kept separate from `historyTask` so the instant
    /// local return does not make the caller wait on the network.
    var latestRefreshTask: Task<Void, Never>?
    /// Debounced, single-flight fill for a window that is behind the server
    /// while the reader is at the newest edge (see `scheduleLatestFill`).
    var latestFillTask: Task<Void, Never>?
    /// Non-zero while a direct latest read (the opening path) is on the wire;
    /// the fill stays out of its way instead of downloading the same page too.
    var latestReadInFlight = 0
    /// The local store restored this session's metadata but none of its rows
    /// (cache eviction). `open` answers it with the bounded snapshot.
    var restoredEmptyWindow = false
    /// Rotation key so a finishing fill only clears its own registration
    /// (a stop + observe can replace the task before its defer runs).
    var latestFillID = UUID()
#if AA_TIMELINE_PROBE
    /// Probe-only latest-page counters (see `V2TimelineWindowSnapshot`).
    var latestStarted = 0
    var latestApplied = 0
    var latestSkipped = 0
    var latestCanceled = 0
    var latestFailed = 0
    var deferredNewer = 0
    var lastLatest = "-"
#endif
    var catalogTask: Task<V2SessionCatalogs, Error>?
    /// Single-flight recovery round. It returns its outcome instead of
    /// throwing, so joining callers can choose to surface or ignore failure.
    var recoveryTask: Task<Error?, Never>?
    /// Rotated only by `stop()`; rounds capture it and refuse to apply results
    /// once it changes.
    var recoveryEpoch = UUID()
    /// Monotonic launch counter; the socket subscribe path requires a round
    /// launched after the frame it is closing.
    var recoverySequence = 0
    var recoveryTaskSequence = 0
    /// The recovery sequence in force when the optimistic turn end began, or
    /// nil with no prediction. Only a round launched after it may end the
    /// prediction (red team F4).
    var predictedIdleSequence: Int?
    /// Consecutive real recovery failures since the last successful round or
    /// snapshot rebuild (see `handleRecoveryFailure`).
    var recoveryFailureStreak = 0
    /// When the last snapshot rebuild was attempted; nil before the first. The
    /// frequency gate measures from attempts, not successes.
    var lastSnapshotRecoveryAt: Date?
    /// Successful snapshot rebuilds this entry has performed. It also numbers
    /// the disclosures, so a later rebuild is a new toast payload rather than
    /// a repeat the store would keep dismissed.
    var snapshotRecoveryCount = 0
    /// Newest-last ring of the failed rounds booked on this entry.
    var recoveryDiagnostics: [V2SessionRecoveryDiagnostic] = []
    /// The disclosure of the last successful rebuild — a rebuilt projection is
    /// user-visible state. One-shot: the session page clears it through
    /// `clearRecoveryNotice(sessionId:)` once shown, and a later rebuild
    /// replaces it with a fresh, higher-numbered value.
    var recoveryNotice: V2SessionRecoveryNotice?
    /// The notification-type notices this session has already acknowledged (see
    /// `V2NotificationAcknowledgements`). Persisted with the archive so the
    /// one-shot semantics survive a page rebuild and a relaunch.
    var acknowledgedNotifications = V2NotificationAcknowledgements()
    var connectionTask: Task<Void, Never>?
    /// The observed-session heal loop. Cancelled by `stop()`; the id lets a
    /// round that is ending clear its own registration only.
    var healTask: Task<Void, Never>?
    var healID = UUID()
    /// Debounced heal for a state/capability contradiction seen on a frame.
    var mismatchHealTask: Task<Void, Never>?
    var mismatchHealID = UUID()
    /// The post-write follow-up reconcile wrapper (see
    /// `launchFollowUpReconcile`). Cancelled by `stop()`; the id lets a
    /// wrapper clear its own registration only.
    var followUpReconcileTask: Task<Void, Never>?
    var followUpReconcileID = UUID()
    var catalogs: V2SessionCatalogs?
    var catalogScopes: Set<String>?
    var catalogReadAt: Date?
    var commands: [V2RuntimeCommand]?

    init(id: V2SessionID, model: V2SessionModel) { self.id = id; self.model = model }
}

private enum CacheError: LocalizedError, Equatable {
    case invalidated
    case superseded
    case connectionClosed

    var errorDescription: String? {
        switch self {
        case .invalidated: String(localized: "The session request no longer belongs to the active cache.")
        case .superseded: String(localized: "The session recovery was superseded by a newer connection lifecycle.")
        case .connectionClosed: String(localized: "The session connection closed.")
        }
    }
}

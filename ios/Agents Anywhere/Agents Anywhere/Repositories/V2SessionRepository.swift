import Foundation

nonisolated struct V2SessionCachePolicy {
    /// Sessions resident at once, sized to the recently active working set so
    /// returning to a session after a background or app switch is served from
    /// cache instead of the network. The local store's per-file (64MB) and
    /// total (128MB) budgets plus the LRU eviction below still bound disk use.
    var maximumSessions = 20
    var maximumTimelineItems = 1000
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
    private var entries: [V2SessionID: Entry] = [:]
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
        healBackoff: V2SessionHealBackoff = V2SessionHealBackoff()
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

    /// Returns cached durable content immediately. Observe to keep live facts fresh.
    func load(sessionId: V2SessionID) async throws -> V2SessionData {
        let entry = entry(for: sessionId)
        await restoreCachedSession(id: sessionId)
        try requireCurrent(entry)
        if let data = entry.projection?.data { return data }
        try requireNetwork()
        return try await hydrate(entry)
    }

    /// A page visit starts with the latest 100 records, including cached visits.
    /// Explicit history loads may then accumulate additional 100-record pages.
    func open(sessionId: V2SessionID) async throws -> V2SessionData {
        let entry = entry(for: sessionId)
        _ = try await load(sessionId: sessionId)
        try Task.checkCancellation()
        try requireCurrent(entry)
        entry.readVersion += 1
        entry.historyTask?.cancel()
        entry.historyTask = nil
        // Trim before a possible latest-page request so an offline fallback
        // also stays bounded and cannot remount the entire cached history.
        if entry.projection?.limitToLatest(100) == true { emit(entry) }
        if entry.projection?.data.hasNewerItems == true {
            return try await loadLatest(sessionId: sessionId, limit: 100)
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
            entry.localReadTask = Task { await localStore.session(id) }
        }
        let saved = await entry.localReadTask?.value
        guard isCurrent(entry), entry.projection == nil, !entry.hasReadLocal else { return }
        entry.hasReadLocal = true; entry.localReadTask = nil
        guard let saved, saved.session.id == id,
              let projection = try? saved.projection(maximumItems: policy.maximumTimelineItems, now: now) else { return }
        entry.projection = projection
        // A failure that outlived the process is still on record: the ring is
        // restored beside the projection it belongs to.
        entry.recoveryDiagnostics = saved.recoveryDiagnostics ?? []
        entry.model.restoreLocal(saved)
        emit(entry)
    }

    func flushCache() async {
        persistenceTask?.cancel(); persistenceTask = nil
        guard let localStore else { return }
        let values = entries.values.sorted { $0.lastAccess < $1.lastAccess }.compactMap { entry in
            entry.projection.map { projection in
                var archive = V2SessionArchive(data: projection.data, model: entry.model)
                archive.recoveryDiagnostics = entry.recoveryDiagnostics.isEmpty ? nil : entry.recoveryDiagnostics
                return archive
            }
        }
        for value in values { await localStore.saveSession(value) }
    }

    private func schedulePersistence() {
        guard localStore != nil, persistenceTask == nil else { return }
        persistenceTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
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

    func loadOlder(sessionId: V2SessionID, limit: Int = 100) async throws -> V2SessionData {
        try requireNetwork()
        _ = try await load(sessionId: sessionId)
        let entry = entry(for: sessionId)
        if let task = entry.historyTask { return try await task.value }
        guard let data = entry.projection?.data,
              data.hasOlderItems, let before = data.items.first?.orderSeq else {
            return entry.projection!.data
        }
        let version = entry.readVersion
        let task = Task { [self] in
            defer { if entry.readVersion == version { entry.historyTask = nil } }
            let page = try await detail.loadOlderItems(sessionId: sessionId, beforeOrderSeq: before, limit: limit)
            try requireCurrent(entry, version: version)
            entry.projection?.applyHistory(page)
            emit(entry)
            return entry.projection!.data
        }
        entry.historyTask = task
        return try await task.value
    }

    func loadLatest(sessionId: V2SessionID, limit: Int = 100) async throws -> V2SessionData {
        try requireNetwork()
        _ = try await load(sessionId: sessionId)
        let entry = entry(for: sessionId)
        entry.readVersion += 1
        entry.historyTask?.cancel()
        entry.historyTask = nil
        let version = entry.readVersion
        let page = try await detail.latestItems(sessionId: sessionId, limit: limit)
        try requireCurrent(entry, version: version)
        entry.projection?.applyLatest(page)
        emit(entry)
        return entry.projection!.data
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

    func draftDidChange() { schedulePersistence() }

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
        for session in sessions {
            guard let entry = entries[session.id] else { continue }
            let previous = entry.projection?.data.session
            entry.projection?.applyMeta(session)
            if session.connectorStatus != .online || previous?.effectiveRuntimeId != session.effectiveRuntimeId {
                invalidateCatalogs(entry)
            }
            emit(entry)
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
        for entry in entries.values { stop(entry); emit(entry) }
    }

    func resume() {
        suspended = false
        for entry in entries.values { start(entry, catchUp: true) }
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
            }
            emit(entry)
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
        let version = entry.readVersion
        let task = Task { [self] in
            defer {
                if entry.readVersion == version { entry.loadTask = nil }
                evict()
            }
            let snapshot = try await detail.load(sessionId: entry.id)
            try requireCurrent(entry, version: version)
            guard snapshot.session.id == entry.id else { throw CacheError.invalidated }
            entry.projection = V2SessionProjection(snapshot: snapshot, maximumItems: policy.maximumTimelineItems, now: now)
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
                    self.emit(entry)
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
                            self.emit(entry)
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
                        self.emit(entry)
                        return
                    }
                    entry.connection = .reconnecting
                    self.emit(entry)
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
        }
        let mergedOutcome = try entry.projection?.apply(event)
        confirmEchoes(event, entry: entry)
        if event.type == "runtime.catalog.updated" || entry.projection?.data.session.connectorStatus != .online {
            invalidateCatalogs(entry)
        }
        if event.type == "runtime.state.updated" || event.type == "runtime.capability.updated" {
            scheduleMismatchHeal(entry)
        }
        emit(entry)
        // The orb's receive pulse: only this live path consumes a merge
        // outcome — replay, snapshot, paging and cache restores never reach
        // this code, so nothing else can ring the orb (§6.3).
        if let merged = mergedOutcome {
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
                        try entry.projection?.apply(event)
                    } catch {
                        // The batch is all-or-nothing, so this event's position
                        // is the whole story of the stall: carry it out of the
                        // loop instead of losing it with the throw.
                        throw V2SessionRecoveryApplyFailure(event: event, fromCursor: cursor,
                                                            nextCursor: recovery.nextCursor, underlying: error)
                    }
                    confirmEchoes(event, entry: entry)
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
                             recoveryNotice: entry.recoveryNotice)
    }

    private func emit(_ entry: Entry) {
        guard isCurrent(entry) else { return }
        entry.model.update(observation(entry), network: network)
        for observer in entry.observers.values { observer.yield(observation(entry)) }
        schedulePersistence()
    }

    private func confirmEchoes(_ event: V2SessionEvent, entry: Entry) {
        if let raw = event.payload["item"],
           let data = try? JSONEncoder().encode(raw),
           let item = try? JSONDecoder().decode(V2TimelineItem.self, from: data) {
            entry.model.confirmEcho(item)
        }
    }

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
        entry.connection = .inactive
        // A stopped or disconnected entry cannot carry a live prediction: the
        // optimistic turn end belongs to the connection lifecycle that proved
        // it (red team F4).
        entry.predictedIdleSequence = nil
        entry.model.runtime.endPredictedIdle()
        entry.projection?.markStale()
        invalidateCatalogs(entry)
        emit(entry)
    }

    private func dispose(_ entry: Entry) {
        stop(entry)
        entry.loadTask?.cancel()
        entry.historyTask?.cancel()
        for observer in entry.observers.values { observer.finish() }
        entry.observers.removeAll()
        entry.model.invalidate()
    }

    private func evict(protecting protected: Entry? = nil) {
        let candidates = entries.values.filter {
            $0 !== protected && $0.observers.isEmpty && $0.loadTask == nil && $0.catalogTask == nil
                && $0.historyTask == nil && $0.recoveryTask == nil && $0.followUpReconcileTask == nil
                && !$0.model.hasLocalWork
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
    var hasReadLocal = false
    var localReadTask: Task<V2SessionArchive?, Never>?
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
    /// user-visible state. Sticky: it stays until a later rebuild replaces it,
    /// so a view that attaches later still sees the acknowledgement.
    var recoveryNotice: V2SessionRecoveryNotice?
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

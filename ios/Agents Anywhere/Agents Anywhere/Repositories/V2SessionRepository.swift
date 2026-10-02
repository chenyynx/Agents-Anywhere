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
        connectionReadinessWindow: Duration = .milliseconds(1500)
    ) {
        self.scope = scope
        self.detail = detail
        self.interactions = interactions
        self.policy = policy
        self.localStore = localStore
        self.now = now
        self.sleep = sleep
        self.connectionReadinessWindow = connectionReadinessWindow
    }

    /// Bound on how long a not-ready path delays one connection attempt.
    private static let readinessProbeInterval: Duration = .milliseconds(100)
    /// Retry delay while the path itself is not usable, instead of the longer
    /// transient backoff that a reachable server earns.
    private static let notReadyRetryDelay: Duration = .milliseconds(500)

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
        entry.projection = V2SessionProjection.placeholder(submission.session, maximumItems: policy.maximumTimelineItems)
        entry.model.stage(submission.pending)
        emit(entry)
    }

    func bindCreation(_ submission: NewSessionSubmission, response: V2SessionCreateResponse) {
        let entry = entry(for: response.session.id)
        if entry.projection == nil {
            entry.projection = V2SessionProjection.placeholder(response.session, maximumItems: policy.maximumTimelineItems)
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
              let projection = try? saved.projection(maximumItems: policy.maximumTimelineItems) else { return }
        entry.projection = projection
        entry.model.restoreLocal(saved)
        emit(entry)
    }

    func flushCache() async {
        persistenceTask?.cancel(); persistenceTask = nil
        guard let localStore else { return }
        let values = entries.values.sorted { $0.lastAccess < $1.lastAccess }.compactMap { entry in
            entry.projection.map { V2SessionArchive(data: $0.data, model: entry.model) }
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

    func interrupt(sessionId: V2SessionID) async throws {
        try requireNetwork()
        let entry = entry(for: sessionId)
        _ = try await detail.interrupt(sessionId: sessionId)
        try requireCurrent(entry)
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
        if let state { entry.projection?.applyState(state) }
        invalidateCatalogs(entry)
        emit(entry)
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
            entry.projection = V2SessionProjection(snapshot: snapshot, maximumItems: policy.maximumTimelineItems)
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
        try entry.projection?.apply(event)
        confirmEchoes(event, entry: entry)
        if event.type == "runtime.catalog.updated" || entry.projection?.data.session.connectorStatus != .online {
            invalidateCatalogs(entry)
        }
        emit(entry)
        if entry.projection?.data.session.connectorStatus == .online,
           !wasOnline || previousRuntime != entry.projection?.data.session.effectiveRuntimeId {
            try await reconcile(entry)
        }
    }

    private func reconcile(_ entry: Entry, requiringRoundAfter sequence: Int? = nil) async throws {
        if let error = await performRecovery(entry, requiringRoundAfter: sequence) { throw error }
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
            let outcome = await self.runRecovery(entry, epoch: epoch)
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
    /// The round never writes `entry.error`; it reports failure to its caller.
    /// The socket path surfaces it, the catch-up path ignores it.
    private func runRecovery(_ entry: Entry, epoch: UUID) async -> Error? {
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
                    try entry.projection?.apply(event)
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
                }
            }
            emit(entry)
            return nil
        } catch {
            return isSuperseded(error) ? nil : error
        }
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
        V2SessionObservation(sessionId: entry.id, data: entry.projection?.data, connection: entry.connection, error: entry.error)
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
        // Recovery identity belongs to the lifecycle, not to a socket
        // generation: rotating it here makes an in-flight round abandon its
        // results quietly, while a later start() runs a round of its own.
        entry.recoveryEpoch = UUID()
        entry.recoveryTask?.cancel()
        entry.recoveryTask = nil
        entry.connection = .inactive
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
                && $0.historyTask == nil && $0.recoveryTask == nil && !$0.model.hasLocalWork
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
    var connectionTask: Task<Void, Never>?
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

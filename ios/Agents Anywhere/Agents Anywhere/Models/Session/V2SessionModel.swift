import Foundation
import Observation

/// Stable row identity: streamed changes only invalidate the affected row's observable value.
@MainActor @Observable
final class V2TimelineItemModel: Identifiable {
    let id: V2TimelineItemID
    private(set) var value: V2TimelineItem

    init(_ value: V2TimelineItem) { id = value.id; self.value = value }
    func update(_ value: V2TimelineItem) { if self.value != value { self.value = value } }
}

@MainActor @Observable
final class V2SessionRuntimeModel {
    private(set) var state: V2RuntimeState?
    private(set) var capabilities: V2RuntimeCapabilitySnapshot?
    private(set) var notices: [V2RuntimeNotice] = []
    /// Functional gate: authoritative live facts are current. Freshness is
    /// proven by a live-state read — over the subscribed socket, or by the
    /// foreground REST catch-up, which reads the same facts — so the gate does
    /// not wait for the socket handshake and opens as soon as authoritative
    /// facts are applied. Every staleness mark (stop, connection failure,
    /// offline, takeover/respond writes) closes it exactly as before, and
    /// lifecycle states that cannot carry current facts are excluded, so the
    /// gate is only ever true while a live recovery owns the data.
    private(set) var isFresh = false
    /// Optimistic turn end after an accepted interrupt. The ack proves the
    /// runtime stopped the turn, but the frames that say so can be late or
    /// lost, so the composer gates read the post-stop turn-window shape until
    /// authoritative facts (or an explicit rollback) end the prediction. It
    /// never writes the projected state, never counts as an authoritative
    /// turn ending, and is only honoured while the projection is fresh.
    private(set) var predictedIdle = false
    /// Authoritative turn endings: transitions of the projected state from a
    /// turn in flight to `idle`, applied while live facts were fresh. The
    /// completion cue keys off this instead of a raw status edge so that a
    /// status no authoritative source ever confirmed (an optimistic
    /// prediction, a selection write response) cannot announce a completion.
    private(set) var authoritativeTurnEnds = 0

    func allows(_ id: V2CapabilityID) -> Bool {
        guard isFresh, let capability = capabilities?.capability(id: id) else { return false }
        guard capability.allowed else { return false }
        if predictedIdle, capability.supported {
            // The accepted stop already closed the turn window: report the
            // post-stop shape of the two complementary turn capabilities
            // (docs/api/capabilities.md) and leave every other capability —
            // and every unavailable runtime — exactly as the snapshot says.
            switch id {
            case "session.send_message": return true
            case "session.interrupt": return false
            default: break
            }
        }
        return capability.supported && capability.available
    }

    /// Whether the predicted idle is currently in force for composer gating.
    /// A prediction only gets to speak while the projection is fresh; once
    /// fresh facts stop flowing, the last authoritative state is the honest
    /// one (and the stop affordance stays reachable through its own gate).
    var isPredictedIdle: Bool { predictedIdle && isFresh }

    /// The stop affordance's gate. Interrupt is idempotent on the server —
    /// an already-finished turn answers 409 and is treated as success — so a
    /// stale projection must not turn a user's stop tap into a silent no-op:
    /// with a last-known supported, allowed capability the button stays live
    /// and every outcome lands on the existing error channel.
    func permitsInterruptAttempt() -> Bool {
        guard let capability = capabilities?.capability(id: "session.interrupt") else { return false }
        guard capability.supported, capability.allowed else { return false }
        return capability.available || !isFresh
    }

    func beginPredictedIdle() {
        guard !predictedIdle else { return }
        predictedIdle = true
    }

    /// Ends the prediction. Called when authoritative facts land (truth wins)
    /// and when the follow-up read fails (the optimistic value rolls back).
    func endPredictedIdle() {
        guard predictedIdle else { return }
        predictedIdle = false
    }

    func update(_ data: V2SessionData?, connection: V2SessionConnectionState) {
        let previousStatus = state?.status
        if state != data?.state { state = data?.state }
        if capabilities != data?.capabilities { capabilities = data?.capabilities }
        let notices = data?.notices ?? []
        if self.notices != notices { self.notices = notices }
        let carriesCurrentFacts: Bool
        switch connection {
        case .connected, .connecting, .reconnecting: carriesCurrentFacts = true
        case .inactive, .offline, .failed: carriesCurrentFacts = false
        }
        let fresh = data?.liveStateIsFresh == true && carriesCurrentFacts
        if isFresh != fresh { isFresh = fresh }
        if fresh, previousStatus?.isTurnInFlight == true, data?.state?.status == .idle {
            authoritativeTurnEnds += 1
        }
    }
}

@MainActor @Observable
final class V2PendingMessage: Identifiable {
    enum Delivery: Hashable {
        case sending, accepted, confirmed
        case uncertain(V2ClientFailure)
        case rejected(V2ClientFailure)
    }
    let id: String
    let content: String
    private(set) var attachmentIDs: [V2AttachmentID]
    let localAttachmentIDs: [String]
    private(set) var attachments: [ChatAttachment]
    private(set) var delivery: Delivery = .sending
    var didRestoreDraft = false
    /// Unresolved records this bubble replaces: the draft was restored from
    /// them and the user sent again (possibly after editing). They leave the
    /// timeline together with this record's confirming echo, so a successful
    /// retry cannot strand the old bubble at the tail forever.
    var supersededPendingIDs: [String] = []

    /// While true the write's outcome is unknown and no echo has arrived, so
    /// sending the identical draft again would risk a duplicate.
    var blocksRepeatSend: Bool {
        switch delivery {
        case .sending, .accepted, .uncertain: return true
        case .rejected, .confirmed: return false
        }
    }

    /// `rejected` records never reached the server and are safe to retire once
    /// the user resolves them by sending again; `uncertain` ones are the ghost
    /// this supersede chain exists for.
    var isSupersedable: Bool {
        switch delivery {
        case .uncertain, .rejected: return true
        case .sending, .accepted, .confirmed: return false
        }
    }

    init(id: String, content: String, attachmentIDs: [V2AttachmentID], localAttachmentIDs: [String] = [], attachments: [ChatAttachment] = []) {
        self.id = id; self.content = content; self.attachmentIDs = attachmentIDs
        self.localAttachmentIDs = localAttachmentIDs
        self.attachments = attachments
    }

    func bindUpload(_ file: V2AttachmentReference, localID: String) {
        guard let index = attachments.firstIndex(where: { $0.id == localID }) else { return }
        attachments[index].uploaded = file
        attachmentIDs = attachments.compactMap { $0.uploaded?.fileId }
    }

    func update(_ delivery: Delivery) {
        // An authoritative echo can arrive before the HTTP request completes or fails.
        guard self.delivery != .confirmed else { return }
        self.delivery = delivery
    }
}

/// SwiftUI owns a reference obtained from repository.session(id:). Use connect() in
/// a view .task; cancellation releases that view's subscription. DTOs never own I/O.
@MainActor @Observable
final class V2SessionModel: Identifiable {
    let id: V2SessionID
    let scope: V2ClientScope
    let runtime = V2SessionRuntimeModel()
    let notices = SessionNoticeStore()
    private(set) var metadata: V2SessionMeta?
    private(set) var timeline: [V2TimelineItemModel] = []
    private(set) var connection = V2SessionConnectionState.inactive
    private(set) var network = V2NetworkStatus()
    private(set) var failure: V2ClientFailure?
    /// The last self-heal disclosure the repository published: the session's
    /// data was rebuilt from a snapshot because the incremental recovery could
    /// not be applied. One-shot: the session page clears it via
    /// `clearRecoveryNotice()` once shown, so re-entering the page cannot replay
    /// it, while a later rebuild (a higher `snapshotRecoveryCount`) publishes a
    /// fresh value that opens again.
    private(set) var recoveryNotice: V2SessionRecoveryNotice?
    /// The notification-type notices this session has already acknowledged (see
    /// `V2NotificationAcknowledgements`). Carried on the observation beside the
    /// recovery disclosure so the one-shot filter reads durable state rather
    /// than the view-scoped toast store.
    private(set) var acknowledgedNotifications = V2NotificationAcknowledgements()
    private(set) var hasOlderItems = false
    private(set) var hasNewerItems = false
    /// Whether the window was read from a server that excluded SubAgent child
    /// rows (`excludeAgentChildren`). The SubAgent panel reads it: a card's own
    /// row being present says nothing about activity rows in such a window.
    private(set) var windowExcludesAgentChildren = false
    /// The projection's active SubAgent cards, mirroring the same field on
    /// `V2SessionData`. They are read beside the presented rows so the capsule
    /// does not depend on which part of the timeline the client holds.
    private(set) var activeAgentCards: [V2ActiveAgentCard] = []
    /// The newest pulse from the live receive path (a fresh id rings once);
    /// nil before the first arrival. The orb view drops it on its own when the
    /// pulse setting is off or Reduce Motion is on — the model never judges
    /// presentation.
    private(set) var incomingPulse: OrbPulse?
    private(set) var isLoading = false
    private(set) var isLoadingHistory = false
    private(set) var isValid = true
    var isPerformingAction = false
    private(set) var pendingMessages: [V2PendingMessage] = []
    private(set) var awaitingReplyID: String?
    /// Set when the composer's text came back from an unresolved send record;
    /// the next send from that draft replaces the record once it is confirmed.
    @ObservationIgnored private(set) var draftRestoredFromPendingID: String?
    /// The unresolved record that just made sendDraft/enqueueDraft a no-op.
    /// The chat layer reads it to explain the silence instead of swallowing
    /// the tap (2026-10-27: a user had to guess and delete a character before
    /// the message would leave).
    private(set) var blockedSendPendingID: String?
    /// The session's outbound queue: messages the user committed while a turn
    /// was running. Session-scoped like `pendingMessages`, so navigating away
    /// and back keeps it, and persisted with the archive so it survives a
    /// relaunch.
    let sendQueue = V2SendQueue()
    @ObservationIgnored private var queueDrainTask: Task<Void, Never>?
    /// When the current head entered `.awaitingEcho`. A drained message waits
    /// this long for its authoritative echo before the queue stops trusting the
    /// HTTP accept alone; see `awaitingEchoTimeout`.
    @ObservationIgnored private(set) var awaitingEchoSince: Date?
    let composer = ComposerDraft()
    let attachmentPreviews = ChatAttachmentStore()
    /// C3: the SubAgent panel's on-demand child rows and their offline cache.
    /// Session-scoped so it outlives the sheet, feeds the local archive, and
    /// keeps a cold offline launch from opening the panel on an empty body.
    let subAgentActivity: SubAgentActivityStore
    var draft: String {
        get { composer.text }
        set { composer.text = newValue }
    }
    var draftAttachmentIDs: [V2AttachmentID] = []
    @ObservationIgnored private weak var repository: V2SessionRepository?
    @ObservationIgnored private var rowsByID: [V2TimelineItemID: V2TimelineItemModel] = [:]

    init(id: V2SessionID, scope: V2ClientScope, repository: V2SessionRepository) {
        self.id = id; self.scope = scope; self.repository = repository
        // The repository holds this model through its entries; the closures
        // capture it weakly so the store cannot close that cycle. A completed
        // read marks the session dirty so the local archive picks the rows up.
        subAgentActivity = SubAgentActivityStore(
            fetch: { [weak repository] parentItemId, beforeOrderSeq in
                guard let repository else { throw CancellationError() }
                return try await repository.loadSubAgentChildren(
                    sessionId: id, parentItemId: parentItemId, beforeOrderSeq: beforeOrderSeq, limit: 100)
            },
            onCacheChanged: { [weak repository] in
                repository?.localWorkDidChange(sessionID: id)
            }
        )
        // An emptied editor means the user moved on: the restored draft is no
        // longer a retry of the unresolved record. This mirrors the archive,
        // which never persists provenance for an empty draft.
        composer.onTextBecameEmpty = { [weak self] in
            self?.draftRestoredFromPendingID = nil
        }
    }

    var canSend: Bool { isValid && runtime.allows("session.send_message") && !notices.notices.contains { $0.blocks(id) } }
    var hasLocalWork: Bool { !draft.isEmpty || !composer.attachments.isEmpty || !draftAttachmentIDs.isEmpty || !pendingMessages.isEmpty || notices.hasDraft || !sendQueue.items.isEmpty }

    // MARK: Send queue

    /// Whether the session may commit a draft to the queue at all. Unlike
    /// `canSend` this reads the capability's *support* and *permission*, not
    /// its availability: enqueuing is legal precisely when a *send* is not —
    /// that is the whole point of the queue.
    var permitsQueuedSend: Bool {
        guard runtime.isFresh, let send = runtime.capabilities?.capability(id: "session.send_message") else { return false }
        return send.supported && send.allowed
    }
    /// The queue is held when it was explicitly paused (a drain/retry failure)
    /// or when the network is down and there is something waiting.
    var isSendQueuePaused: Bool {
        sendQueue.explicitPause != nil || (network.availability == .offline && !sendQueue.isEmpty)
    }
    /// What the paused banner prints. An explicit failure wins over the derived
    /// offline reason, so a send that failed while the path was up still names
    /// its failure; a purely offline pause reads as a connection problem.
    var queuePauseForDisplay: V2SendQueuePause? {
        if let explicit = sendQueue.explicitPause { return explicit }
        if network.availability == .offline && !sendQueue.isEmpty { return .offline }
        return nil
    }

    /// Reads the composer (text + attachments) into a queued message, clears
    /// the composer, and flags the local work. Returns nil when there is
    /// nothing to queue. Attachments travel with the message; the eager upload
    /// is the caller's to start.
    @discardableResult func enqueueDraft() -> V2QueuedMessage? {
        blockedSendPendingID = nil
        guard isValid else { return nil }
        let content = draft
        let attachments = composer.attachments
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty else { return nil }
        // The queue is the other way a draft leaves the composer; it must
        // refuse the same unresolved duplicate the send path refuses.
        if let blocking = unresolvedPending(matching: content, localAttachmentIDs: composer.attachments.map(\.id)) {
            blockedSendPendingID = blocking.id
            return nil
        }
        let item = V2QueuedMessage(content: content, attachments: attachments)
        // Before `composer.clear()` below: the clear drops the provenance.
        item.supersededPendingIDs = takeSupersededPendingIDs()
        attachmentPreviews.remember(attachments, clientID: item.id)
        sendQueue.enqueue(item)
        composer.clear(); draftAttachmentIDs = []
        repository?.localWorkDidChange(sessionID: id)
        // A message committed as the turn ends must not wait for the next frame:
        // if every gate already stands open, the queue drains from here.
        evaluateSendQueue()
        return item
    }

    /// Drops a waiting message. A message already on the wire is past the point
    /// of a safe local withdrawal, so it is left alone (the UI greys the item).
    func withdrawQueuedMessage(id: String) {
        guard let item = sendQueue.items.first(where: { $0.id == id }), item.state == .queued else { return }
        sendQueue.remove(id: id)
        repository?.localWorkDidChange(sessionID: id)
        evaluateSendQueue()
    }

    /// Moves a waiting message back into the composer so it can be rewritten:
    /// the message leaves the queue and its text is appended to any draft
    /// already present (a fresh line), never overwriting it. Attachments merge
    /// in too. As with withdraw, only a still-`queued` item may be edited.
    func editQueuedMessage(id: String) {
        guard let item = sendQueue.items.first(where: { $0.id == id }), item.state == .queued else { return }
        sendQueue.remove(id: id)
        // The retry chain travels back with the text, so the next send from
        // this edited draft still retires the records the queued retry replaced.
        if let origin = item.supersededPendingIDs.first { draftRestoredFromPendingID = origin }
        if composer.text.isEmpty {
            draft = item.content
        } else {
            draft = composer.text + "\n" + item.content
        }
        composer.attachments.append(contentsOf: item.attachments)
        draftAttachmentIDs = composer.attachments.compactMap { $0.uploaded?.fileId }
        repository?.draftDidChange(sessionID: id)
        repository?.localWorkDidChange(sessionID: id)
        evaluateSendQueue()
    }

    /// Binds one eager upload to its queued message. Kept on the session so the
    /// chat layer never reaches into the message's storage directly.
    func bindQueueUpload(itemID: String, localID: String, file: V2AttachmentReference) {
        sendQueue.items.first { $0.id == itemID }?.bindUpload(file, localID: localID)
    }

    func localWorkDidChange() { repository?.localWorkDidChange(sessionID: id) }

    /// Cheap gate before spawning a drain: nothing to do, or still paused, and
    /// no task is started. Otherwise a single-flight drain runs in the
    /// background; `drainSendQueueIfPossible` is the testable core it calls.
    func evaluateSendQueue() {
        // A head whose echo never landed must not pin the queue forever, so the
        // staleness check runs before any guard that a stuck head would satisfy.
        demoteStaleAwaitingEcho(now: Date())
        guard isValid, !sendQueue.items.isEmpty, !isSendQueuePaused, queueDrainTask == nil else { return }
        // Only a waiting head is drainable; while one is on the wire the queue
        // is holding by design, so there is nothing to evaluate.
        guard sendQueue.head?.state == .queued else { return }
        queueDrainTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.queueDrainTask = nil }
            _ = await self.drainSendQueueIfPossible()
        }
    }

    /// A drained message waits this long for its echo. HTTP accepted the write,
    /// but only the echo proves the message reached the timeline; past the
    /// window the client stops waiting and hands the record to the existing
    /// uncertain-pending path (same shape a relaunch would produce), which
    /// keeps it visible and releasable instead of pinning the queue's head.
    static let awaitingEchoTimeout: TimeInterval = 60

    /// Demotes the head out of `.awaitingEcho` once its echo window has lapsed.
    /// - Parameter now: injectable so tests can drive the window without waiting.
    func demoteStaleAwaitingEcho(now: Date) {
        guard let since = awaitingEchoSince, now.timeIntervalSince(since) >= Self.awaitingEchoTimeout,
              let head = sendQueue.head, head.state == .awaitingEcho else { return }
        let pending = V2PendingMessage(id: head.id, content: head.content, attachmentIDs: head.attachmentIDs,
            localAttachmentIDs: head.attachments.map(\.id), attachments: head.attachments)
        // Same construction as a restored uncertain record, so the bubble, its
        // duplicate warning and the late-echo reconciliation all behave alike.
        let failure = V2ClientFailure(kind: .unavailable, message: String(localized: "上次发送的结果尚未确认，正在同步记录。请确认后再重试。"))
        pending.update(.uncertain(failure))
        attachmentPreviews.remember(head.attachments, clientID: head.id)
        pendingMessages.append(pending)
        awaitingEchoSince = nil
        if awaitingReplyID == head.id { awaitingReplyID = nil }
        sendQueue.remove(id: head.id)
        localWorkDidChange()
        evaluateSendQueue()
    }

    /// Sends the queue's head when every gate is open, then stops — the next
    /// message waits for this one's echo. Returns whether a send was issued.
    /// Deliberately avoids `sendDraft`: the queue row stands in for the pending
    /// bubble, and a failure must *not* refill the composer (the content is
    /// still in the queue), so this calls `repository.send` directly.
    @discardableResult func drainSendQueueIfPossible() async -> Bool {
        guard let repository, isValid, !Task.isCancelled else { return false }
        guard !sendQueue.items.isEmpty, !isSendQueuePaused else { return false }
        guard network.availability != .offline else { return false }
        guard runtime.isFresh, let status = runtime.state?.status, status == .idle || status == .error else { return false }
        guard canSend else { return false }
        guard let head = sendQueue.head, head.state == .queued, head.isUploadComplete else { return false }
        head.update(.sending)
        do {
            await repository.flushCache()
            guard isValid, head.state == .sending else { return false }
            // A cancelled drain (the session went away mid-flush) must not leave
            // the head marked as on-the-wire, or the queue would hold forever.
            guard !Task.isCancelled else { head.update(.queued); return false }
            // Set the placeholder link immediately before the write, so a frame
            // arriving during the flush cannot clear a promise not yet made.
            awaitingReplyID = head.id
            _ = try await repository.send(sessionId: id, content: head.content, attachmentIDs: head.attachmentIDs, clientMessageID: head.id)
            guard isValid else { return true }
            // The send is on the wire; the echo removes the row. Until then no
            // further message is drained, and this stamp arms the echo window.
            head.update(.awaitingEcho)
            awaitingEchoSince = Date()
            return true
        } catch {
            guard isValid else { return false }
            // A failure leaves the message queued and pauses the whole queue:
            // the banner is the only notice, and the only way back is retry.
            head.update(.queued)
            if awaitingReplyID == head.id { awaitingReplyID = nil }
            sendQueue.pause(.failure(V2ClientFailure(error).message))
            repository.localWorkDidChange(sessionID: id)
            return false
        }
    }

    func connect() async {
        guard let repository, isValid else { return }
        for await _ in repository.observe(sessionId: id) {
            if Task.isCancelled { break }
        }
    }

    func load() async {
        guard let repository, isValid, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do { _ = try await repository.load(sessionId: id); if isValid { failure = nil } }
        catch { if isValid { failure = V2ClientFailure(error) } }
    }

    func refresh() async {
        guard let repository, isValid, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do { _ = try await repository.refresh(sessionId: id); if isValid { failure = nil } }
        catch { if isValid { failure = V2ClientFailure(error) } }
    }

    func loadOlder() async {
        guard let repository, isValid, !isLoadingHistory else { return }
        isLoadingHistory = true
        defer { isLoadingHistory = false }
        do { _ = try await repository.loadOlder(sessionId: id) }
        catch { if isValid { failure = V2ClientFailure(error) } }
    }

    func loadLatest() async {
        guard let repository, isValid, !isLoadingHistory else { return }
        isLoadingHistory = true
        defer { isLoadingHistory = false }
        do { _ = try await repository.loadLatest(sessionId: id) }
        catch { if isValid { failure = V2ClientFailure(error) } }
    }

    /// Explicit user action only. No outbox replay: clientMessageId correlates an echo
    /// but is not a promise of backend idempotency.
    @discardableResult func sendDraft(upload: ((V2PendingMessage) async throws -> Void)? = nil) async -> V2PendingMessage? {
        blockedSendPendingID = nil
        guard let repository, canSend else {
            failure = V2ClientFailure(kind: .unavailable, message: String(localized: "Wait for the session to reconnect before sending."))
            return nil
        }
        let content = draft
        let attachments = draftAttachmentIDs
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty || !composer.attachments.isEmpty else {
            failure = V2ClientFailure(V2BusinessError.emptyMessage)
            return nil
        }
        // Avoid a repeated tap while this exact draft's outcome remains unresolved.
        if let blocking = unresolvedPending(matching: content, localAttachmentIDs: composer.attachments.map(\.id)) {
            blockedSendPendingID = blocking.id
            return nil
        }
        let pending = V2PendingMessage(id: UUID().uuidString, content: content, attachmentIDs: attachments,
                                      localAttachmentIDs: composer.attachments.map(\.id), attachments: composer.attachments)
        // Before `composer.clear()` below: the clear drops the provenance.
        pending.supersededPendingIDs = takeSupersededPendingIDs()
        attachmentPreviews.remember(pending.attachments, clientID: pending.id)
        pendingMessages.append(pending); awaitingReplyID = pending.id
        // Commit the local bubble and release the editor immediately. A failed
        // write restores this snapshot only if the user has not started a new draft.
        composer.clear(); draftAttachmentIDs = []
        repository.localWorkDidChange(sessionID: id)
        var didSubmit = false
        do {
            try await upload?(pending)
            guard isValid, !Task.isCancelled else { throw CancellationError() }
            attachmentPreviews.remember(pending.attachments, clientID: pending.id)
            // The staged bubble must be durable before the request leaves, but
            // only this session's archive needs writing, not every cached one.
            await repository.flushCache(sessionID: id)
            guard isValid, !Task.isCancelled else { throw CancellationError() }
            didSubmit = true
            _ = try await repository.send(sessionId: id, content: content, attachmentIDs: pending.attachmentIDs, clientMessageID: pending.id)
            guard isValid else { return pending }
            pending.update(.accepted)
            clearDraft(ifMatching: pending)
        } catch {
            guard isValid else { return pending }
            if awaitingReplyID == pending.id { awaitingReplyID = nil }
            let failure = V2ClientFailure(error)
            pending.update(!didSubmit || V2ClientFailure.isDefiniteWriteRejection(error) ? .rejected(failure) : .uncertain(failure))
            if pending.delivery == .confirmed { clearDraft(ifMatching: pending) }
            else {
                self.failure = failure
                if draft.isEmpty && composer.attachments.isEmpty && !composer.isComposing {
                    draft = pending.content; composer.attachments = pending.attachments; draftAttachmentIDs = pending.attachmentIDs
                    pending.didRestoreDraft = true
                    draftRestoredFromPendingID = pending.id
                }
            }
        }
        repository.localWorkDidChange(sessionID: id)
        return pending
    }

    /// An explicit UI action may dismiss a reviewed outcome; it never resends it.
    func dismissPendingMessage(id: String) {
        pendingMessages.removeAll { $0.id == id && $0.delivery != .sending }
        if draftRestoredFromPendingID == id { draftRestoredFromPendingID = nil }
        repository?.localWorkDidChange(sessionID: self.id)
    }

    /// The unresolved record that makes sending this exact draft again unsafe.
    /// A definite rejection never blocks: the user already knows it failed and
    /// retrying is the intended next step.
    ///
    /// The identity is the text plus the composer's *local* attachment ids.
    /// Server-side ids cannot answer this: `draftAttachmentIDs` only tracks
    /// completed uploads and is not updated when the composer adds or removes
    /// an attachment, so comparing it would both miss real duplicates and block
    /// a message the user just changed.
    private func unresolvedPending(matching content: String, localAttachmentIDs: [String]) -> V2PendingMessage? {
        pendingMessages.first {
            $0.content == content
                && $0.localAttachmentIDs == localAttachmentIDs
                && $0.blocksRepeatSend
        }
    }

    /// Consumes the restore provenance for the send about to start. The chain
    /// travels with the new record, so confirming it retires every record the
    /// user already resolved by re-sending — including the edited-retry case
    /// where the text no longer matches the record exactly.
    ///
    /// Contract: callers consume this **before** `composer.clear()`, because
    /// that clear fires `onTextBecameEmpty` and drops the provenance. An
    /// emptied editor abandons the retry (see the callback in `init`); an edit
    /// that replaces the whole text without passing through empty still counts
    /// as a retry and keeps the provenance — a declared tradeoff, since the
    /// alternative (comparing text similarity) invents a rule the user cannot
    /// see.
    private func takeSupersededPendingIDs() -> [String] {
        guard let origin = draftRestoredFromPendingID else { return [] }
        draftRestoredFromPendingID = nil
        guard let record = pendingMessages.first(where: { $0.id == origin }), record.isSupersedable else {
            return []
        }
        return [origin] + record.supersededPendingIDs
    }

    func update(_ observation: V2SessionObservation, network: V2NetworkStatus) {
        guard isValid else { return }
        let data = observation.data
        if metadata != data?.session { metadata = data?.session }
        if connection != observation.connection { connection = observation.connection }
        if self.network != network { self.network = network }
        if failure != observation.error { failure = observation.error }
        if recoveryNotice != observation.recoveryNotice { recoveryNotice = observation.recoveryNotice }
        if acknowledgedNotifications != observation.acknowledgedNotifications {
            acknowledgedNotifications = observation.acknowledgedNotifications
        }
        runtime.update(data, connection: connection)
        notices.update(runtime.notices, sessionID: id)
        if hasOlderItems != (data?.hasOlderItems ?? false) { hasOlderItems = data?.hasOlderItems ?? false }
        if hasNewerItems != (data?.hasNewerItems ?? false) { hasNewerItems = data?.hasNewerItems ?? false }
        if windowExcludesAgentChildren != (data?.windowExcludesAgentChildren ?? false) {
            windowExcludesAgentChildren = data?.windowExcludesAgentChildren ?? false
        }
        let activeCards = data?.activeAgentCards ?? []
        if activeAgentCards != activeCards { activeAgentCards = activeCards }
        // A streamed token updates one existing row. Keep the id index across
        // ticks and only republish the array when membership or order changed.
        let items = data?.items ?? []
        var rows: [V2TimelineItemModel] = []
        rows.reserveCapacity(items.count)
        var orderChanged = items.count != timeline.count
        for (index, item) in items.enumerated() {
            let row: V2TimelineItemModel
            if let existing = rowsByID[item.id] {
                row = existing
                existing.update(item)
            } else {
                row = V2TimelineItemModel(item)
                rowsByID[item.id] = row
            }
            if !orderChanged, timeline[index] !== row { orderChanged = true }
            rows.append(row)
        }
        if orderChanged {
            timeline = rows
            rowsByID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        }
        // Reconcile authoritative echoes against both the optimistic bubbles and
        // the send queue. A queued message in flight has a sendQueue row but no
        // pending bubble, so gating on `pendingMessages` alone would skip a
        // queue echo that only arrives through a bulk read (hydrate / reconnect
        // catch-up / paging) and leave the head stuck until the stale timeout.
        if !pendingMessages.isEmpty || !sendQueue.items.isEmpty {
            for item in items { confirmEcho(item) }
        }
        if let id = awaitingReplyID, let data {
            let agentStarted = data.liveStateIsFresh && [.running, .waiting, .pending, .error].contains(data.state?.status ?? .unknown)
            let user = data.items.first { $0.role == .user && $0.source["clientMessageId"]?.stringValue == id }
            let hasReply = user.map { user in data.items.contains { $0.orderSeq > user.orderSeq && $0.role != .user && $0.type != .turnStart } } ?? false
            if agentStarted || hasReply { awaitingReplyID = nil }
        }
        // Live facts or a fresh timeline may have opened every drain gate; the
        // queue takes its turn here rather than on a timer.
        evaluateSendQueue()
    }

    /// Acknowledges the self-heal disclosure after the view has shown it. The
    /// notice is one-shot: clearing the model field — and, through the
    /// repository, the entry behind it — means re-entering the session page
    /// does not replay a notice already disclosed, while
    /// `snapshotRecoveryCount` keeps counting so a later rebuild still
    /// publishes a fresh, higher-numbered payload that opens once more.
    func clearRecoveryNotice() {
        recoveryNotice = nil
        repository?.clearRecoveryNotice(sessionId: id)
    }

    /// Records a notification as acknowledged within its current open episode
    /// once the user has closed its toast. The notice is one-shot per episode:
    /// writing the id through to the repository means re-entering the session
    /// page — or relaunching — cannot replay a notice already closed in this
    /// episode, while the next episode at the same id surfaces once more (the
    /// acknowledgement is dropped when the notice leaves the open set).
    func acknowledgeNotification(noticeId: String) {
        repository?.acknowledgeNotification(sessionId: id, noticeId: noticeId)
    }

    func confirmEcho(_ item: V2TimelineItem) {
        guard item.sessionId == id, item.type == .message, item.role == .user,
              let clientID = item.source["clientMessageId"]?.stringValue else { return }
        if let pending = pendingMessages.first(where: { $0.id == clientID }) {
            pending.update(.confirmed)
            clearDraft(ifMatching: pending)
            let superseded = Set(pending.supersededPendingIDs)
            pendingMessages.removeAll { $0.id == clientID || superseded.contains($0.id) }
        }
        // A queued message reconciles the same way: the authoritative echo
        // removes its row (the rest slide up) and releases the next message.
        if let queued = sendQueue.items.first(where: { $0.id == clientID }) {
            let superseded = Set(queued.supersededPendingIDs)
            if !superseded.isEmpty {
                pendingMessages.removeAll { superseded.contains($0.id) }
            }
            sendQueue.remove(id: clientID)
            awaitingEchoSince = nil
            if awaitingReplyID == clientID { awaitingReplyID = nil }
            localWorkDidChange()
        }
    }

    /// Publishes one live receive pulse. Every call carries a fresh id; two
    /// calls in the same render cycle may coalesce, so the orb sees the newest
    /// pulse of the batch rather than one animation per arrival.
    func noteIncomingPulse(_ pulse: OrbPulse) {
        incomingPulse = pulse
    }

    var isLocalCreation: Bool { id.hasPrefix("local:") }
    func stage(_ pending: V2PendingMessage) {
        guard isValid, !pendingMessages.contains(where: { $0.id == pending.id }) else { return }
        pendingMessages.append(pending)
        attachmentPreviews.remember(pending.attachments, clientID: pending.id)
        repository?.localWorkDidChange(sessionID: id)
    }
    func restoreDraft(from pending: V2PendingMessage) -> Bool {
        guard isValid else { return false }
        // "Return to editing" is also offered while the failed send's own
        // payload sits in the editor (its usual state); refusing that case
        // leaves the button dead for the record it belongs to.
        let sameAsRecord = composer.text == pending.content
            && composer.attachments.map(\.id) == pending.localAttachmentIDs
        guard composer.text.isEmpty || sameAsRecord else { return false }
        draft = pending.content; composer.attachments = pending.attachments; draftAttachmentIDs = pending.attachmentIDs
        pending.didRestoreDraft = true
        draftRestoredFromPendingID = pending.id
        composer.isFocused = true
        repository?.draftDidChange(sessionID: id)
        return true
    }

    func restoreLocal(_ archive: V2SessionArchive, subAgentActivity cachedActivity: [String: [V2TimelineItem]] = [:]) {
        // The activity cache is read-only content, independent of the
        // local-work guard below: seed it even when a draft or queue write
        // raced the disk read, so the panel can show it offline. The rows are
        // already decoded by the store actor.
        if !cachedActivity.isEmpty { subAgentActivity.restore(cachedActivity) }
        guard isValid, !hasLocalWork else { return }
        if let previews = archive.previews { attachmentPreviews.restore(previews) }
        draft = archive.draft; composer.attachments = archive.draftAttachments
        draftAttachmentIDs = archive.draftAttachments.compactMap { $0.uploaded?.fileId }
        pendingMessages = archive.pending.map { value in
            let pending = V2PendingMessage(id: value.id, content: value.content, attachmentIDs: value.attachmentIDs,
                localAttachmentIDs: value.attachments.map(\.id), attachments: value.attachments)
            let failure = V2ClientFailure(kind: .unavailable, message: value.error ?? String(localized: "上次发送的结果尚未确认，正在同步记录。请确认后再重试。"))
            pending.update(value.rejected ? .rejected(failure) : .uncertain(failure))
            pending.supersededPendingIDs = value.superseded ?? []
            attachmentPreviews.remember(value.attachments, clientID: value.id)
            return pending
        }
        // A draft that came back from an unresolved record keeps its retry
        // provenance across the relaunch, so the edited retry still retires the
        // record once its echo lands. An emptied draft means the user moved on.
        draftRestoredFromPendingID = archive.draft.isEmpty ? nil : archive.draftOriginPendingID
        // Only never-submitted messages are stored as `queued` (see the archive
        // assembly): restoring them re-arms the queue, which is legal because a
        // queued item was never sent, so no unconfirmed write is being replayed.
        if let queued = archive.queued {
            for value in queued { attachmentPreviews.remember(value.attachments, clientID: value.id) }
            sendQueue.replaceAll(queued.map { value in
                let item = V2QueuedMessage(id: value.id, content: value.content,
                    attachments: value.attachments, state: .queued)
                item.supersededPendingIDs = value.superseded ?? []
                return item
            })
        }
    }

    func invalidate() {
        runtime.update(nil, connection: .inactive)
        queueDrainTask?.cancel(); queueDrainTask = nil
        awaitingEchoSince = nil
        sendQueue.replaceAll([])
        metadata = nil; timeline = []; rowsByID = [:]; pendingMessages = []; awaitingReplyID = nil; draft = ""; draftAttachmentIDs = []
        draftRestoredFromPendingID = nil; blockedSendPendingID = nil
        activeAgentCards = []; recoveryNotice = nil; acknowledgedNotifications = V2NotificationAcknowledgements()
        composer.invalidate()
        attachmentPreviews.clear()
        subAgentActivity.cancel()
        notices.clear()
        connection = .inactive; isValid = false; repository = nil
    }

    /// The original bytes of an attachment still held locally — an optimistic
    /// send in flight, or a message waiting in the queue. The projection only
    /// carries the `local:` file id (no `openUrl`), so a bubble tap on such an
    /// image cannot reach the server; the full-resolution data lives on the
    /// pending/queued `ChatAttachment` and this is the bridge back to it.
    /// Matching is by the content's `fileId`, exactly the `local:<uuid>` the
    /// store minted; nil once the upload bound a server id (the content's
    /// fileId is then `file_…`) or when nothing local matches.
    func localImageData(for content: V2AttachmentContent) -> Data? {
        guard let fileId = content.fileId, fileId.hasPrefix("local:") else { return nil }
        if let data = pendingMessages.lazy.compactMap({ message in
            message.attachments.first { "local:\($0.id)" == fileId }?.data
        }).first { return data }
        return sendQueue.items.lazy.compactMap { item in
            item.attachments.first { "local:\($0.id)" == fileId }?.data
        }.first
    }

    /// The routing decision for a bubble tap on an attachment: an image whose
    /// original is still held locally (no `openUrl` yet, and local bytes in
    /// hand) opens the instant viewer straight on those bytes. Returns nil for
    /// everything else — non-images, uploaded images with a URL, and local
    /// images nothing matches — so the caller falls through to the existing
    /// paths. A pure predicate so the view and its tests read the same rule.
    func localImageRoute(for content: V2AttachmentContent) -> Data? {
        guard content.isImage, content.openUrl == nil else { return nil }
        return localImageData(for: content)
    }

    private func clearDraft(ifMatching pending: V2PendingMessage) {
        if pending.didRestoreDraft, draft == pending.content && draftAttachmentIDs == pending.attachmentIDs,
           composer.attachments.map(\.id) == pending.localAttachmentIDs {
            composer.clear(); draftAttachmentIDs = []
        }
    }
}

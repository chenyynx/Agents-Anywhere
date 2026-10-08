import Foundation
import Testing
@testable import ClientCore

/// The outbound send queue: what happens to a message the user commits while a
/// turn is running (`.local-dev/send-queue-tasks.md`).
///
/// The gates the drain reads — freshness, turn status, capability availability,
/// network — are driven through the session's own runtime model, and the send
/// itself goes out over the shared `TestHTTPTransport`. Enqueuing while a turn
/// runs keeps the queue dormant, so a test drives the release itself: either by
/// waiting on the observable outcome (`eventually`) when either the session's
/// own evaluation or a direct drain may issue the send, or by calling the drain
/// directly when only a "nothing was sent" fact is being asserted.
@Suite @MainActor struct SendQueueTests {
    /// The realtime double is built in the body, not as a default argument: a
    /// default is checked in a nonisolated context, and `TestRealtimeAPI` is
    /// main-actor isolated.
    private func makeSession(_ http: TestHTTPTransport, realtime: TestRealtimeAPI? = nil)
        -> (V2SessionRepository, V2SessionModel) {
        let repo = repository(transport: http, realtime: realtime ?? TestRealtimeAPI())
        return (repo, repo.session(id: "session"))
    }

    private func makeChat(_ model: V2SessionModel, _ repo: V2SessionRepository, _ http: TestHTTPTransport) -> SessionChatModel {
        SessionChatModel(session: model, repository: repo, attachments: .init(attachmentAPI: V2AttachmentAPI(transport: http)))
    }

    /// Pushes one set of authoritative live facts (freshness, turn status,
    /// capability shape) onto the session, exactly as a live-state frame would.
    /// Applied through the runtime model directly, so it never itself triggers
    /// a queue evaluation — the release stays the test's to perform.
    ///
    /// Mind the mirror image: a local write (`repository.localWorkDidChange`)
    /// emits an observation built from this suite's empty repository entry, and
    /// that resets these injected facts. Re-apply them after any such write that
    /// precedes another drain.
    private func applyLive(_ model: V2SessionModel, status: V2RuntimeStatus, sendAvailable: Bool = true,
                           sendSupported: Bool = true, sendAllowed: Bool = true, fresh: Bool = true) throws {
        var raw = try fixtureObject("snapshot")
        var state = raw["state"] as! [String: Any]
        state["status"] = status.rawValue
        raw["state"] = state
        raw["effectiveCapabilities"] = [
            "capabilities": [[
                "allowed": sendAllowed, "available": sendAvailable,
                "capabilityId": "session.send_message", "parameters": [:],
                "runtime": "claude", "runtimeId": "rti_work", "scope": "runtime",
                "sessionId": NSNull(), "supported": sendSupported,
                "unavailableReason": NSNull(), "version": "1"]],
            "revision": 10,
        ]
        var data = V2SessionData(snapshot: try decode(raw))
        data.liveStateIsFresh = fresh
        data.notices = []
        model.runtime.update(data, connection: .connected)
    }

    /// Enqueues while a turn is running, so the queue stays dormant and the
    /// test owns the release.
    @discardableResult
    private func enqueueWhileRunning(_ model: V2SessionModel, _ text: String) throws -> V2QueuedMessage {
        try applyLive(model, status: .running, sendAvailable: false)
        model.draft = text
        return try #require(model.enqueueDraft())
    }

    private func echo(clientID: String) throws -> V2TimelineItem {
        try decode(itemObject(clientID: clientID), as: V2TimelineItem.self)
    }

    // MARK: - Enqueue

    @Test func enqueueCommitsTheDraftToTheQueueAndClearsTheComposer() throws {
        let http = TestHTTPTransport()
        let (repo, model) = makeSession(http)
        defer { repo.reset() }
        let item = try enqueueWhileRunning(model, "queued while running")
        #expect(item.content == "queued while running")
        #expect(model.draft.isEmpty)
        #expect(model.sendQueue.count == 1)
        #expect(model.sendQueue.head?.state == .queued)
        #expect(model.sendQueue.head?.isUploadComplete == true)
        // Nothing is sent: the turn is still running.
        #expect(http.count("messages") == 0)
    }

    @Test func emptyDraftEnqueuesNothing() throws {
        let http = TestHTTPTransport()
        let (repo, model) = makeSession(http)
        defer { repo.reset() }
        try applyLive(model, status: .running, sendAvailable: false)
        model.draft = "   "
        #expect(model.enqueueDraft() == nil)
        #expect(model.sendQueue.isEmpty)
    }

    @Test func queueCapabilityIgnoresAvailabilityButNotSupport() throws {
        let http = TestHTTPTransport()
        let (repo, model) = makeSession(http)
        defer { repo.reset() }
        // A running turn reports send *unavailable* yet still supported and
        // allowed — exactly the window the queue exists for.
        try applyLive(model, status: .running, sendAvailable: false)
        #expect(model.permitsQueuedSend)
        #expect(!model.canSend)
        // A runtime that does not support the capability at all refuses both.
        try applyLive(model, status: .running, sendAvailable: false, sendSupported: false)
        #expect(!model.permitsQueuedSend)
        #expect(!model.canSend)
    }

    // MARK: - Drain (FIFO, single flight, echo)

    @Test func drainSendsOneAtATimeAndWaitsForTheEchoBeforeTheNext() async throws {
        let http = TestHTTPTransport()
        let (repo, model) = makeSession(http)
        defer { repo.reset() }
        let first = try enqueueWhileRunning(model, "first")
        model.draft = "second"
        let second = try #require(model.enqueueDraft())
        #expect(model.sendQueue.items.map(\.content) == ["first", "second"])

        // The turn ends; the release issues exactly one message (single flight),
        // no matter whether the session's own evaluation or the drain runs it.
        try applyLive(model, status: .idle, sendAvailable: true)
        model.evaluateSendQueue()
        try await eventually { first.state == .awaitingEcho }
        #expect(model.sendQueue.count == 2)
        #expect(http.count("messages") == 1)
        #expect(second.state == .queued)

        // The message on the wire holds the queue: nothing else goes out.
        #expect(await model.drainSendQueueIfPossible() == false)
        #expect(http.count("messages") == 1)

        // The echo removes the first row and opens the next message; the
        // session's own evaluation (as an arriving frame would run) drains it.
        model.confirmEcho(try echo(clientID: first.id))
        #expect(model.sendQueue.items.map(\.id) == [second.id])
        // Confirming is a local write, and a local write emits an empty-data
        // observation; the injected live facts need re-asserting before the
        // released head can pass the idle gate.
        try applyLive(model, status: .idle, sendAvailable: true)
        model.evaluateSendQueue()
        try await eventually { http.count("messages") == 2 }
        model.confirmEcho(try echo(clientID: second.id))
        #expect(model.sendQueue.isEmpty)
    }

    @Test func drainWaitsForAuthorityItCannotFabricate() async throws {
        let http = TestHTTPTransport()
        let (repo, model) = makeSession(http)
        defer { repo.reset() }
        try enqueueWhileRunning(model, "held")
        #expect(await model.drainSendQueueIfPossible() == false)
        #expect(http.count("messages") == 0)

        // Idle but the projection is stale: the send gate stays closed.
        try applyLive(model, status: .idle, sendAvailable: true, fresh: false)
        #expect(await model.drainSendQueueIfPossible() == false)
        #expect(http.count("messages") == 0)
    }

    @Test func stopDoesNotPauseTheQueueAndTheIdleTurnReleasesIt() async throws {
        let http = TestHTTPTransport()
        let (repo, model) = makeSession(http)
        defer { repo.reset() }
        try enqueueWhileRunning(model, "survives the stop")
        #expect(await model.drainSendQueueIfPossible() == false)

        // The post-stop shape: an authoritative idle turn. Nothing paused the
        // queue in between — a stop only ends the turn, never the queue.
        try applyLive(model, status: .idle, sendAvailable: true)
        #expect(!model.isSendQueuePaused)
        #expect(model.sendQueue.explicitPause == nil)
        #expect(await model.drainSendQueueIfPossible())
        #expect(http.count("messages") == 1)
    }

    @Test func echoReconcilesAQueuedMessageWithoutAPendingBubble() async throws {
        let http = TestHTTPTransport()
        let (repo, model) = makeSession(http)
        defer { repo.reset() }
        let item = try enqueueWhileRunning(model, "hello")
        try applyLive(model, status: .idle, sendAvailable: true)
        #expect(await model.drainSendQueueIfPossible())
        // The queue row stands in for the pending bubble; no pending is built.
        #expect(model.pendingMessages.isEmpty)
        model.confirmEcho(try echo(clientID: item.id))
        #expect(model.sendQueue.isEmpty)
        #expect(model.awaitingReplyID == nil)
    }

    @Test func aLostEchoDemotesTheHeadToAnUncertainPendingAndReleasesTheQueue() async throws {
        let http = TestHTTPTransport()
        let (repo, model) = makeSession(http)
        defer { repo.reset() }
        let first = try enqueueWhileRunning(model, "first")
        model.draft = "second"
        let second = try #require(model.enqueueDraft())
        try applyLive(model, status: .idle, sendAvailable: true)
        #expect(await model.drainSendQueueIfPossible())
        #expect(first.state == .awaitingEcho)
        #expect(model.awaitingEchoSince != nil)

        // Inside the echo window the queue keeps waiting: HTTP alone is not
        // proof the message reached the timeline.
        model.demoteStaleAwaitingEcho(now: Date())
        #expect(first.state == .awaitingEcho)
        #expect(model.sendQueue.items.map(\.id) == [first.id, second.id])

        // The echo never lands. Past the window the head is handed to the
        // uncertain-pending path — visible, releasable, never re-sent — and the
        // queue moves on instead of staying pinned forever.
        model.demoteStaleAwaitingEcho(now: Date().addingTimeInterval(V2SessionModel.awaitingEchoTimeout + 1))
        #expect(model.sendQueue.items.map(\.id) == [second.id])
        #expect(model.awaitingEchoSince == nil)
        guard case .uncertain = model.pendingMessages.first?.delivery else {
            Issue.record("A stale in-flight message must surface as an uncertain pending"); return
        }
        #expect(model.pendingMessages.first?.id == first.id)
        #expect(model.draft.isEmpty)

        // The demotion is a local write whose emit resets the injected facts;
        // re-assert them so the released head can pass the idle gate.
        try applyLive(model, status: .idle, sendAvailable: true)
        model.evaluateSendQueue()
        try await eventually { http.count("messages") == 2 }
    }

    // MARK: - Failure, pause, retry

    @Test func aFailedSendKeepsTheHeadQueuedAndPausesTheQueueWithTheBannerCopy() async throws {
        let http = TestHTTPTransport()
        let (repo, model) = makeSession(http)
        defer { repo.reset() }
        let item = try enqueueWhileRunning(model, "boom")
        try applyLive(model, status: .idle, sendAvailable: true)
        http.respond = { call in
            if call.path.hasSuffix("messages") { throw URLError(.timedOut) }
            return try http.defaultResponse(call)
        }
        #expect(await model.drainSendQueueIfPossible() == false)
        // The message stays queued; the failure never becomes a pending bubble
        // nor refills the composer (the content is still in the queue).
        #expect(model.sendQueue.count == 1)
        #expect(item.state == .queued)
        #expect(model.pendingMessages.isEmpty)
        #expect(model.draft.isEmpty)
        #expect(model.isSendQueuePaused)
        guard case .failure = model.queuePauseForDisplay else { Issue.record("A failed send must surface as a failure pause"); return }
        // No second attempt is made once paused.
        #expect(await model.drainSendQueueIfPossible() == false)
        #expect(http.count("messages") == 1)
    }

    @Test func retryClearsThePauseAndDrainsTheHeldHead() async throws {
        let http = TestHTTPTransport()
        let (repo, model) = makeSession(http)
        let chat = makeChat(model, repo, http)
        defer { repo.reset() }
        try enqueueWhileRunning(model, "retry me")
        try applyLive(model, status: .idle, sendAvailable: true)
        http.respond = { call in
            if call.path.hasSuffix("messages") { throw URLError(.timedOut) }
            return try http.defaultResponse(call)
        }
        #expect(await model.drainSendQueueIfPossible() == false)
        #expect(model.isSendQueuePaused)

        http.respond = nil
        // The retry clears the pause and re-evaluates, but its own local write
        // emits an empty-data observation that resets the injected facts, so
        // the drain it evaluates stands down (production emits carry the real
        // projection and do not). Re-assert the facts and evaluate again: the
        // pause is gone, so the held head is released.
        await chat.retrySendQueue()
        try applyLive(model, status: .idle, sendAvailable: true)
        model.evaluateSendQueue()
        try await eventually { http.count("messages") == 2 }
        #expect(!model.isSendQueuePaused)
        #expect(model.sendQueue.head?.state == .awaitingEcho)
    }

    @Test func anOfflineQueueReadsAsPausedAndNeverDrains() async throws {
        let http = TestHTTPTransport()
        let (repo, model) = makeSession(http)
        defer { repo.reset() }
        try enqueueWhileRunning(model, "offline")
        model.update(V2SessionObservation(sessionId: "session", data: nil, connection: .offline, error: nil),
                     network: V2NetworkStatus(availability: .offline))
        try applyLive(model, status: .idle, sendAvailable: true)
        #expect(model.isSendQueuePaused)
        #expect(model.queuePauseForDisplay == .offline)
        #expect(await model.drainSendQueueIfPossible() == false)
        #expect(http.count("messages") == 0)
    }

    // MARK: - Withdraw / edit

    @Test func withdrawRemovesAWaitingMessageButNotOneOnTheWire() async throws {
        let http = TestHTTPTransport()
        let (repo, model) = makeSession(http)
        defer { repo.reset() }
        let waiting = try enqueueWhileRunning(model, "withdraw me")
        model.withdrawQueuedMessage(id: waiting.id)
        #expect(model.sendQueue.isEmpty)

        model.draft = "on the wire"
        let onWire = try #require(model.enqueueDraft())
        try applyLive(model, status: .idle, sendAvailable: true)
        #expect(await model.drainSendQueueIfPossible())
        model.withdrawQueuedMessage(id: onWire.id)
        #expect(model.sendQueue.count == 1)
        #expect(onWire.state == .awaitingEcho)
    }

    @Test func editMovesAWaitingMessageBackIntoTheComposerAndAppendsToTheDraft() throws {
        let http = TestHTTPTransport()
        let (repo, model) = makeSession(http)
        defer { repo.reset() }
        let item = try enqueueWhileRunning(model, "queued line")
        model.draft = "existing draft"
        model.editQueuedMessage(id: item.id)
        #expect(model.draft == "existing draft\nqueued line")
        #expect(model.sendQueue.isEmpty)

        // With an empty draft the content is restored verbatim (enqueue clears
        // the composer, so the draft is empty when the edit happens).
        model.draft = "verbatim"
        let again = try #require(model.enqueueDraft())
        model.editQueuedMessage(id: again.id)
        #expect(model.draft == "verbatim")
        #expect(model.sendQueue.isEmpty)
    }

    @Test func editAndWithdrawAreRefusedOnceAMessageIsOnTheWire() async throws {
        let http = TestHTTPTransport()
        let (repo, model) = makeSession(http)
        defer { repo.reset() }
        let item = try enqueueWhileRunning(model, "committed")
        try applyLive(model, status: .idle, sendAvailable: true)
        #expect(await model.drainSendQueueIfPossible())
        model.editQueuedMessage(id: item.id)
        model.withdrawQueuedMessage(id: item.id)
        #expect(model.draft.isEmpty)
        #expect(model.sendQueue.count == 1)
    }

    // MARK: - Attachments

    @Test func aMessageWithUnfinishedUploadsDoesNotDrainUntilTheBytesLand() async throws {
        let http = TestHTTPTransport()
        let (repo, model) = makeSession(http)
        defer { repo.reset() }
        try applyLive(model, status: .running, sendAvailable: false)
        model.composer.attachments = [ChatAttachment(id: "local-1", name: "note.txt", data: Data([1, 2, 3]), mediaType: "text/plain")]
        model.draft = "with a file"
        let item = try #require(model.enqueueDraft())
        #expect(item.isUploadComplete == false)
        try applyLive(model, status: .idle, sendAvailable: true)
        #expect(await model.drainSendQueueIfPossible() == false)
        #expect(http.count("messages") == 0)

        let uploaded: V2AttachmentUploadResponse = try fixture("upload")
        let reference = try #require(uploaded.attachments.first)
        model.bindQueueUpload(itemID: item.id, localID: "local-1", file: reference)
        #expect(item.attachmentIDs == [reference.fileId])
        #expect(item.isUploadComplete == true)
        #expect(await model.drainSendQueueIfPossible())
        #expect(http.count("messages") == 1)
    }

    // MARK: - Chat layer

    @Test func chatEnqueueCommitsTheComposerDraftAndKeepsTheQueueKeyLive() async throws {
        let http = TestHTTPTransport()
        let (repo, model) = makeSession(http)
        defer { repo.reset() }
        try applyLive(model, status: .running, sendAvailable: false)
        let chat = makeChat(model, repo, http)
        #expect(chat.canQueueSend)
        model.draft = "typed while running"
        await chat.enqueueComposer()
        #expect(model.draft.isEmpty)
        #expect(model.sendQueue.count == 1)
        #expect(model.sendQueue.head?.content == "typed while running")
        #expect(chat.queueEnqueueTick == 1)
    }

    @Test func chatRefusesToQueueWhenTheCapabilityIsUnsupported() async throws {
        let http = TestHTTPTransport()
        let (repo, model) = makeSession(http)
        defer { repo.reset() }
        try applyLive(model, status: .running, sendAvailable: false, sendSupported: false)
        let chat = makeChat(model, repo, http)
        #expect(!chat.canQueueSend)
        model.draft = "no thanks"
        await chat.enqueueComposer()
        #expect(model.sendQueue.isEmpty)
        #expect(chat.queueEnqueueTick == 0)
    }

    @Test func chatEagerlyUploadsAQueuedAttachmentsBytes() async throws {
        let http = TestHTTPTransport()
        let (repo, model) = makeSession(http)
        defer { repo.reset() }
        try applyLive(model, status: .running, sendAvailable: false)
        let chat = makeChat(model, repo, http)
        model.composer.attachments = [ChatAttachment(id: "local-1", name: "note.txt", data: Data([1]), mediaType: "text/plain")]
        model.draft = "with a file"
        await chat.enqueueComposer()
        let item = try #require(model.sendQueue.head)
        // The bytes go up in the background, not before the tap returns.
        try await eventually { item.isUploadComplete }
        #expect(http.uploads.count == 1)
    }

    @Test func retryKeepsThePauseWhenAnUploadStillCannotComplete() async throws {
        let http = TestHTTPTransport()
        let (repo, model) = makeSession(http)
        defer { repo.reset() }
        try applyLive(model, status: .running, sendAvailable: false)
        let chat = makeChat(model, repo, http)
        // An empty attachment body makes the upload service reject the file, so
        // the upload can never complete — a stand-in for a transport failure
        // the shared harness cannot otherwise produce.
        model.composer.attachments = [ChatAttachment(id: "local-1", name: "note.txt", data: Data(), mediaType: "text/plain")]
        model.draft = "stuck"
        let item = try #require(model.enqueueDraft())
        try await chat.retrySendQueue()
        #expect(!item.isUploadComplete)
        // The retry could not finish the upload, so the banner stays up with
        // its reason instead of flashing away on the resume.
        #expect(model.isSendQueuePaused)
        guard case .failure = model.queuePauseForDisplay else {
            Issue.record("A retry that still cannot upload must keep the failure pause"); return
        }
    }

    // MARK: - Composer affordance truth table

    @Test func affordanceResolvesTheThreeShapesAndTheirEnablement() {
        // Idle: the plain send key, gated by the full send gate.
        let idle = ComposerQueueAffordance.resolve(isStreaming: false, hasText: true, canQueue: true, canStop: true, canSend: false)
        #expect(idle.shape == .send)
        #expect(!idle.isActionEnabled)
        #expect(ComposerQueueAffordance.resolve(isStreaming: false, hasText: true, canQueue: false, canStop: true, canSend: true).shape == .send)

        // Running with no text: the plain stop key, gated by the interrupt gate.
        let stop = ComposerQueueAffordance.resolve(isStreaming: true, hasText: false, canQueue: false, canStop: true, canSend: false)
        #expect(stop.shape == .stop)
        #expect(stop.isActionEnabled)
        let unstopable = ComposerQueueAffordance.resolve(isStreaming: true, hasText: false, canQueue: false, canStop: false, canSend: false)
        #expect(unstopable.shape == .stop)
        #expect(!unstopable.isActionEnabled)

        // Running with text: the split form; the arrow follows the queue gate.
        let queued = ComposerQueueAffordance.resolve(isStreaming: true, hasText: true, canQueue: true, canStop: true, canSend: false)
        #expect(queued.shape == .queueSend)
        #expect(queued.isActionEnabled)
        let refused = ComposerQueueAffordance.resolve(isStreaming: true, hasText: true, canQueue: false, canStop: true, canSend: false)
        #expect(refused.shape == .queueSend)
        #expect(!refused.isActionEnabled)
    }
}

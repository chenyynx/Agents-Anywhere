import Foundation
import Testing
@testable import ClientCore

/// Timeline page fixture holding the given record orders.
private func openingTimelinePage(rows: [Int], hasMore: Bool = false) throws -> Data {
    var page = try fixtureObject("timeline")
    page["items"] = try rows.map { try itemObject(id: "reply-\($0)", order: $0) }
    page["hasMore"] = hasMore
    return try JSONSerialization.data(withJSONObject: page)
}

/// T1.4 — a memory-cached visit presents its snapshot before the network
/// refresh completes; the cold path keeps presenting only after the snapshot
/// arrives, and the cold-load mask waits for the first positioning or its
/// bounded fallback.
@Suite @MainActor struct OpeningFastPathPresentationTests {
    private func location() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("aa-opening-\(UUID().uuidString)", isDirectory: true)
    }

    /// A cached visit whose saved archive still flags rows newer than its
    /// window. Restoring that flag is the opening reconcile's trigger; since
    /// b744 history paging keeps both sides of the reader and can no longer
    /// overflow the newest rows out of the projection.
    private func seededStore(_ url: URL, rows: [Int], hasNewerItems: Bool,
                             hasMore: Bool = true) async throws -> V2LocalStore {
        let store = V2LocalStore(directory: url, timelineDatabaseEnabled: true)
        let probe = repository(transport: TestHTTPTransport(), localStore: store)
        var data = V2SessionData(snapshot: try snapshot(items: rows.map {
            try itemObject(id: "reply-\($0)", order: $0)
        }, hasMore: hasMore))
        data.hasNewerItems = hasNewerItems
        await store.saveSession(V2SessionArchive(data: data, model: probe.session(id: "session")))
        probe.reset()
        return store
    }
    private func chat(_ repo: V2SessionRepository, _ http: TestHTTPTransport) -> SessionChatModel {
        SessionChatModel(session: repo.session(id: "session"), repository: repo,
            attachments: .init(attachmentAPI: V2AttachmentAPI(transport: http)))
    }

    @Test func cachedOpeningPresentsBeforeTheNetworkRefreshCompletes() async throws {
        let http = TestHTTPTransport()
        let gate = TestGate()
        var latestStarted = false
        http.respond = { call in
            if call.path.hasSuffix("timeline") {
                latestStarted = true
                await gate.wait()
                return try openingTimelinePage(rows: [2, 3])
            }
            return try http.defaultResponse(call)
        }
        // A saved window [1, 2] whose archive still flags newer rows: opening
        // presents the local page first and reconciles it in the background.
        let url = location(); defer { try? FileManager.default.removeItem(at: url) }
        let store = try await seededStore(url, rows: [1, 2], hasNewerItems: true)
        let repo = repository(transport: http, localStore: store)
        defer { repo.reset() }
        _ = try await repo.load(sessionId: "session")
        #expect(repo.cached(sessionId: "session")?.hasNewerItems == true)
        let model = chat(repo, http)
        // The memory snapshot suppresses the full-screen cold mask from the
        // first frame (D3).
        #expect(model.opensFromCachedSnapshot)
        #expect(!model.showsOpeningMask)
        let opening = Task { await model.prepareOpening() }
        defer { gate.release(); opening.cancel() }
        try await eventually { latestStarted }
        await opening.value
        // The refresh is still blocked in the network, yet the cached window is
        // presented and the page is ready (D3): opening never waits for the
        // reconcile.
        #expect(model.timeline.rows.map(\.id) == ["reply-1", "reply-2"])
        #expect(model.isOpeningReady && model.openingError == nil)
        #expect(model.openingRefreshCompleted)
        gate.release()
        // The late refresh updates the newest side without a second
        // presentation path and clears the newer prompt. It keeps the rows the
        // opening already presented (row 1), so the refresh cannot remove a
        // row the reader already saw.
        try await eventually { repo.cached(sessionId: "session")?.hasNewerItems == false }
        #expect(repo.cached(sessionId: "session")?.items.map(\.id) == ["reply-1", "reply-2", "reply-3"])
    }

    /// R-a guard — the early presentation uses the same opening window as the
    /// store. With no opening trim, the cached visit keeps its whole window,
    /// so a later refresh cannot remove a row the reader already saw.
    @Test func cachedOpeningPresentsTheCachedWindowWhileTheRefreshIsBlocked() async throws {
        let http = TestHTTPTransport()
        let gate = TestGate()
        var latestStarted = false
        http.respond = { call in
            if call.path.hasSuffix("timeline") {
                latestStarted = true
                await gate.wait()
                return try openingTimelinePage(rows: Array(121...130))
            }
            return try http.defaultResponse(call)
        }
        let url = location(); defer { try? FileManager.default.removeItem(at: url) }
        let store = try await seededStore(url, rows: Array(1...120), hasNewerItems: true)
        let repo = repository(transport: http, localStore: store)
        defer { repo.reset() }
        _ = try await repo.load(sessionId: "session")
        let cached = try #require(repo.cached(sessionId: "session"))
        #expect(cached.items.count == 120)
        #expect(cached.hasNewerItems)

        let model = chat(repo, http)
        let opening = Task { await model.prepareOpening() }
        defer { gate.release(); opening.cancel() }
        try await eventually { latestStarted }
        await opening.value
        // The refresh is still blocked in the network. The cached window was
        // presented before it, whole (R-a guard).
        #expect(model.timeline.rows.map(\.id) == (1...120).map { "reply-\($0)" })
        #expect(model.isOpeningReady && model.openingError == nil)
        gate.release()
        try await eventually { repo.cached(sessionId: "session")?.hasNewerItems == false }
    }

    @Test func cachedOpeningStaysReadyWhenTheRefreshFails() async throws {
        let http = TestHTTPTransport()
        http.respond = { call in
            if call.path.hasSuffix("timeline") { throw URLError(.notConnectedToInternet) }
            return try http.defaultResponse(call)
        }
        let url = location(); defer { try? FileManager.default.removeItem(at: url) }
        let store = try await seededStore(url, rows: [1, 2], hasNewerItems: true)
        let repo = repository(transport: http, localStore: store)
        defer { repo.reset() }
        _ = try await repo.load(sessionId: "session")
        let model = chat(repo, http)
        await model.prepareOpening()
        // The local-first page opens without touching the network; the failed
        // background read (and the guaranteed fill retrying it) keeps the
        // local window and the newer prompt instead of surfacing an error or
        // a blocked mask. The count is at least one, not exactly one: the
        // fill legitimately retries the same read.
        try await eventually { http.count("timeline") >= 1 }
        try await Task.sleep(for: .milliseconds(20))
        #expect(model.isOpeningReady && model.openingError == nil)
        #expect(model.timeline.rows.map(\.id) == ["reply-1", "reply-2"])
        #expect(repo.cached(sessionId: "session")?.hasNewerItems == true)
    }

    @Test func coldOpeningPresentsOnlyAfterTheSnapshotArrives() async throws {
        let http = TestHTTPTransport()
        let gate = TestGate()
        var snapshotStarted = false
        http.respond = { call in
            guard call.path.hasSuffix("snapshot") else { return try http.defaultResponse(call) }
            snapshotStarted = true
            await gate.wait()
            return try http.defaultResponse(call)
        }
        let repo = repository(transport: http)
        defer { repo.reset() }
        let model = chat(repo, http)
        #expect(!model.opensFromCachedSnapshot && model.showsOpeningMask)
        let opening = Task { await model.prepareOpening() }
        defer { gate.release(); opening.cancel() }
        try await eventually { snapshotStarted }
        // A cold load never presents rows before its snapshot arrives.
        #expect(!model.isOpeningReady && model.timeline.rows.isEmpty)
        #expect(model.showsOpeningMask)
        gate.release()
        await opening.value
        #expect(model.isOpeningReady && !model.timeline.rows.isEmpty)
        #expect(model.openingError == nil)
    }

    /// The row store keeps metadata after evicting rows. That empty shell used
    /// to count as a cached snapshot, so the cold mask was suppressed and the
    /// reader stared at an empty transcript while the newest page downloaded
    /// (device 2026-11-01). It must behave like a cold open.
    @Test func anEvictedWindowKeepsTheColdMaskUntilTheSnapshotArrives() async throws {
        let http = TestHTTPTransport()
        let gate = TestGate()
        var snapshotStarted = false
        http.respond = { call in
            if call.path.hasSuffix("snapshot") {
                snapshotStarted = true
                await gate.wait()
            }
            return try http.defaultResponse(call)
        }
        let url = location(); defer { try? FileManager.default.removeItem(at: url) }
        let store = try await seededStore(url, rows: [1, 2], hasNewerItems: true)
        await store.trimCache(to: 0)
        let repo = repository(transport: http, localStore: store)
        defer { repo.reset() }
        _ = try await repo.load(sessionId: "session")
        #expect(repo.cached(sessionId: "session")?.items.isEmpty == true)

        let model = chat(repo, http)
        #expect(!model.opensFromCachedSnapshot && model.showsOpeningMask)
        let opening = Task { await model.prepareOpening() }
        defer { gate.release(); opening.cancel() }
        try await eventually { snapshotStarted }
        // No empty presentation may dismiss the mask before the snapshot.
        #expect(!model.isOpeningReady && model.timeline.rows.isEmpty)
        #expect(model.showsOpeningMask)
        gate.release()
        await opening.value
        #expect(model.isOpeningReady && !model.timeline.rows.isEmpty)
        #expect(model.openingError == nil)
    }

    /// A creation handoff: the server entry a local creation binds onto starts
    /// with an empty projection and the unconfirmed bubble staged. It must open
    /// like a cached visit — the bubble paints on the first frame and no cold
    /// mask covers the page. Otherwise the bound page cold-opened and replayed
    /// the send's entrance (pp 2026-11-15: the bubble and the working row
    /// animated twice).
    ///
    /// A placeholder window carries neither the older nor the newer flag, so
    /// `repository.open` returns it without a network read; the newest page
    /// arrives later through the connection's snapshot (device b1216:
    /// `timeline.snapshot.fetch trigger=reconnect` right after the bound
    /// `session.open`). The assertions therefore pin the opening state, not a
    /// gated request.
    @Test func aBoundCreationOpensLikeACachedVisitInsteadOfColdOpening() async throws {
        let http = TestHTTPTransport()
        let repo = repository(transport: http)
        defer { repo.reset() }
        let project = try fixture("project", as: V2ProjectResponse.self).project
        let runtime: V2DeviceRuntime = try fixture("runtime")
        let submission = NewSessionSubmission(
            project: project, runtime: runtime, text: "第一条", attachments: [])
        repo.stageCreation(submission)
        let response: V2SessionCreateResponse = try fixture("session")
        repo.bindCreation(submission, response: response)

        let model = chat(repo, http)
        // The handoff entry carries the bubble the local page already showed;
        // it must not cold-open over it.
        #expect(model.opensFromCachedSnapshot)
        #expect(!model.showsOpeningMask)
        await model.prepareOpening()
        #expect(model.openingError == nil)
        #expect(model.isOpeningReady)
        #expect(model.timeline.pendingMessages.map(\.id) == [submission.pending.id])
    }

    @Test func coldMaskWaitsForTheFirstPositioningOrItsBoundedFallback() async throws {
        let http = TestHTTPTransport()
        let repo = repository(transport: http)
        defer { repo.reset() }
        let model = chat(repo, http)
        await model.prepareOpening()
        #expect(model.isOpeningReady && !model.timeline.rows.isEmpty)
        // The first return has not been acknowledged yet: the cold mask still
        // covers the page so the reader never sees the top of the window.
        #expect(!model.openingPositionSettled && model.showsOpeningMask)
        model.openingPositionDidSettle()
        #expect(model.openingPositionSettled && !model.showsOpeningMask)
        model.openingPositionDidSettle()
        #expect(model.openingPositionSettled && !model.showsOpeningMask)
    }

}

/// The presentation-side signal behind the re-assert: a window that drops a
/// row it had presented is a replacement (the trim/latest-page surgery, a
/// recovery snapshot); an append keeps every presented row and must not move
/// the reader.
@Suite @MainActor struct OpeningWindowRevisionTests {
    private func items(_ orders: ClosedRange<Int>) throws -> [V2TimelineItem] {
        try orders.map { try decode(itemObject(id: "reply-\($0)", order: $0), as: V2TimelineItem.self) }
    }

    @Test func aReplacedWindowBumpsTheRevisionButAnAppendDoesNot() throws {
        let timeline = SessionTimelinePresentation()
        // The opening's own first presentation has no claim to re-assert: the
        // opening return is already armed by `open()`.
        timeline.presentOpening(try items(1...3), pendingMessages: [])
        #expect(timeline.rows.map(\.id) == ["reply-1", "reply-2", "reply-3"])
        #expect(timeline.windowRevision == 0)
        // The post-surgery window (the newest page) drops rows that were on
        // screen: the reader must be re-anchored to the new bottom.
        timeline.presentOpening(try items(2...4), pendingMessages: [])
        #expect(timeline.windowRevision == 1)
        // A live append keeps every presented row: nothing to re-assert.
        timeline.stage(try items(2...5), animate: false)
        timeline.flush(now: 1)
        #expect(timeline.rows.map(\.id) == ["reply-2", "reply-3", "reply-4", "reply-5"])
        #expect(timeline.windowRevision == 1)
        // A recovery/snapshot replacement is the same shape as the surgery.
        timeline.stage(try items(51...53), animate: false)
        timeline.flush(now: 2)
        #expect(timeline.rows.map(\.id) == ["reply-51", "reply-52", "reply-53"])
        #expect(timeline.windowRevision == 2)
    }

    @Test func rePresentingTheSameWindowDoesNotBumpTheRevision() throws {
        let timeline = SessionTimelinePresentation()
        timeline.presentOpening(try items(1...3), pendingMessages: [])
        timeline.presentOpening(try items(1...3), pendingMessages: [])
        #expect(timeline.windowRevision == 0)
    }
}

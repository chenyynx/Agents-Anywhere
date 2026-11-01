import Foundation
import Testing
@testable import ClientCore

@Suite @MainActor struct LocalPageCacheTests {
    private func location() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("aa-page-cache-\(UUID().uuidString)", isDirectory: true)
    }

    private func timelinePage(_ rows: ClosedRange<Int>, hasMore: Bool = false) throws -> Data {
        var page = try fixtureObject("timeline")
        page["items"] = try rows.map { try itemObject(id: "item-\($0)", order: $0, seq: $0) }
        page["hasMore"] = hasMore
        return try JSONSerialization.data(withJSONObject: page)
    }

    private func seed(_ store: V2LocalStore, count: Int, hasMore: Bool = false,
                     hasNewerItems: Bool = false,
                     excludesAgentChildren: Bool? = nil) async throws {
        let http = TestHTTPTransport()
        let probe = repository(transport: http, localStore: store)
        var data = V2SessionData(snapshot: try snapshot(items: (1...count).map {
            try itemObject(id: "item-\($0)", order: $0, seq: $0)
        }, hasMore: hasMore, excludesAgentChildren: excludesAgentChildren))
        data.hasNewerItems = hasNewerItems
        await store.saveSession(V2SessionArchive(data: data, model: probe.session(id: "session")))
        probe.reset()
        await store.close(removing: false)
    }

    @Test func olderPagesComeFromDiskWithoutNetwork() async throws {
        let url = location(); defer { try? FileManager.default.removeItem(at: url) }
        try await seed(V2LocalStore(directory: url, timelineDatabaseEnabled: true), count: 600)

        let http = TestHTTPTransport()
        let store = V2LocalStore(directory: url, timelineDatabaseEnabled: true)
        let repo = repository(transport: http, localStore: store)
        repo.updateConnectivity(.init(availability: .offline))
        let opening = try await repo.open(sessionId: "session")
        #expect(opening.items.map(\.orderSeq) == Array(301...600))
        #expect(opening.localOlderAvailable && opening.canLoadOlder)

        let first = try await repo.loadOlder(sessionId: "session")
        #expect(first.items.map(\.orderSeq) == Array(101...600))
        #expect(first.localOlderAvailable && first.canLoadOlder)

        let second = try await repo.loadOlder(sessionId: "session")
        #expect(second.items.map(\.orderSeq) == Array(1...600))
        #expect(!second.localOlderAvailable && !second.canLoadOlder)
        #expect(http.calls.isEmpty)

        repo.reset(); await store.close(removing: true)
    }

    @Test func latestPagesComeFromDiskAfterTheWindowSlides() async throws {
        let url = location(); defer { try? FileManager.default.removeItem(at: url) }
        try await seed(V2LocalStore(directory: url, timelineDatabaseEnabled: true), count: 600)

        let http = TestHTTPTransport()
        let store = V2LocalStore(directory: url, timelineDatabaseEnabled: true)
        var policy = V2SessionCachePolicy()
        policy.maximumTimelineItems = 150
        let repo = repository(transport: http, policy: policy, localStore: store)
        repo.updateConnectivity(.init(availability: .offline))
        _ = try await repo.open(sessionId: "session")

        let older = try await repo.loadOlder(sessionId: "session")
        // The opening window is 451...600, the disk page is the 200 rows
        // before it, and browsing keeps the whole merged window: the newer
        // half survives instead of being trimmed away.
        #expect(older.items.map(\.orderSeq) == Array(251...600))
        #expect(!older.hasNewerItems)

        let latest = try await repo.loadLatest(sessionId: "session")
        #expect(latest.items.map(\.orderSeq) == Array(451...600))
        #expect(!latest.hasNewerItems)
        #expect(latest.localOlderAvailable)
        #expect(http.calls.isEmpty)

        repo.reset(); await store.close(removing: true)
    }

    @Test func onlineLatestUsesTheLocalPageBeforeTheNetwork() async throws {
        let url = location(); defer { try? FileManager.default.removeItem(at: url) }
        try await seed(V2LocalStore(directory: url, timelineDatabaseEnabled: true), count: 600)

        let http = TestHTTPTransport()
        let store = V2LocalStore(directory: url, timelineDatabaseEnabled: true)
        var policy = V2SessionCachePolicy()
        policy.maximumTimelineItems = 150
        let repo = repository(transport: http, policy: policy, localStore: store)
        // Online, not offline: a return-to-bottom must still prefer the local
        // latest page and only reconcile it in the background.
        _ = try await repo.open(sessionId: "session")
        _ = try await repo.loadOlder(sessionId: "session")

        let latest = try await repo.loadLatest(sessionId: "session")
        #expect(latest.items.map(\.orderSeq) == Array(451...600))
        #expect(!latest.hasNewerItems)
        #expect(http.calls.isEmpty)

        repo.reset(); await store.close(removing: true)
    }

    @Test func aStaleLocalLatestPageReconcilesInTheBackground() async throws {
        let url = location(); defer { try? FileManager.default.removeItem(at: url) }
        try await seed(V2LocalStore(directory: url, timelineDatabaseEnabled: true),
                       count: 600, hasNewerItems: true)

        let http = TestHTTPTransport()
        let gate = TestGate()
        let latestPage = try timelinePage(451...600, hasMore: true)
        var latestStarted = false
        http.respond = { call in
            guard call.path.hasSuffix("timeline") else { return try http.defaultResponse(call) }
            latestStarted = true
            await gate.wait()
            return latestPage
        }
        let store = V2LocalStore(directory: url, timelineDatabaseEnabled: true)
        var policy = V2SessionCachePolicy()
        policy.maximumTimelineItems = 150
        let repo = repository(transport: http, policy: policy, localStore: store)
        defer { gate.release(); repo.reset() }

        _ = try await repo.load(sessionId: "session")
        _ = try await repo.loadOlder(sessionId: "session")
        let latest = try await repo.loadLatest(sessionId: "session")
        // The local page is on screen immediately, but its saved tail is
        // incomplete; the newer prompt stays until the network page lands.
        #expect(latest.items.map(\.orderSeq) == Array(451...600))
        #expect(latest.hasNewerItems)
        try await eventually { latestStarted }
        gate.release()
        try await eventually { repo.cached(sessionId: "session")?.hasNewerItems == false }
        repo.reset(); await store.close(removing: true)
    }

    /// The 2026-11-01 incident end to end: the echo of a sent message sits
    /// beyond a stale window, so the projection refuses it. The pending bubble
    /// must not be confirmed while the row is missing; the deferred-row fill
    /// then opens the window and both the echo and the bubble settle.
    @Test func aDeferredEchoWaitsForTheLatestFillBeforeConfirming() async throws {
        let url = location(); defer { try? FileManager.default.removeItem(at: url) }
        try await seed(V2LocalStore(directory: url, timelineDatabaseEnabled: true),
                       count: 600, hasNewerItems: true)

        let http = TestHTTPTransport()
        let gate = TestGate()
        // The page must carry the echo's clientMessageId: that is what retires
        // the pending bubble once the row is present.
        var page = try fixtureObject("timeline")
        var pageItems = try (451...600).map {
            try itemObject(id: "item-\($0)", order: $0, seq: $0)
        }
        pageItems.append(try itemObject(id: "item-601", order: 601, seq: 601,
                                        text: "hi", clientID: "client"))
        page["items"] = pageItems
        page["hasMore"] = true
        let latestPage = try JSONSerialization.data(withJSONObject: page)
        var latestStarted = false
        http.respond = { call in
            guard call.path.hasSuffix("timeline") else { return try http.defaultResponse(call) }
            latestStarted = true
            await gate.wait()
            return latestPage
        }
        let realtime = TestRealtimeAPI()
        realtime.onRecover = {
            V2EventRecoveryResponse(events: [], nextCursor: "seq:1000",
                                    snapshotRequired: false, serverTime: "")
        }
        let store = V2LocalStore(directory: url, timelineDatabaseEnabled: true)
        var policy = V2SessionCachePolicy()
        policy.maximumTimelineItems = 150
        let repo = repository(transport: http, realtime: realtime, policy: policy, localStore: store)
        defer { gate.release(); repo.reset() }

        // Restore the cached window with its newer flag but do not open: the
        // fill caused by the deferred echo is the only latest read here.
        _ = try await repo.load(sessionId: "session")
        #expect(repo.cached(sessionId: "session")?.hasNewerItems == true)

        let model = repo.session(id: "session")
        let connection = Task { await model.connect() }
        defer { connection.cancel() }
        try await eventually { model.connection == .connected }
        model.stage(V2PendingMessage(id: "client", content: "hi", attachmentIDs: []))
        // Production reaches the echo with the write already accepted.
        model.pendingMessages.first?.update(.accepted)

        realtime.yield(try event("timeline.item_created", seq: 1001, payload: [
            "item": itemObject(id: "item-601", order: 601, seq: 1001,
                               text: "hi", clientID: "client")]))
        try await eventually { latestStarted }

        // The echo is deferred: no confirmation, no row, and the window still
        // reports that it is behind. The count assertion is what makes a
        // premature confirmation (the pre-fix behaviour) fail loudly instead
        // of reading as "first?.delivery == nil".
        #expect(model.pendingMessages.count == 1)
        #expect(model.pendingMessages.first?.delivery != V2PendingMessage.Delivery.confirmed)
        #expect(!model.timeline.contains { $0.value.id == "item-601" })
        #expect(model.hasNewerItems)

        gate.release()
        try await eventually { model.pendingMessages.isEmpty }
        #expect(model.timeline.contains { $0.value.id == "item-601" })
        #expect(!model.hasNewerItems)

        repo.reset(); await store.close(removing: true)
    }

    /// The send path's guarantee: an authoritative read must not be answered
    /// from the stale local page even when that page reaches the held window's
    /// end. Without it, a send made from a stale window kept the transcript
    /// behind until a background read happened to land.
    @Test func authoritativeLatestSkipsTheStaleLocalPage() async throws {
        let url = location(); defer { try? FileManager.default.removeItem(at: url) }
        try await seed(V2LocalStore(directory: url, timelineDatabaseEnabled: true),
                       count: 600, hasNewerItems: true)

        let http = TestHTTPTransport()
        let latestPage = try timelinePage(501...700, hasMore: true)
        http.respond = { call in
            guard call.path.hasSuffix("timeline") else { return try http.defaultResponse(call) }
            return latestPage
        }
        let store = V2LocalStore(directory: url, timelineDatabaseEnabled: true)
        var policy = V2SessionCachePolicy()
        policy.maximumTimelineItems = 150
        let repo = repository(transport: http, policy: policy, localStore: store)
        defer { repo.reset() }

        _ = try await repo.load(sessionId: "session")
        #expect(repo.cached(sessionId: "session")?.hasNewerItems == true)

        let latest = try await repo.loadLatest(sessionId: "session", authoritative: true)
        #expect(http.count("timeline") == 1)
        #expect(latest.items.last?.orderSeq == 700)
        #expect(!latest.hasNewerItems)

        repo.reset(); await store.close(removing: true)
    }

    /// A history page served from the archive can carry a step the server has
    /// already finished. The disk page must not win when it holds an active
    /// status: the repository reads the server's page for that range and the
    /// settled row replaces it (device 2026-11-01: a step spun forever).
    @Test func anArchivedActiveRowIsRefreshedFromTheServerOnHistoryPaging() async throws {
        let url = location(); defer { try? FileManager.default.removeItem(at: url) }
        let http = TestHTTPTransport()
        let seedStore = V2LocalStore(directory: url, timelineDatabaseEnabled: true)
        do {
            let seedRepo = repository(transport: TestHTTPTransport(), localStore: seedStore)
            var items = try (1...600).map { try itemObject(id: "item-\($0)", order: $0) }
            var active = try itemObject(id: "item-200", order: 200)
            active["status"] = "running"
            items[199] = active
            let data = V2SessionData(snapshot: try snapshot(items: items, hasMore: true))
            await seedStore.saveSession(V2SessionArchive(data: data,
                                                         model: seedRepo.session(id: "session")))
            seedRepo.reset()
            await seedStore.close(removing: false)
        }
        let store = V2LocalStore(directory: url, timelineDatabaseEnabled: true)

        var page = try fixtureObject("timeline")
        var pageItems = try (101...300).map { try itemObject(id: "item-\($0)", order: $0) }
        var settled = try itemObject(id: "item-200", order: 200)
        settled["status"] = "done"
        pageItems[99] = settled
        page["items"] = pageItems
        page["hasMore"] = true
        let pageData = try JSONSerialization.data(withJSONObject: page)
        http.respond = { call in
            guard call.path.hasSuffix("timeline") else { return try http.defaultResponse(call) }
            return pageData
        }

        let repo = repository(transport: http, localStore: store)
        defer { repo.reset() }
        _ = try await repo.load(sessionId: "session")
        let older = try await repo.loadOlder(sessionId: "session")
        #expect(http.count("timeline") == 1)
        #expect(older.items.first { $0.id == "item-200" }?.status == .done)

        repo.reset(); await store.close(removing: true)
    }

    /// A stale window is healed on resume for an observed session even when no
    /// opening or bottom trigger runs (the app was only backgrounded).
    @Test func resumeFillsAStaleWindowForAnObservedSession() async throws {
        let url = location(); defer { try? FileManager.default.removeItem(at: url) }
        try await seed(V2LocalStore(directory: url, timelineDatabaseEnabled: true),
                       count: 600, hasNewerItems: true)

        let http = TestHTTPTransport()
        let latestPage = try timelinePage(501...700, hasMore: true)
        var serveLatest = false
        http.respond = { call in
            guard call.path.hasSuffix("timeline") else { return try http.defaultResponse(call) }
            guard serveLatest else { throw URLError(.notConnectedToInternet) }
            return latestPage
        }
        let realtime = TestRealtimeAPI()
        realtime.onRecover = {
            V2EventRecoveryResponse(events: [], nextCursor: "seq:1000",
                                    snapshotRequired: false, serverTime: "")
        }
        let store = V2LocalStore(directory: url, timelineDatabaseEnabled: true)
        var policy = V2SessionCachePolicy()
        policy.maximumTimelineItems = 150
        let repo = repository(transport: http, realtime: realtime, policy: policy, localStore: store)
        defer { repo.reset() }

        _ = try await repo.load(sessionId: "session")
        #expect(repo.cached(sessionId: "session")?.hasNewerItems == true)
        let model = repo.session(id: "session")
        let connection = Task { await model.connect() }
        defer { connection.cancel() }
        try await eventually { model.connection == .connected }

        // Suspend cancels the observed fill; resume must schedule it again and
        // the now-working read must clear the window.
        repo.suspend()
        let before = http.count("timeline")
        serveLatest = true
        repo.resume()
        try await eventually {
            http.count("timeline") > before
                && repo.cached(sessionId: "session")?.hasNewerItems == false
        }
        #expect(repo.cached(sessionId: "session")?.items.last?.orderSeq == 700)

        repo.reset(); await store.close(removing: true)
    }

    @Test func historyAnchorKeepsTheReaderInsideTheWindow() async throws {
        let url = location(); defer { try? FileManager.default.removeItem(at: url) }
        try await seed(V2LocalStore(directory: url, timelineDatabaseEnabled: true), count: 600)

        let http = TestHTTPTransport()
        let store = V2LocalStore(directory: url, timelineDatabaseEnabled: true)
        var policy = V2SessionCachePolicy()
        policy.maximumTimelineItems = 150
        let repo = repository(transport: http, policy: policy, localStore: store)
        repo.updateConnectivity(.init(availability: .offline))
        _ = try await repo.open(sessionId: "session")

        let older = try await repo.loadOlder(sessionId: "session", anchorOrderSeq: 500)
        // Browsing history keeps both sides of the reader: the idle ceiling no
        // longer drops the newer half around an anchor (b744).
        #expect(older.items.map(\.orderSeq) == Array(251...600))
        #expect(older.items.contains { $0.orderSeq == 500 })
        #expect(!older.hasNewerItems)
        #expect(http.calls.isEmpty)

        repo.reset(); await store.close(removing: true)
    }

    @Test func localLatestPreservesTheMainOnlyWindowFlag() async throws {
        let url = location(); defer { try? FileManager.default.removeItem(at: url) }
        try await seed(V2LocalStore(directory: url, timelineDatabaseEnabled: true),
                       count: 600, excludesAgentChildren: true)

        let http = TestHTTPTransport()
        let store = V2LocalStore(directory: url, timelineDatabaseEnabled: true)
        var policy = V2SessionCachePolicy()
        policy.maximumTimelineItems = 150
        let repo = repository(transport: http, policy: policy, localStore: store)
        repo.updateConnectivity(.init(availability: .offline))
        _ = try await repo.open(sessionId: "session")
        _ = try await repo.loadOlder(sessionId: "session")
        _ = try await repo.loadLatest(sessionId: "session")
        #expect(repo.cached(sessionId: "session")?.windowExcludesAgentChildren == true)
        #expect(http.calls.isEmpty)

        repo.reset(); await store.close(removing: true)
    }
}

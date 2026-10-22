import Foundation
import Testing
@testable import ClientCore

/// C3: the SubAgent panel's on-demand child-row read for a main-only window —
/// page merge, the request state machine, per-card caching, and the loaded
/// gate over (window ∪ fetched) rows.
@Suite @MainActor struct SubAgentActivityStoreTests {
    private struct Page {
        let items: [V2TimelineItem]
        let hasMore: Bool

        init(_ items: [V2TimelineItem], hasMore: Bool) {
            self.items = items
            self.hasMore = hasMore
        }
    }

    private final class FetchStub {
        var pages: [String: [Page]] = [:]
        var error: Error?
        var calls: [(parent: String, before: Int?)] = []

        func fetch(_ parent: String, _ before: Int?) async throws -> V2SessionTimelinePage {
            calls.append((parent, before))
            if let error { throw error }
            var queue = pages[parent] ?? []
            let page = queue.isEmpty ? Page([], hasMore: false) : queue.removeFirst()
            pages[parent] = queue
            return V2SessionTimelinePage(sessionId: "session", items: page.items,
                                         nextSeq: 1000, hasMore: page.hasMore, serverTime: nil)
        }
    }

    private func child(_ id: String, parent: String = "card", order: Int,
                       revision: Int = 1, seq: Int = 10) throws -> V2TimelineItem {
        var value = try itemObject(id: id, order: order, revision: revision, seq: seq)
        value["type"] = "tool"
        value["content"] = ["kind": "command", "command": "ls", "parentItemId": parent]
        return try decode(value)
    }

    private func cardRow(_ id: String, order: Int = 1) throws -> V2TimelineItem {
        var value = try itemObject(id: id, order: order)
        value["type"] = "tool"
        value["content"] = ["kind": "agent_call", "action": "invoke", "description": "work"]
        return try decode(value)
    }

    // MARK: Merge

    @Test func theMergeKeepsTheNewerCopyAndSortsLikeTheTimeline() throws {
        let live = try child("t1", order: 2, revision: 3)
        let stale = try child("t1", order: 2, revision: 1)
        // A live window row that is newer than the fetched page wins...
        #expect(SubAgentActivityMerge.items(existing: [live], incoming: [stale]).first?.revision == 3)
        // ...and a fetched row that supersedes it wins instead.
        let newer = try child("t1", order: 2, revision: 4)
        #expect(SubAgentActivityMerge.items(existing: [live], incoming: [newer]).first?.revision == 4)
        // Pages merge by id and order by (orderSeq, id).
        let first = try child("b", order: 5), second = try child("a", order: 5), third = try child("c", order: 1)
        let merged = SubAgentActivityMerge.items(existing: [first, second], incoming: [third, first])
        #expect(merged.map(\.id) == ["c", "a", "b"])
    }

    // MARK: State machine

    @Test func theFirstPageLoadsEveryLineageParentAndMerges() async throws {
        let stub = FetchStub()
        stub.pages = [
            "dispatch": [Page([try child("t1", parent: "dispatch", order: 1),
                               try child("t3", parent: "dispatch", order: 3)], hasMore: true)],
            "alias": [Page([try child("t2", parent: "alias", order: 2)], hasMore: false)],
        ]
        let store = SubAgentActivityStore(fetch: stub.fetch)
        store.activate(cardID: "card", lineageIDs: ["dispatch", "alias"])
        try await eventually { store.phase == .loaded }
        #expect(stub.calls.map { $0.parent } == ["alias", "dispatch"])
        #expect(store.rows.map(\.id) == ["t1", "t2", "t3"])
        #expect(store.hasMore)
        #expect(store.cardID == "card")
    }

    @Test func anEmptyPageSettlesAsLoadedWithNoRows() async throws {
        let stub = FetchStub()
        let store = SubAgentActivityStore(fetch: stub.fetch)
        store.activate(cardID: "card", lineageIDs: ["card"])
        try await eventually { store.phase == .loaded }
        #expect(store.rows.isEmpty && !store.hasMore)
        #expect(stub.calls.count == 1)
    }

    @Test func aFailureIsRetryable() async throws {
        let stub = FetchStub()
        stub.error = URLError(.timedOut)
        let store = SubAgentActivityStore(fetch: stub.fetch)
        store.activate(cardID: "card", lineageIDs: ["card"])
        try await eventually {
            if case .failed = store.phase { return true }
            return false
        }
        stub.error = nil
        stub.pages = ["card": [Page([try child("t1", order: 1)], hasMore: false)]]
        store.retry()
        try await eventually { store.phase == .loaded }
        #expect(store.rows.map(\.id) == ["t1"])
    }

    @Test func paginationAsksForRowsOlderThanTheOldestLoadedOne() async throws {
        let stub = FetchStub()
        stub.pages = ["card": [
            Page([try child("t5", order: 5)], hasMore: true),
            Page([try child("t1", order: 1)], hasMore: false),
        ]]
        let store = SubAgentActivityStore(fetch: stub.fetch)
        store.activate(cardID: "card", lineageIDs: ["card"])
        try await eventually { store.phase == .loaded }
        #expect(store.hasMore)
        let oldest = try #require(store.rows.first?.orderSeq)
        store.loadOlder(beforeOrderSeq: oldest)
        try await eventually { store.rows.map(\.id) == ["t1", "t5"] }
        #expect(stub.calls.map { $0.before } == [nil, 5])
        #expect(!store.hasMore)
        #expect(store.phase == .loaded)
    }

    @Test func a422MeansUnsupportedAndIsNeverRetried() async throws {
        let stub = FetchStub()
        stub.error = HTTPError.server(statusCode: 422, message: "children mode unsupported")
        let store = SubAgentActivityStore(fetch: stub.fetch)
        store.activate(cardID: "card", lineageIDs: ["card"])
        try await eventually { store.phase == .unsupported }
        #expect(stub.calls.count == 1)
    }

    @Test func switchingBackToALoadedCardDoesNotRefetch() async throws {
        let stub = FetchStub()
        stub.pages = [
            "a": [Page([try child("a1", parent: "a", order: 1)], hasMore: false)],
            "b": [Page([try child("b1", parent: "b", order: 1)], hasMore: false)],
        ]
        let store = SubAgentActivityStore(fetch: stub.fetch)
        store.activate(cardID: "A", lineageIDs: ["a"])
        try await eventually { store.phase == .loaded }
        store.activate(cardID: "B", lineageIDs: ["b"])
        try await eventually { store.phase == .loaded && store.cardID == "B" }
        store.activate(cardID: "A", lineageIDs: ["a"])
        // Restored from the sheet-lifetime cache, no third request.
        #expect(store.phase == .loaded && store.rows.map(\.id) == ["a1"])
        #expect(stub.calls.count == 2)
    }

    // MARK: Offline cache

    @Test func eachCardKeepsOnlyItsNewestRows() throws {
        let rows = try (1...201).map { try child("r\($0)", order: $0) }
        let bounded = SubAgentActivityArchive.boundedRows(rows, limits: .default)
        #expect(bounded.count == 200)
        #expect(bounded.first?.orderSeq == 2)
        #expect(bounded.last?.orderSeq == 201)
    }

    @Test func theByteBudgetDropsOldestRowsFirstThenLeastRecentlyUsedCards() throws {
        let a1 = try child("a1", parent: "a", order: 1)
        let a2 = try child("a2", parent: "a", order: 2)
        let b1 = try child("b1", parent: "b", order: 3)
        let sizes = [a1, a2, b1].map(SubAgentActivityArchive.encodedSize(of:))
        // Row step: the budget fits two rows, so the globally oldest row goes.
        let rowLimited = SubAgentActivityArchive.bounded(
            ["a": [a1, a2], "b": [b1]],
            limits: .init(rowsPerCard: 200, byteBudget: sizes[1] + sizes[2]))
        #expect(rowLimited["a"]?.map(\.id) == ["a2"])
        #expect(rowLimited["b"]?.map(\.id) == ["b1"])
        // Card step: with one row per card the row step cannot free anything,
        // so the least recently used card goes first.
        let cardLimited = SubAgentActivityArchive.bounded(
            ["a": [a1], "b": [b1]],
            lastUsed: ["a": 1, "b": 2],
            limits: .init(rowsPerCard: 200, byteBudget: sizes[2]))
        #expect(cardLimited.keys.sorted() == ["b"])
    }

    @Test func aRestoredCardStaysReadableOffline() async throws {
        let stub = FetchStub()
        stub.error = V2ClientFailure(kind: .offline, message: "offline")
        let store = SubAgentActivityStore(fetch: stub.fetch)
        store.restore(["card": [try child("t1", parent: "card", order: 2)]])
        store.beginPresentation()
        store.activate(cardID: "card", lineageIDs: ["card"])
        try await eventually { store.phase == .offline }
        // The refresh failed, but the cached rows keep the panel readable.
        #expect(store.rows.map(\.id) == ["t1"])
        #expect(store.displayRows.map(\.id) == ["t1"])
        let cardItem = try cardRow("card")
        let card = try #require(SubAgentProgress.card(cardItem))
        #expect(SubAgentProgress.isContentLoaded(card, in: store.displayRows,
            windowExcludesAgentChildren: true))
    }

    @Test func liveWindowRowsJoinTheFetchedRowsAsStoreState() async throws {
        let stub = FetchStub()
        stub.pages = ["card": [Page([try child("t1", order: 2)], hasMore: false)]]
        let store = SubAgentActivityStore(fetch: stub.fetch)
        store.activate(cardID: "card", lineageIDs: ["card"])
        try await eventually { store.phase == .loaded }
        #expect(store.displayRows.map(\.id) == ["t1"])
        // A live child row from the window joins the fetched set, ordered.
        store.updateWindow(childRows: [try child("t0", order: 1)])
        #expect(store.displayRows.map(\.id) == ["t0", "t1"])
        // The window's newer copy of a fetched row wins the id.
        store.updateWindow(childRows: [try child("t1", order: 2, revision: 2)])
        #expect(store.displayRows.map(\.id) == ["t1"])
        #expect(store.displayRows.first?.revision == 2)
    }

    @Test func rePresentingTheSheetRefreshesAShownCard() async throws {
        let stub = FetchStub()
        stub.pages = ["card": [
            Page([try child("t1", order: 1)], hasMore: false),
            Page([try child("t1", order: 1), try child("t2", order: 2)], hasMore: false),
        ]]
        let store = SubAgentActivityStore(fetch: stub.fetch)
        store.activate(cardID: "card", lineageIDs: ["card"])
        try await eventually { store.phase == .loaded && store.rows.count == 1 }
        // A new sheet presentation keeps the rows on screen but refreshes them.
        store.beginPresentation()
        store.activate(cardID: "card", lineageIDs: ["card"])
        try await eventually { store.rows.count == 2 }
        #expect(stub.calls.count == 2)
        #expect(store.rows.map(\.id) == ["t1", "t2"])
    }

    @Test func theActivityCacheRoundTripsThroughTheArchive() async throws {
        let http = TestHTTPTransport()
        http.respond = { _ in
            var response = try fixtureObject("snapshot")
            var timeline = response["timeline"] as! [String: Any]
            timeline["items"] = [try itemObject(id: "main", order: 1)]
            response["timeline"] = timeline
            return try JSONSerialization.data(withJSONObject: response)
        }
        let repo = repository(transport: http)
        defer { repo.reset() }
        let data = try await repo.load(sessionId: "session")
        let model = repo.session(id: "session")
        model.subAgentActivity.restore(["card": [try child("t1", order: 2)]])
        let archive = V2SessionArchive(data: data, model: model)
        #expect(archive.subAgentActivity?["card"]?.count == 1)
        let decoded = try JSONDecoder().decode(V2SessionArchive.self, from: JSONEncoder().encode(archive))
        #expect(decoded.subAgentActivity?["card"]?.count == 1)
        // An archive written before this field existed decodes as empty.
        let encoded = try JSONEncoder().encode(archive)
        let object = try JSONSerialization.jsonObject(with: encoded)
        var old = try #require(object as? [String: Any])
        old.removeValue(forKey: "subAgentActivity")
        let oldArchive = try JSONDecoder().decode(V2SessionArchive.self,
            from: JSONSerialization.data(withJSONObject: old))
        #expect(oldArchive.subAgentActivity == nil)
    }

    @Test func theActivityCacheIsEncodedAndDecodedOnTheStoreActor() async throws {
        let http = TestHTTPTransport()
        http.respond = { _ in
            var response = try fixtureObject("snapshot")
            var timeline = response["timeline"] as! [String: Any]
            timeline["items"] = [try itemObject(id: "main", order: 1)]
            response["timeline"] = timeline
            return try JSONSerialization.data(withJSONObject: response)
        }
        let repo = repository(transport: http)
        defer { repo.reset() }
        let data = try await repo.load(sessionId: "session")
        let model = repo.session(id: "session")
        model.subAgentActivity.restore(["card": [try child("t1", order: 2)]])
        let archive = V2SessionArchive(data: data, model: model)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("aa-activity-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: url) }
        let store = V2LocalStore(directory: url)
        await store.saveSession(archive)
        let restored = await store.restoreSession("session")
        #expect(restored?.subAgentActivity["card"]?.map(\.id) == ["t1"])
        #expect(restored?.archive.subAgentActivity?["card"]?.count == 1)
        await store.close(removing: true)
    }

    // MARK: Loaded gate

    @Test func fetchedChildRowsAreWhatLoadsTheCardInAMainOnlyWindow() throws {
        let cardItem = try cardRow("card")
        let card = try #require(SubAgentProgress.card(cardItem))
        let fetched = try child("t1", parent: "card", order: 2)
        // The card's own row is always in a main-only window; it proves nothing.
        #expect(!SubAgentProgress.isContentLoaded(card, in: [cardItem], windowExcludesAgentChildren: true))
        let merged = SubAgentActivityMerge.items(existing: [cardItem], incoming: [fetched])
        #expect(SubAgentProgress.isContentLoaded(card, in: merged, windowExcludesAgentChildren: true))
        // Outside main-only windows the card's own row still passes.
        #expect(SubAgentProgress.isContentLoaded(card, in: [cardItem]))
    }

    // MARK: Request

    @Test func theChildrenReadUsesTheChildrenModeAndItsParameters() async throws {
        let http = TestHTTPTransport()
        http.respond = { _ in
            try JSONSerialization.data(withJSONObject: [
                "sessionId": "session", "items": [], "nextSeq": 10, "hasMore": false,
            ])
        }
        let repo = repository(transport: http)
        defer { repo.reset() }
        _ = try await repo.loadSubAgentChildren(sessionId: "session", parentItemId: "card-1",
                                                beforeOrderSeq: 42, limit: 25)
        let call = try #require(http.calls.last)
        #expect(call.path.hasSuffix("/sessions/session/timeline"))
        #expect(Dictionary(uniqueKeysWithValues: call.query.map { ($0.name, $0.value ?? "") })
            == ["mode": "children", "limit": "25", "beforeOrderSeq": "42", "parentItemId": "card-1"])
    }

    @Test func theChildrenReadKeepsTheOfflineGate() async throws {
        let http = TestHTTPTransport()
        let repo = repository(transport: http)
        defer { repo.reset() }
        repo.updateConnectivity(V2NetworkStatus(availability: .offline))
        await #expect(throws: V2ClientFailure.self) {
            _ = try await repo.loadSubAgentChildren(sessionId: "session", parentItemId: "card")
        }
        #expect(http.calls.isEmpty)
    }
}

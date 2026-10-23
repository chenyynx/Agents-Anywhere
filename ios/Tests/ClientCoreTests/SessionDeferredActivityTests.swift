import Foundation
import Testing
@testable import ClientCore

/// `deferActivity`: the window reads opt in, summary rows are replaceable by
/// the single-item read, the open-time repair runs at most once per process,
/// and the archive carries the mode across a relaunch.
@Suite @MainActor struct SessionDeferredActivityTests {
    private func location() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("aa-deferred-tests-" + UUID().uuidString)
    }

    private func makeRepository(_ http: TestHTTPTransport, localStore: V2LocalStore? = nil) -> V2SessionRepository {
        let runtime = V2RuntimeAPI(transport: http)
        return V2SessionRepository(
            scope: V2ClientScope(serverURL: URL(string: "https://example.test/api/v2")!, accountID: "account"),
            detail: V2SessionDetailService(sessionAPI: V2SessionAPI(transport: http), runtimeAPI: runtime,
                                           realtimeAPI: TestRealtimeAPI()),
            interactions: V2RuntimeInteractionService(runtimeAPI: runtime),
            policy: V2SessionCachePolicy(), localStore: localStore,
            sleep: { _ in try await Task.sleep(for: .milliseconds(1)) })
    }

    private func snapshotResponse(items: [[String: Any]], hasMore: Bool,
                                  excludesAgentChildren: Bool? = true,
                                  deferredActivity: Bool? = nil) throws -> Data {
        var response = try fixtureObject("snapshot")
        var timeline = response["timeline"] as! [String: Any]
        timeline["items"] = items; timeline["hasMore"] = hasMore
        response["timeline"] = timeline
        if let excludesAgentChildren { response["excludesAgentChildren"] = excludesAgentChildren }
        if let deferredActivity { response["deferredActivity"] = deferredActivity }
        return try JSONSerialization.data(withJSONObject: response)
    }

    private func pageResponse(items: [[String: Any]], hasMore: Bool,
                              excludesAgentChildren: Bool? = true,
                              deferredActivity: Bool? = nil) throws -> Data {
        var object: [String: Any] = ["sessionId": "session", "items": items, "nextSeq": 1000, "hasMore": hasMore]
        if let excludesAgentChildren { object["excludesAgentChildren"] = excludesAgentChildren }
        if let deferredActivity { object["deferredActivity"] = deferredActivity }
        return try JSONSerialization.data(withJSONObject: object)
    }

    private func deferredObject(id: String, order: Int, revision: Int = 1, bytes: Int = 4096) throws -> [String: Any] {
        var value = try itemObject(id: id, order: order, revision: revision)
        value["content"] = ["name": "bash", "deferred": true, "deferredBytes": bytes]
        return value
    }

    private func latestRequests(_ http: TestHTTPTransport) -> Int {
        http.calls.filter { call in
            call.path.hasSuffix("/timeline") && call.query.contains { $0.name == "mode" && $0.value == "latest" }
        }.count
    }

    /// A window archive as the previous build saved it: main-only rows and no
    /// `deferredActivity` field.
    private func makeArchive(_ items: [[String: Any]], hasMore: Bool = true,
                             excludesAgentChildren: Bool = true) throws -> V2SessionArchive {
        let model = makeRepository(TestHTTPTransport()).session(id: "session")
        var data = V2SessionData(snapshot: try snapshot(items: items, hasMore: hasMore))
        data.windowExcludesAgentChildren = excludesAgentChildren
        return V2SessionArchive(data: data, model: model)
    }

    // MARK: Request contract

    @Test func windowReadsSendDeferActivityWithTheExclusion() async throws {
        let http = TestHTTPTransport()
        http.respond = { call in
            if call.path.hasSuffix("snapshot") {
                return try self.snapshotResponse(items: [try itemObject(id: "main", order: 5)], hasMore: true)
            }
            return try self.pageResponse(items: [try itemObject(id: "main", order: 5)], hasMore: true)
        }
        let repo = makeRepository(http)
        defer { repo.reset() }
        _ = try await repo.load(sessionId: "session")
        _ = try await repo.loadOlder(sessionId: "session")
        _ = try await repo.loadLatest(sessionId: "session")

        let windowCalls = http.calls.filter {
            $0.path.hasSuffix("snapshot") || $0.path.hasSuffix("/timeline")
        }
        #expect(windowCalls.count == 3)
        for call in windowCalls {
            let carriesDefer = call.query.contains { $0.name == "deferActivity" && $0.value == "true" }
            let carriesExclusion = call.query.contains { $0.name == "excludeAgentChildren" && $0.value == "true" }
            #expect(carriesDefer)
            #expect(carriesExclusion)
        }

        // The incremental feed and the panel's child read must never ask for
        // summaries: both carry rows that a second read would have to complete.
        let api = V2SessionAPI(transport: http)
        _ = try await api.timelineChanges(sessionId: "session", afterSeq: 40, limit: 500)
        _ = try await api.timelineChildren(sessionId: "session", parentItemId: "card",
                                           beforeOrderSeq: nil, limit: 100)
        for call in http.calls.suffix(2) {
            let carriesDefer = call.query.contains { $0.name == "deferActivity" }
            #expect(!carriesDefer)
        }
    }

    @Test func aMissingEchoIsNotTheSameAsAnExplicitFalse() throws {
        // 老服务端: absent. Only this retires the open-time repair.
        let absent: V2SessionTimelinePage = try decode([
            "sessionId": "session", "items": [], "nextSeq": 10, "hasMore": false,
        ])
        #expect(absent.deferredActivity == nil)
        // A current server answered without deferring this read.
        let explicitFalse: V2SessionTimelinePage = try decode([
            "sessionId": "session", "items": [], "nextSeq": 10, "hasMore": false,
            "deferredActivity": false,
        ])
        #expect(explicitFalse.deferredActivity == false)
        let honored: V2SessionTimelinePage = try decode([
            "sessionId": "session", "items": [], "nextSeq": 10, "hasMore": false,
            "deferredActivity": true,
        ])
        #expect(honored.deferredActivity == true)
        let plainSnapshot: V2SessionSnapshot = try fixture("snapshot")
        #expect(!V2SessionData(snapshot: plainSnapshot).windowDeferredActivity)

        let snapshot: V2SessionSnapshot = try fixture("snapshot")
        #expect(snapshot.deferredActivity == nil)
        var object = try fixtureObject("snapshot")
        object["deferredActivity"] = true
        #expect(try decode(object, as: V2SessionSnapshot.self).deferredActivity == true)
    }

    // MARK: Open-time repair

    @Test func anOldArchiveReReadsItsWindowOnceDeferred() async throws {
        let url = location(); defer { try? FileManager.default.removeItem(at: url) }
        let store = V2LocalStore(directory: url)
        await store.saveSession(try makeArchive([try itemObject(id: "main", order: 3)]))
        let http = TestHTTPTransport()
        http.respond = { _ in
            try self.pageResponse(items: [try itemObject(id: "main", order: 3)], hasMore: true,
                                  deferredActivity: true)
        }
        let repo = makeRepository(http, localStore: store)
        defer { repo.reset() }

        let first = try await repo.open(sessionId: "session")
        #expect(latestRequests(http) == 1)
        #expect(first.windowDeferredActivity)
        // The echo is the proof: a deferred window is not re-read on every visit.
        _ = try await repo.open(sessionId: "session")
        #expect(latestRequests(http) == 1)
        await store.close(removing: true)
    }

    @Test func aServerWithoutTheFeatureIsAskedAtMostOnce() async throws {
        let url = location(); defer { try? FileManager.default.removeItem(at: url) }
        let store = V2LocalStore(directory: url)
        await store.saveSession(try makeArchive([try itemObject(id: "main", order: 3)]))
        let http = TestHTTPTransport()
        http.respond = { _ in
            // 老服务端: no echo, but it still honours the exclusion flag.
            try self.pageResponse(items: [try itemObject(id: "main", order: 3)], hasMore: true,
                                  deferredActivity: nil)
        }
        let repo = makeRepository(http, localStore: store)
        defer { repo.reset() }

        let first = try await repo.open(sessionId: "session")
        #expect(latestRequests(http) == 1)
        #expect(!first.windowDeferredActivity)
        // The process-local mark retires the repair instead of re-asking.
        _ = try await repo.open(sessionId: "session")
        #expect(latestRequests(http) == 1)
        await store.close(removing: true)
    }

    @Test func aCurrentServerThatSkippedDeferralIsAskedAgain() async throws {
        let url = location(); defer { try? FileManager.default.removeItem(at: url) }
        let store = V2LocalStore(directory: url)
        await store.saveSession(try makeArchive([try itemObject(id: "main", order: 3)]))
        let http = TestHTTPTransport()
        http.respond = { _ in
            // A current server, but this read did not defer (no display row to
            // anchor on). That is not proof the server lacks the feature.
            try self.pageResponse(items: [try itemObject(id: "main", order: 3)], hasMore: true,
                                  deferredActivity: false)
        }
        let repo = makeRepository(http, localStore: store)
        defer { repo.reset() }

        let first = try await repo.open(sessionId: "session")
        #expect(latestRequests(http) == 1)
        #expect(!first.windowDeferredActivity)
        _ = try await repo.open(sessionId: "session")
        #expect(latestRequests(http) == 2)
        await store.close(removing: true)
    }

    @Test func anOfflineOpenKeepsTheCachedWindow() async throws {
        let url = location(); defer { try? FileManager.default.removeItem(at: url) }
        let store = V2LocalStore(directory: url)
        await store.saveSession(try makeArchive([try itemObject(id: "main", order: 3)]))
        let http = TestHTTPTransport()
        let repo = makeRepository(http, localStore: store)
        defer { repo.reset() }
        repo.updateConnectivity(V2NetworkStatus(availability: .offline))

        let data = try await repo.open(sessionId: "session")
        #expect(http.calls.isEmpty)
        #expect(data.items.map(\.id) == ["main"])
        await store.close(removing: true)
    }

    // MARK: Window length

    @Test func theDeferredWindowTrimsCachedHistoryToTheConstant() async throws {
        let url = location(); defer { try? FileManager.default.removeItem(at: url) }
        let items = try (1...1000).map { try itemObject(id: "item-\($0)", order: $0) }
        let store = V2LocalStore(directory: url)
        await store.saveSession(try makeArchive(items, excludesAgentChildren: false))
        let http = TestHTTPTransport()
        let repo = makeRepository(http, localStore: store)
        defer { repo.reset() }

        let opened = try await repo.open(sessionId: "session")
        #expect(V2SessionCachePolicy.deferredWindowItems == 150)
        #expect(opened.items.count == 150)
        #expect(opened.items.first?.id == "item-851")
        #expect(opened.items.last?.id == "item-1000")
        #expect(http.calls.isEmpty)
        await store.close(removing: true)
    }

    @Test func theChatFirstScreenMatchesTheOpenWindow() async throws {
        let url = location(); defer { try? FileManager.default.removeItem(at: url) }
        let items = try (1...1000).map { try itemObject(id: "item-\($0)", order: $0) }
        let store = V2LocalStore(directory: url)
        await store.saveSession(try makeArchive(items, excludesAgentChildren: false))
        let http = TestHTTPTransport()
        let repo = makeRepository(http, localStore: store)
        defer { repo.reset() }
        repo.updateConnectivity(V2NetworkStatus(availability: .offline))
        _ = try await repo.load(sessionId: "session")

        let chat = SessionChatModel(session: repo.session(id: "session"), repository: repo,
                                    attachments: V2AttachmentService(attachmentAPI: V2AttachmentAPI(transport: http)))
        await chat.prepareOpening()
        #expect(chat.timeline.rows.count == V2SessionCachePolicy.deferredWindowItems)
        #expect(chat.timeline.rows.last?.id == "item-1000")
        await store.close(removing: true)
    }

    // MARK: In-place replacement

    @Test func aCompleteRowReplacesItsSummaryInPlace() throws {
        let items = [try itemObject(id: "first", order: 1), try deferredObject(id: "tool", order: 2),
                     try itemObject(id: "last", order: 3)]
        var projection = V2SessionProjection(snapshot: try snapshot(items: items, hasMore: true), maximumItems: 100)
        let hasOlder = projection.data.hasOlderItems

        let full: V2TimelineItem = try decode(itemObject(id: "tool", order: 2, revision: 1))
        let replaced = projection.replaceDeferredItem(full)
        #expect(replaced)
        #expect(projection.data.items.map(\.id) == ["first", "tool", "last"])
        #expect(projection.data.items[1].isDeferred == false)
        #expect(projection.data.hasOlderItems == hasOlder)
        #expect(projection.data.hasNewerItems == false)
    }

    @Test func aStaleRowNeverReplacesANewerOne() throws {
        let items = [try itemObject(id: "tool", order: 2, revision: 3)]
        var projection = V2SessionProjection(snapshot: try snapshot(items: items), maximumItems: 100)
        let stale: V2TimelineItem = try decode(itemObject(id: "tool", order: 2, revision: 2))
        let replaced = projection.replaceDeferredItem(stale)
        #expect(replaced == false)
        #expect(projection.data.items.first?.revision == 3)
    }

    @Test func aStaleCompleteRowNeverReplacesANewerSummary() throws {
        // The summary itself was refreshed to revision 3 while the single-row
        // read was in flight; the late revision-2 body must not roll it back.
        let summary = try deferredObject(id: "tool", order: 2, revision: 3)
        var projection = V2SessionProjection(snapshot: try snapshot(items: [summary]), maximumItems: 100)
        let stale: V2TimelineItem = try decode(itemObject(id: "tool", order: 2, revision: 2))
        let replaced = projection.replaceDeferredItem(stale)
        #expect(replaced == false)
        #expect(projection.data.items.first?.revision == 3)
        #expect(projection.data.items.first?.isDeferred == true)
    }

    @Test func aRowOutsideTheWindowIsNeverInserted() throws {
        let items = [try itemObject(id: "tool", order: 2)]
        var projection = V2SessionProjection(snapshot: try snapshot(items: items), maximumItems: 100)
        let outside: V2TimelineItem = try decode(itemObject(id: "outside", order: 9))
        let replaced = projection.replaceDeferredItem(outside)
        #expect(replaced == false)
        #expect(projection.data.items.map(\.id) == ["tool"])
    }

    @Test func aDeferredReasoningSummaryStaysVisibleWithItsHead() throws {
        // The budget trim may summarise a thinking row, but never to an empty
        // shell: the Chat page hides a reasoning row whose text is empty, so
        // the summary must keep a readable head and the single-item read
        // completes it on expand.
        var value = try itemObject(id: "r1", order: 1)
        value["type"] = "system"
        value["content"] = [
            "kind": "reasoning",
            "text": "opening thought…",
            "deferred": true,
            "deferredBytes": 20000,
        ]
        let item: V2TimelineItem = try decode(value)
        #expect(item.isReasoning && item.isDeferred)
        #expect(item.isVisibleInChat)
        #expect(!item.displayText.isEmpty)
        #expect(TimelineEntryPresentation(item: item, cwd: nil).kind == .reasoning)
    }

    // MARK: Archive round trip

    @Test func aDeferredArchiveRoundTripsAndAnOldOneStillDecodes() throws {
        let model = makeRepository(TestHTTPTransport()).session(id: "session")
        var data = V2SessionData(snapshot: try snapshot(items: [try deferredObject(id: "tool", order: 1)],
                                                        hasMore: true))
        data.windowDeferredActivity = true
        let archive = V2SessionArchive(data: data, model: model)
        #expect(archive.deferredActivity == true)

        let bytes = try JSONEncoder().encode(archive)
        let decoded = try JSONDecoder().decode(V2SessionArchive.self, from: bytes)
        #expect(decoded.deferredActivity == true)
        let restored = decoded.projection(items: data.items, maximumItems: 100)
        #expect(restored.data.windowDeferredActivity)
        #expect(restored.data.items.first?.isDeferred == true)

        // 旧归档: the key is absent, which reads as "not a deferred window".
        var object = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
        object.removeValue(forKey: "deferredActivity")
        let old = try JSONDecoder().decode(V2SessionArchive.self,
            from: JSONSerialization.data(withJSONObject: object))
        #expect(old.deferredActivity == nil)
        #expect(old.projection(items: data.items, maximumItems: 100).data.windowDeferredActivity == false)
    }
}

/// The per-row read store behind a deferred summary row.
@Suite @MainActor struct DeferredItemStoreTests {
    private func item(_ id: String, order: Int = 1, deferred: Bool = true, bytes: Int? = 1024) throws -> V2TimelineItem {
        var value = try itemObject(id: id, order: order)
        var content: [String: Any] = ["name": "bash"]
        if deferred { content["deferred"] = true }
        if let bytes { content["deferredBytes"] = bytes }
        value["content"] = content
        return try decode(value)
    }

    @Test func aSuccessfulReadReturnsToIdle() async throws {
        var reads: [V2TimelineItemID] = []
        let store = DeferredItemStore { id in reads.append(id) }
        store.load("row")
        try await eventually { reads == ["row"] }
        try await eventually { store.phase("row") == .idle }
    }

    @Test func failureAndOfflineAreClassified() async throws {
        let store = DeferredItemStore { id in
            if id == "offline" { throw V2ClientFailure(kind: .offline, message: "offline") }
            throw HTTPError.server(statusCode: 404, message: "missing")
        }
        store.load("missing")
        store.load("offline")
        try await eventually { store.phase("missing") == .failed }
        try await eventually { store.phase("offline") == .offline }
    }

    @Test func aFailedRowCanBeRetried() async throws {
        var attempts = 0
        let store = DeferredItemStore { _ in
            attempts += 1
            if attempts == 1 { throw HTTPError.server(statusCode: 500, message: "boom") }
        }
        store.load("row")
        try await eventually { store.phase("row") == .failed }
        store.retry("row")
        try await eventually { attempts == 2 }
        try await eventually { store.phase("row") == .idle }
    }

    @Test func theSameRowIsReadOnceAtATime() async throws {
        var started = 0
        let gate = TestGate()
        let store = DeferredItemStore { _ in started += 1; await gate.wait() }
        store.load("row")
        store.load("row")
        try await eventually { started == 1 }
        gate.release()
        try await eventually { store.phase("row") == .idle }
        #expect(started == 1)
    }

    @Test func cancellationLeavesNoPhaseBehind() async throws {
        let store = DeferredItemStore { _ in
            try await Task.sleep(for: .seconds(30))
        }
        store.load("row")
        store.cancelAll()
        try await Task.sleep(for: .milliseconds(20))
        #expect(store.phase("row") == .idle)
    }

    @Test func prefetchTakesOnlyDeferredSmallRowsWithinBudget() async throws {
        var reads: [V2TimelineItemID] = []
        let store = DeferredItemStore { id in reads.append(id) }
        var items = [try item("a"), try item("b", deferred: false),
                     try item("c", bytes: 100_000), try item("d", bytes: nil)]
        items += try (0..<20).map { try item("e\($0)") }
        store.prefetch(items)
        try await eventually { reads.count == 12 }
        #expect(reads.first == "a")
        #expect(!reads.contains("b") && !reads.contains("c") && !reads.contains("d"))
        #expect(reads.filter { $0.hasPrefix("e") }.count == 11)
    }

    @Test func prefetchRespectsTheByteBudget() async throws {
        var reads: [V2TimelineItemID] = []
        let store = DeferredItemStore { id in reads.append(id) }
        store.prefetch(try (0..<12).map { try item("big\($0)", bytes: 50_000) })
        try await eventually { reads.count == 10 }
        try await Task.sleep(for: .milliseconds(20))
        // 512KB / 50KB: ten rows fit, the remaining budget cannot take an 11th.
        #expect(reads.count == 10)
    }
}

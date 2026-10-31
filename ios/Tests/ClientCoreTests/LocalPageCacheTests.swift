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

import Foundation
import Testing
@testable import ClientCore

@Suite @MainActor struct LocalPageCacheTests {
    private func location() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("aa-page-cache-\(UUID().uuidString)", isDirectory: true)
    }

    private func seed(_ store: V2LocalStore, count: Int, hasMore: Bool = false) async throws {
        let http = TestHTTPTransport()
        let probe = repository(transport: http, localStore: store)
        let data = V2SessionData(snapshot: try snapshot(items: (1...count).map {
            try itemObject(id: "item-\($0)", order: $0, seq: $0)
        }, hasMore: hasMore))
        await store.saveSession(V2SessionArchive(data: data, model: probe.session(id: "session")))
        probe.reset()
        await store.close(removing: false)
    }

    @Test func olderPagesComeFromDiskWithoutNetwork() async throws {
        let url = location(); defer { try? FileManager.default.removeItem(at: url) }
        try await seed(V2LocalStore(directory: url, timelineDatabaseEnabled: true), count: 300)

        let http = TestHTTPTransport()
        let store = V2LocalStore(directory: url, timelineDatabaseEnabled: true)
        let repo = repository(transport: http, localStore: store)
        repo.updateConnectivity(.init(availability: .offline))
        let opening = try await repo.open(sessionId: "session")
        #expect(opening.items.map(\.orderSeq) == Array(201...300))
        #expect(opening.localOlderAvailable && opening.canLoadOlder)

        let first = try await repo.loadOlder(sessionId: "session")
        #expect(first.items.map(\.orderSeq) == Array(101...300))
        #expect(first.localOlderAvailable && first.canLoadOlder)

        let second = try await repo.loadOlder(sessionId: "session")
        #expect(second.items.map(\.orderSeq) == Array(1...300))
        #expect(!second.localOlderAvailable && !second.canLoadOlder)
        #expect(http.calls.isEmpty)

        repo.reset(); await store.close(removing: true)
    }

    @Test func latestPagesComeFromDiskAfterTheWindowSlides() async throws {
        let url = location(); defer { try? FileManager.default.removeItem(at: url) }
        try await seed(V2LocalStore(directory: url, timelineDatabaseEnabled: true), count: 300)

        let http = TestHTTPTransport()
        let store = V2LocalStore(directory: url, timelineDatabaseEnabled: true)
        var policy = V2SessionCachePolicy()
        policy.maximumTimelineItems = 150
        let repo = repository(transport: http, policy: policy, localStore: store)
        repo.updateConnectivity(.init(availability: .offline))
        _ = try await repo.open(sessionId: "session")

        let older = try await repo.loadOlder(sessionId: "session")
        #expect(older.items.map(\.orderSeq) == Array(101...250))
        #expect(older.hasNewerItems)

        let latest = try await repo.loadLatest(sessionId: "session")
        #expect(latest.items.map(\.orderSeq) == Array(201...300))
        #expect(!latest.hasNewerItems)
        #expect(latest.localOlderAvailable)
        #expect(http.calls.isEmpty)

        repo.reset(); await store.close(removing: true)
    }
}

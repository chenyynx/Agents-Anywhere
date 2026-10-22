import Foundation
import Testing
@testable import ClientCore

/// C2: the window reads opt in to main-agent rows only (`excludeAgentChildren`),
/// the open path re-anchors a child-only cached window on one latest page, and
/// an older server's response still decodes (absent flag reads `false`).
@Suite @MainActor struct SessionAgentChildrenRequestTests {
    private func windowItem(id: String, order: Int, parentItemId: String? = nil) throws -> [String: Any] {
        var value = try itemObject(id: id, order: order)
        var content: [String: Any] = ["text": "Row \(id)"]
        if let parentItemId { content["parentItemId"] = parentItemId }
        value["content"] = content
        return value
    }

    private func snapshotResponse(items: [[String: Any]], hasMore: Bool,
                                  excludesAgentChildren: Bool? = nil) throws -> Data {
        var response = try fixtureObject("snapshot")
        var timeline = response["timeline"] as! [String: Any]
        timeline["items"] = items; timeline["hasMore"] = hasMore
        response["timeline"] = timeline
        if let excludesAgentChildren { response["excludesAgentChildren"] = excludesAgentChildren }
        return try JSONSerialization.data(withJSONObject: response)
    }

    private func pageResponse(items: [[String: Any]], hasMore: Bool,
                              excludesAgentChildren: Bool? = nil) throws -> Data {
        var object: [String: Any] = [
            "sessionId": "session", "items": items, "nextSeq": 1000, "hasMore": hasMore,
        ]
        if let excludesAgentChildren { object["excludesAgentChildren"] = excludesAgentChildren }
        return try JSONSerialization.data(withJSONObject: object)
    }

    private func latestRequests(_ http: TestHTTPTransport) -> Int {
        http.calls.filter { call in
            call.path.hasSuffix("/timeline") && call.query.contains { $0.name == "mode" && $0.value == "latest" }
        }.count
    }

    private func carriesExclusion(_ call: TestHTTPTransport.Call) -> Bool {
        call.query.contains { $0.name == "excludeAgentChildren" && $0.value == "true" }
    }

    @Test func windowReadsOptInToMainAgentRows() async throws {
        let http = TestHTTPTransport()
        http.respond = { call in
            if call.path.hasSuffix("snapshot") {
                return try self.snapshotResponse(items: [self.windowItem(id: "main", order: 1)], hasMore: true)
            }
            return try self.pageResponse(items: [self.windowItem(id: "main", order: 1)], hasMore: true)
        }
        let repo = repository(transport: http)
        defer { repo.reset() }
        _ = try await repo.load(sessionId: "session")
        _ = try await repo.loadOlder(sessionId: "session")
        _ = try await repo.loadLatest(sessionId: "session")

        let snapshot = try #require(http.calls.first { $0.path.hasSuffix("snapshot") })
        #expect(carriesExclusion(snapshot))
        let history = try #require(http.calls.first { call in
            call.path.hasSuffix("/timeline") && call.query.contains { $0.name == "mode" && $0.value == "history" }
        })
        #expect(carriesExclusion(history))
        let latest = try #require(http.calls.first { call in
            call.path.hasSuffix("/timeline") && call.query.contains { $0.name == "mode" && $0.value == "latest" }
        })
        #expect(carriesExclusion(latest))
    }

    @Test func aChildOnlyCachedWindowRefetchesTheLatestPageOnOpen() async throws {
        let http = TestHTTPTransport()
        http.respond = { call in
            if call.path.hasSuffix("snapshot") {
                return try self.snapshotResponse(
                    items: [self.windowItem(id: "a1", order: 1, parentItemId: "card")], hasMore: true)
            }
            return try self.pageResponse(
                items: [self.windowItem(id: "a2", order: 2, parentItemId: "card")], hasMore: true)
        }
        let repo = repository(transport: http)
        defer { repo.reset() }
        _ = try await repo.open(sessionId: "session")
        // No newer rows were flagged: the child-only window is what asks for
        // the latest page, so the reader never lands on a blank timeline.
        #expect(latestRequests(http) == 1)
    }

    @Test func aWindowWithAMainRowDoesNotRefetch() async throws {
        let http = TestHTTPTransport()
        http.respond = { call in
            if call.path.hasSuffix("snapshot") {
                return try self.snapshotResponse(items: [
                    self.windowItem(id: "main", order: 1),
                    self.windowItem(id: "a1", order: 2, parentItemId: "card"),
                ], hasMore: true)
            }
            return try self.pageResponse(items: [self.windowItem(id: "main", order: 1)], hasMore: true)
        }
        let repo = repository(transport: http)
        defer { repo.reset() }
        _ = try await repo.open(sessionId: "session")
        #expect(latestRequests(http) == 0)
    }

    @Test func anOfflineChildOnlyWindowKeepsTheCachedRows() async throws {
        let http = TestHTTPTransport()
        http.respond = { call in
            if call.path.hasSuffix("snapshot") {
                return try self.snapshotResponse(
                    items: [self.windowItem(id: "a1", order: 1, parentItemId: "card")], hasMore: true)
            }
            return try self.pageResponse(
                items: [self.windowItem(id: "a2", order: 2, parentItemId: "card")], hasMore: true)
        }
        let repo = repository(transport: http)
        defer { repo.reset() }
        let opened = try await repo.open(sessionId: "session")
        #expect(latestRequests(http) == 1)
        #expect(opened.items.map(\.id) == ["a2"])
        repo.updateConnectivity(V2NetworkStatus(availability: .offline))
        let cached = try await repo.open(sessionId: "session")
        // The C0 fallback renders the cached window; no network is spent.
        #expect(latestRequests(http) == 1)
        #expect(cached.items.map(\.id) == ["a2"])
    }

    @Test func theServerEchoReachesTheModelAndTheArchive() async throws {
        let http = TestHTTPTransport()
        http.respond = { call in
            if call.path.hasSuffix("snapshot") {
                return try self.snapshotResponse(items: [self.windowItem(id: "main", order: 1)],
                                                 hasMore: true, excludesAgentChildren: true)
            }
            return try self.pageResponse(items: [self.windowItem(id: "main", order: 1)],
                                         hasMore: true, excludesAgentChildren: true)
        }
        let repo = repository(transport: http)
        defer { repo.reset() }
        let data = try await repo.load(sessionId: "session")
        #expect(data.windowExcludesAgentChildren)
        #expect(repo.session(id: "session").windowExcludesAgentChildren)
        // A cold relaunch restores from the archive, so the mode has to live
        // there too or the panel would go back to trusting the card row.
        let archive = V2SessionArchive(data: data, model: repo.session(id: "session"))
        #expect(archive.excludesAgentChildren == true)
        let decoded = try JSONDecoder().decode(V2SessionArchive.self, from: JSONEncoder().encode(archive))
        let restored = decoded.projection(items: data.items, maximumItems: 100)
        #expect(restored.data.windowExcludesAgentChildren)
    }

    @Test func aLatestPageOwnsTheWindowMode() async throws {
        let http = TestHTTPTransport()
        http.respond = { call in
            if call.path.hasSuffix("snapshot") {
                return try self.snapshotResponse(items: [self.windowItem(id: "main", order: 1)], hasMore: true)
            }
            return try self.pageResponse(items: [self.windowItem(id: "main", order: 1)],
                                         hasMore: true, excludesAgentChildren: true)
        }
        let repo = repository(transport: http)
        defer { repo.reset() }
        let loaded = try await repo.load(sessionId: "session")
        #expect(!loaded.windowExcludesAgentChildren)
        let latest = try await repo.loadLatest(sessionId: "session")
        #expect(latest.windowExcludesAgentChildren)
        #expect(repo.session(id: "session").windowExcludesAgentChildren)
    }

    @Test func responsesWithoutTheExclusionFlagStillDecode() throws {
        // 老服务端: the key is absent, which must read as "not excluded" so the
        // client-side fallback stays in charge.
        let snapshot: V2SessionSnapshot = try fixture("snapshot")
        #expect(snapshot.excludesAgentChildren == false)
        let page: V2SessionTimelinePage = try decode([
            "sessionId": "session", "items": [], "nextSeq": 10, "hasMore": false,
        ])
        #expect(page.excludesAgentChildren == false)
        let honoredPage: V2SessionTimelinePage = try decode([
            "sessionId": "session", "items": [], "nextSeq": 10, "hasMore": false, "excludesAgentChildren": true,
        ])
        #expect(honoredPage.excludesAgentChildren)
        var honored = try fixtureObject("snapshot")
        honored["excludesAgentChildren"] = true
        #expect(try decode(honored, as: V2SessionSnapshot.self).excludesAgentChildren)
    }
}

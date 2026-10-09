import Foundation
import Synchronization
import Testing
@testable import ClientCore

/// session-open-coverage P3: SubAgent detail rows load on demand through the
/// timeline's `mode=children` read and merge into the projection's detail
/// sidecar. The window, its paging cursor and its history flags are untouched;
/// the panel reads the window ∪ sidecar union.
@Suite @MainActor struct SubAgentDetailLoadTests {
    private func snapshotData(items: [[String: Any]], hasMore: Bool = false) throws -> Data {
        var object = try fixtureObject("snapshot")
        var meta = object["session"] as! [String: Any]; meta["id"] = "session"; object["session"] = meta
        var state = object["state"] as! [String: Any]; state["sessionId"] = "session"; object["state"] = state
        var timeline = object["timeline"] as! [String: Any]
        timeline["items"] = items; timeline["hasMore"] = hasMore; object["timeline"] = timeline
        return try JSONSerialization.data(withJSONObject: object)
    }

    private func pageData(_ items: [[String: Any]], hasMore: Bool) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["sessionId": "session", "items": items,
            "nextSeq": 1000, "hasMore": hasMore])
    }

    private func cardObject(id: String, order: Int) throws -> [String: Any] {
        var value = try itemObject(id: id, order: order, text: "card")
        value["type"] = "tool"; value["status"] = "done"
        value["content"] = ["kind": "agent_call", "action": "invoke", "description": "排查服务状态",
                            "agents": ["t1": ["status": "completed"]], "summary": "done"]
        return value
    }

    private func childObject(id: String, order: Int, parent: String) throws -> [String: Any] {
        var value = try itemObject(id: id, order: order, text: "step")
        value["type"] = "tool"; value["status"] = "done"
        value["content"] = ["kind": "command", "command": "ls -la", "parentItemId": parent]
        return value
    }

    private func child(_ id: String, order: Int, parent: String = "card") throws -> V2TimelineItem {
        try decode(childObject(id: id, order: order, parent: parent))
    }

    @Test func onDemandChildrenMergeIntoTheSidecarAndLeaveTheWindowAlone() async throws {
        let http = TestHTTPTransport()
        let pages = Mutex(0)
        http.respond = { call in
            if call.path.hasSuffix("snapshot") {
                return try self.snapshotData(items: [try self.cardObject(id: "card", order: 1)], hasMore: false)
            }
            if call.path.hasSuffix("timeline") {
                let index = pages.withLock { $0 += 1; return $0 }
                if index % 2 == 1 {
                    return try self.pageData([try self.childObject(id: "child-a", order: 5, parent: "card"),
                                              try self.childObject(id: "child-b", order: 6, parent: "card")], hasMore: true)
                }
                return try self.pageData([try self.childObject(id: "child-c", order: 3, parent: "card"),
                                          try self.childObject(id: "child-d", order: 4, parent: "card")], hasMore: false)
            }
            return try http.defaultResponse(call)
        }
        let repo = repository(transport: http)
        defer { repo.reset() }
        _ = try await repo.open(sessionId: "session")
        let before = try #require(repo.cached(sessionId: "session"))

        await repo.loadSubAgentDetail(sessionId: "session", parentIDs: ["card"])
        let after = try #require(repo.cached(sessionId: "session"))
        #expect(after.subAgentChildren.map(\.id) == ["child-c", "child-d", "child-a", "child-b"])
        #expect(after.items == before.items, "Detail rows never join the window")
        #expect(after.hasOlderItems == before.hasOlderItems)
        #expect(after.hasNewerItems == before.hasNewerItems)
        #expect(after.cursor == before.cursor)

        // Re-fetching is id-keyed and idempotent: no duplicate rows.
        await repo.loadSubAgentDetail(sessionId: "session", parentIDs: ["card"])
        #expect(repo.cached(sessionId: "session")?.subAgentChildren.count == 4)

        // Contract #5: the children read is newest → oldest through
        // parentId/beforeOrderSeq, and never carries the exclude filter.
        let childCalls = http.calls.filter { call in
            call.query.contains(URLQueryItem(name: "mode", value: "children"))
        }
        #expect(childCalls.count == 4)
        #expect(childCalls[0].query == [URLQueryItem(name: "mode", value: "children"),
                                        URLQueryItem(name: "limit", value: "100"),
                                        URLQueryItem(name: "parentId", value: "card")])
        #expect(childCalls[1].query == [URLQueryItem(name: "mode", value: "children"),
                                        URLQueryItem(name: "limit", value: "100"),
                                        URLQueryItem(name: "beforeOrderSeq", value: "5"),
                                        URLQueryItem(name: "parentId", value: "card")])
        #expect(childCalls.allSatisfy { call in
            !call.query.contains { $0.name == "exclude" }
        })
    }

    @Test func aPageForAnUnrequestedParentContributesNothing() async throws {
        let http = TestHTTPTransport()
        http.respond = { call in
            if call.path.hasSuffix("snapshot") {
                return try self.snapshotData(items: [try self.cardObject(id: "card", order: 1)], hasMore: false)
            }
            if call.path.hasSuffix("timeline") {
                return try self.pageData([try self.childObject(id: "stray", order: 9, parent: "other-card")], hasMore: false)
            }
            return try http.defaultResponse(call)
        }
        let repo = repository(transport: http)
        defer { repo.reset() }
        _ = try await repo.open(sessionId: "session")

        await repo.loadSubAgentDetail(sessionId: "session", parentIDs: ["card"])
        #expect(repo.cached(sessionId: "session")?.subAgentChildren.isEmpty == true,
                "A child of the wrong parent must not enter the sidecar")
    }

    @Test func aFailedDetailLoadLeavesTheSidecarAndTheWindowAlone() async throws {
        let http = TestHTTPTransport()
        http.respond = { call in
            if call.path.hasSuffix("snapshot") {
                return try self.snapshotData(items: [try self.cardObject(id: "card", order: 1)], hasMore: false)
            }
            if call.path.hasSuffix("timeline") { throw URLError(.timedOut) }
            return try http.defaultResponse(call)
        }
        let repo = repository(transport: http)
        defer { repo.reset() }
        _ = try await repo.open(sessionId: "session")
        let before = try #require(repo.cached(sessionId: "session"))

        await repo.loadSubAgentDetail(sessionId: "session", parentIDs: ["card"])
        let after = try #require(repo.cached(sessionId: "session"))
        #expect(after.subAgentChildren.isEmpty)
        #expect(after.items == before.items)
    }

    @Test func thePanelUnionSeesTheDetailRowsWithoutDuplicatingThem() throws {
        let cardItem: V2TimelineItem = try decode(cardObject(id: "card", order: 1))
        let window = [cardItem]
        let children = [try child("child-a", order: 5), try child("child-b", order: 6)]
        let card = try #require(SubAgentProgress.card(cardItem))

        // The card's own row makes the panel "loaded" while its activity rows
        // may still be missing entirely — that shape is the lazy load's state
        // bit (`hasDetailRows`), and the union turns it true.
        #expect(SubAgentProgress.isContentLoaded(card, in: window))
        #expect(!SubAgentProgress.hasDetailRows(card, in: window))
        #expect(SubAgentProgress.hasDetailRows(card, in: window + children))
        #expect(SubAgentProgress.isContentLoaded(card, in: window + children))
        #expect(SubAgentProgress.activityRows(of: card, in: window + children).map(\.id) == ["child-a", "child-b"])
        // A card the sidecar holds and the window does not is the other miss:
        // nothing at all is loaded, and the union still satisfies both bits.
        #expect(!SubAgentProgress.isContentLoaded(card, in: []))
        #expect(!SubAgentProgress.hasDetailRows(card, in: []))
        #expect(SubAgentProgress.isContentLoaded(card, in: children))
        #expect(SubAgentProgress.hasDetailRows(card, in: children))

        // A row present in both sets is listed once, the window's copy first.
        let duplicate = SubAgentProgress.activityRows(of: card, in: window + children + children)
        #expect(duplicate.map(\.id) == ["child-a", "child-b"])

        // The presentation publishes the sidecar as its own row models, and a
        // detail merge never touches the window's rows or the re-assert bit.
        let timeline = SessionTimelinePresentation()
        timeline.presentOpening(window, pendingMessages: [])
        timeline.stage(window, detailItems: children, animate: false)
        timeline.flush(now: 1)
        #expect(timeline.rows.map(\.id) == ["card"])
        #expect(timeline.detailRows.map(\.id) == ["child-a", "child-b"])
        #expect(timeline.windowRevision == 0)
    }
}

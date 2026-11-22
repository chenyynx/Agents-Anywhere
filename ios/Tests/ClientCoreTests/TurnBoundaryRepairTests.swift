import Foundation
import Testing
@testable import ClientCore

/// The repair that runs after a recovery snapshot whose page did not cover the
/// whole held window. A mass turn-id re-key outside the page leaves one turn
/// with two ids; the repair re-reads exactly the rows below the page until the
/// turn named at the page edge ends.
@Suite @MainActor struct TurnBoundaryRepairTests {
    private func turnItem(_ order: Int, turn: String, revision: Int = 1) throws -> [String: Any] {
        var item = try itemObject(id: "item-\(order)", order: order,
                                  revision: revision, text: "row \(order)")
        item["source"] = ["turnId": turn]
        return item
    }

    private func snapshotData(
        _ items: [(Int, String, Int)], hasMore: Bool
    ) throws -> Data {
        var object = try fixtureObject("snapshot")
        object["eventCursor"] = "seq:4"
        var meta = object["session"] as! [String: Any]
        meta["id"] = "session"; object["session"] = meta
        var state = object["state"] as! [String: Any]
        state["sessionId"] = "session"; object["state"] = state
        var timeline = object["timeline"] as! [String: Any]
        timeline["items"] = try items.map { try turnItem($0.0, turn: $0.1, revision: $0.2) }
        timeline["hasMore"] = hasMore
        object["timeline"] = timeline
        return try JSONSerialization.data(withJSONObject: object)
    }

    private func historyData(
        _ items: [(Int, String, Int)], hasMore: Bool
    ) throws -> Data {
        var object = try fixtureObject("timeline")
        object["items"] = try items.map { try turnItem($0.0, turn: $0.1, revision: $0.2) }
        object["hasMore"] = hasMore
        return try JSONSerialization.data(withJSONObject: object)
    }

    private func historyCalls(_ http: TestHTTPTransport) -> [TestHTTPTransport.Call] {
        http.calls.filter { call in
            call.path.hasSuffix("timeline")
                && call.query.contains(URLQueryItem(name: "mode", value: "history"))
        }
    }

    @Test func aRecoverySnapshotRepairsTheStaleRowsBelowItsPage() async throws {
        let http = TestHTTPTransport(); let realtime = TestRealtimeAPI()
        let repo = repository(transport: http, realtime: realtime)
        defer { repo.reset() }
        http.respond = { call in
            if call.path.hasSuffix("snapshot") {
                let seen = http.calls.filter { $0.path.hasSuffix("snapshot") }.count
                if seen == 1 {
                    return try self.snapshotData(
                        (1...40).map { ($0, "old", 1) }, hasMore: true)
                }
                return try self.snapshotData(
                    (21...40).map { ($0, "new", 2) }, hasMore: true)
            }
            if call.path.hasSuffix("timeline") {
                return try self.historyData(
                    (1...20).map { ($0, "new", 2) }, hasMore: false)
            }
            return try http.defaultResponse(call)
        }
        let model = repo.session(id: "session")
        let task = Task { await model.connect() }
        defer { task.cancel() }
        try await eventually { repo.cached(sessionId: "session")?.items.count == 40 }

        realtime.onRecover = {
            V2EventRecoveryResponse(events: [], nextCursor: "seq:4",
                                    snapshotRequired: true, serverTime: "")
        }
        realtime.yield(try event("session.refetch_required", seq: 12))

        try await eventually {
            repo.cached(sessionId: "session")?.items.allSatisfy { $0.turnId == "new" } == true
        }
        let calls = historyCalls(http)
        #expect(calls.contains { call in
            call.query.contains(URLQueryItem(name: "beforeOrderSeq", value: "21"))
        })
        #expect(calls.count == 1)
        #expect(repo.cached(sessionId: "session")?.items.map(\.orderSeq) == Array(1...40))
    }

    @Test func aRepairStopsAtTheTurnEndingBelowThePage() async throws {
        let http = TestHTTPTransport(); let realtime = TestRealtimeAPI()
        let repo = repository(transport: http, realtime: realtime)
        defer { repo.reset() }
        http.respond = { call in
            if call.path.hasSuffix("snapshot") {
                let seen = http.calls.filter { $0.path.hasSuffix("snapshot") }.count
                if seen == 1 {
                    return try self.snapshotData(
                        (1...40).map { ($0, "old", 1) }, hasMore: true)
                }
                return try self.snapshotData(
                    (21...40).map { ($0, "new", 2) }, hasMore: true)
            }
            if call.path.hasSuffix("timeline") {
                // The page below the boundary holds the end of the repaired
                // turn and the whole previous one. One page is enough: the
                // oldest declared turn differs from the page-edge turn.
                return try self.historyData(
                    (1...10).map { ($0, "prev", 2) }
                        + (11...20).map { ($0, "new", 2) },
                    hasMore: true)
            }
            return try http.defaultResponse(call)
        }
        let model = repo.session(id: "session")
        let task = Task { await model.connect() }
        defer { task.cancel() }
        try await eventually { repo.cached(sessionId: "session")?.items.count == 40 }

        realtime.onRecover = {
            V2EventRecoveryResponse(events: [], nextCursor: "seq:4",
                                    snapshotRequired: true, serverTime: "")
        }
        realtime.yield(try event("session.refetch_required", seq: 12))

        try await eventually {
            repo.cached(sessionId: "session")?.items.first(where: { $0.orderSeq == 1 })?.turnId == "prev"
        }
        #expect(historyCalls(http).count == 1)
        #expect(repo.cached(sessionId: "session")?.items.allSatisfy {
            $0.turnId == "new" || $0.turnId == "prev"
        } == true)
    }
}

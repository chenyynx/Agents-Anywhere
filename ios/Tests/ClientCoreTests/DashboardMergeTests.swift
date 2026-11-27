import Foundation
import Testing
@testable import ClientCore

/// Locks the extracted merge rules against the implementation they replaced.
/// The reference functions below are the pre-extraction code, kept verbatim;
/// any divergence between them and `DashboardMerge` fails the suite.
@Suite struct DashboardMergeTests {
    // MARK: - Reference implementation (pre-extraction)

    private func legacyMerge(_ current: V2SessionMeta?, _ incoming: V2SessionMeta,
                             _ reconcile: (V2SessionMeta) -> V2SessionMeta) -> V2SessionMeta {
        var value = current.map { $0.updatedSeq > incoming.updatedSeq ? $0 : incoming } ?? incoming
        value.lastReadSeq = max(current?.lastReadSeq ?? 0, incoming.lastReadSeq)
        if value.lastReadSeq >= value.latestTurnEndSeq { value.unread = false }
        return reconcile(value)
    }

    private func legacyUnique(_ values: [V2SessionMeta]) -> [V2SessionMeta] {
        var result: [String: V2SessionMeta] = [:]
        for value in values { result[value.id] = value }
        return Array(result.values).sorted { $0.id < $1.id }
    }

    private func legacyApply(held: [V2SessionMeta], incoming: [V2SessionMeta],
                             validDevices: Set<String>,
                             reconcile: (V2SessionMeta) -> V2SessionMeta) -> [V2SessionMeta] {
        let current = Dictionary(uniqueKeysWithValues: held.map { ($0.id, $0) })
        let pending = held.filter { $0.id.hasPrefix("local:") && validDevices.contains($0.connectorId) }
        return legacyUnique(pending + incoming.map { legacyMerge(current[$0.id], $0, reconcile) })
    }

    private func legacyUpsert(held: [V2SessionMeta], incoming: [V2SessionMeta],
                              reconcile: (V2SessionMeta) -> V2SessionMeta) -> [V2SessionMeta] {
        var values = Dictionary(uniqueKeysWithValues: held.map { ($0.id, $0) })
        for value in incoming { values[value.id] = legacyMerge(values[value.id], value, reconcile) }
        return Array(values.values).sorted { $0.id < $1.id }
    }

    // MARK: - Fixtures

    private func meta(id: String,
                      connectorId: String = "device",
                      updatedSeq: Int = 10,
                      lastReadSeq: Int = 0,
                      latestTurnEndSeq: Int = 0,
                      unread: Bool = false,
                      title: String = "t") throws -> V2SessionMeta {
        let object = try fixtureObject("snapshot")
        var session = object["session"] as! [String: Any]
        session["id"] = id
        session["connectorId"] = connectorId
        session["updatedSeq"] = updatedSeq
        session["lastReadSeq"] = lastReadSeq
        session["latestTurnEndSeq"] = latestTurnEndSeq
        session["unread"] = unread
        session["title"] = title
        return try decode(session)
    }

    private struct SeededRandom {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        mutating func next(_ upper: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 33) % UInt64(upper))
        }
    }

    private func randomSessions(_ random: inout SeededRandom,
                                ids: [String]) throws -> [V2SessionMeta] {
        var result: [V2SessionMeta] = []
        for id in ids {
            let connector = random.next(4) == 0 ? "other" : "device"
            let updated = random.next(21)
            let read = random.next(31)
            let end = random.next(31)
            result.append(try meta(id: id, connectorId: connector,
                                   updatedSeq: updated,
                                   lastReadSeq: read,
                                   latestTurnEndSeq: end,
                                   unread: read < end))
        }
        return result
    }

    private var reconcile: (V2SessionMeta) -> V2SessionMeta {
        { value in
            var copy = value
            copy.lastReadSeq += 2
            return copy
        }
    }

    // MARK: - Parity

    @Test func snapshotMergeMatchesTheLegacyImplementation() throws {
        var random = SeededRandom()
        let ids = ["a", "b", "c", "d", "e", "f"]
        for _ in 0..<200 {
            var heldIDs: [String] = []
            for id in ids where random.next(2) == 0 { heldIDs.append(id) }
            var incomingIDs: [String] = []
            for id in ids where random.next(2) == 0 { incomingIDs.append(id) }
            let held = try randomSessions(&random, ids: heldIDs)
            let incoming = try randomSessions(&random, ids: incomingIDs)
            let valid: Set<String> = random.next(5) == 0 ? ["other"] : ["device"]

            let actual = DashboardMerge.apply(held: held, incoming: incoming,
                                              validConnectorIDs: valid, reconcile: reconcile)
            let expected = legacyApply(held: held, incoming: incoming,
                                       validDevices: valid, reconcile: reconcile)
            #expect(actual == expected)
        }
    }

    @Test func upsertMatchesTheLegacyImplementation() throws {
        var random = SeededRandom()
        let ids = ["a", "b", "c", "d", "e", "f"]
        for _ in 0..<200 {
            var heldIDs: [String] = []
            for id in ids where random.next(2) == 0 { heldIDs.append(id) }
            var incomingIDs: [String] = []
            for id in ids where random.next(2) == 0 { incomingIDs.append(id) }
            let held = try randomSessions(&random, ids: heldIDs)
            let incoming = try randomSessions(&random, ids: incomingIDs)

            let actual = DashboardMerge.upsert(held: held, incoming: incoming, reconcile: reconcile)
            let expected = legacyUpsert(held: held, incoming: incoming, reconcile: reconcile)
            #expect(actual == expected)
        }
    }

    // MARK: - Explicit edges

    @Test func newerHeldRevisionWinsButReadWatermarkStillAdvances() throws {
        let held = [try meta(id: "s", updatedSeq: 20, lastReadSeq: 5, latestTurnEndSeq: 8, title: "held")]
        let incoming = [try meta(id: "s", updatedSeq: 10, lastReadSeq: 9, latestTurnEndSeq: 8, title: "incoming")]
        let result = DashboardMerge.apply(held: held, incoming: incoming,
                                          validConnectorIDs: ["device"], reconcile: { $0 })
        let value = try #require(result.first)
        #expect(value.title == "held")
        #expect(value.lastReadSeq == 9)
        #expect(value.unread == false)
    }

    @Test func equalRevisionTakesTheIncomingRow() throws {
        let held = [try meta(id: "s", updatedSeq: 10, title: "held")]
        let incoming = [try meta(id: "s", updatedSeq: 10, title: "incoming")]
        let result = DashboardMerge.apply(held: held, incoming: incoming,
                                          validConnectorIDs: ["device"], reconcile: { $0 })
        #expect(result.first?.title == "incoming")
    }

    @Test func localPendingRowsSurviveASnapshotWithoutThem() throws {
        let local = try meta(id: "local:1", connectorId: "device", title: "draft")
        let remote = try meta(id: "s", connectorId: "device", title: "remote")
        let result = DashboardMerge.apply(held: [local], incoming: [remote],
                                          validConnectorIDs: ["device"], reconcile: { $0 })
        #expect(Set(result.map(\.id)) == ["local:1", "s"])
    }

    @Test func localPendingRowsOnAnUnknownConnectorAreDropped() throws {
        let local = try meta(id: "local:1", connectorId: "removed", title: "draft")
        let result = DashboardMerge.apply(held: [local], incoming: [],
                                          validConnectorIDs: ["device"], reconcile: { $0 })
        #expect(result.isEmpty)
    }

    @Test func reconcileRunsOnSnapshotRowsOnlyNotOnPendingRows() throws {
        var touched: [String] = []
        let local = try meta(id: "local:1", title: "draft")
        let remote = try meta(id: "s", title: "remote")
        _ = DashboardMerge.apply(held: [local], incoming: [remote], validConnectorIDs: ["device"]) { value in
            touched.append(value.id)
            return value
        }
        #expect(touched == ["s"])
    }
}

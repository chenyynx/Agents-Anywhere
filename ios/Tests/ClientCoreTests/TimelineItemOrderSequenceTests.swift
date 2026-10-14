import Foundation
import Testing
@testable import ClientCore

/// The wire contract treats `orderSeq` as the client's ONLY ordering truth: a
/// row missing it fails to decode, and every collection of items reads lossily
/// so that failure drops just that row instead of the whole page. These tests
/// pin both halves — the field is required, and a row lacking it costs nothing
/// beyond the row itself.
///
/// Background: `orderSeq` used to fall back silently to `updatedSeq`, which runs
/// the OPPOSITE way for a message's reasoning rows (the intra-message repack
/// gives the reasoning row a higher `updatedSeq` than its body) — that is the
/// exact "reasoning below its body" defect (server v2_42, 2026-10-14).
@Suite @MainActor struct TimelineItemOrderSequenceTests {

    /// A copy of the standard item fixture with one key removed, so the row
    /// fails to decode exactly the way a server that dropped a field would.
    private func itemObjectWithout(_ key: String) throws -> [String: Any] {
        var item = try itemObject(id: "broken", order: 2)
        item.removeValue(forKey: key)
        return item
    }

    @Test func aRowWithoutOrderSeqFailsToDecode() throws {
        let object = try itemObjectWithout("orderSeq")
        #expect(throws: (any Error).self) {
            _ = try decode(object, as: V2TimelineItem.self)
        }
    }

    @Test func aRowWithoutIdOrSessionIdFailsToDecode() throws {
        for key in ["id", "sessionId"] {
            let object = try itemObjectWithout(key)
            #expect(throws: (any Error).self) {
                _ = try decode(object, as: V2TimelineItem.self)
            }
        }
    }

    @Test func aWellFormedRowStillDecodes() throws {
        let item = try decode(try itemObject(id: "ok", order: 7), as: V2TimelineItem.self)
        #expect(item.orderSeq == 7)
    }

    @Test func theSnapshotDropsOnlyTheMalformedRow() throws {
        let good = try itemObject(id: "good", order: 1)
        let broken = try itemObjectWithout("orderSeq")

        let snapshot = try snapshot(items: [good, broken])
        #expect(snapshot.timeline.items.map(\.id) == [V2TimelineItemID("good")])

        // The session still opens with the surviving rows in the right order.
        let projection = V2SessionProjection(snapshot: snapshot, maximumItems: 100)
        #expect(projection.data.items.map(\.orderSeq) == [1])
    }

    @Test func theSnapshotKeepsEveryRowWhenAllAreWellFormed() throws {
        let items = try (1...5).map { try itemObject(id: "item-\($0)", order: $0) }
        let snapshot = try snapshot(items: items)
        #expect(snapshot.timeline.items.map(\.orderSeq) == [1, 2, 3, 4, 5])
    }

    @Test func theHistoryPageDropsOnlyTheMalformedRow() throws {
        var page = try fixtureObject("timeline")
        page["items"] = [try itemObject(id: "good", order: 1), try itemObjectWithout("orderSeq")]
        page["nextSeq"] = 42
        page["hasMore"] = true

        let decoded: V2SessionTimelinePage = try decode(page)
        #expect(decoded.items.map(\.id) == [V2TimelineItemID("good")])
        #expect(decoded.nextSeq == 42 && decoded.hasMore)
    }

    @Test func aSnapshotFrameDropsOnlyTheMalformedRow() throws {
        // The live `timeline.snapshot` reset carries a whole collection; a bad
        // row inside it is dropped, never failing the reset that rebuilds the
        // timeline. (A single-item `timeline.item_*` frame stays strict on
        // purpose — a malformed one there is a stream failure the recovery path
        // is designed to surface.)
        var projection = V2SessionProjection(snapshot: try snapshot(), maximumItems: 100)
        let good = try itemObject(id: "good", order: 1)
        let broken = try itemObjectWithout("orderSeq")
        try projection.apply(event("timeline.snapshot", seq: 20, payload: ["items": [good, broken]]))
        #expect(projection.data.items.map(\.id) == [V2TimelineItemID("good")])
    }

    @Test func aSnapshotRowMissingOrderSeqIsNotShownInAGuessedPosition() throws {
        // 宁缺勿假: the malformed row is absent, never placed by updatedSeq.
        var good = try itemObject(id: "body", order: 1)
        good["updatedSeq"] = 999
        var broken = try itemObjectWithout("orderSeq")
        broken["updatedSeq"] = 1000  // would sort after the body if used as a fallback

        let snapshot = try snapshot(items: [good, broken])
        #expect(snapshot.timeline.items.count == 1)
        #expect(snapshot.timeline.items.first?.id == V2TimelineItemID("body"))
    }
}

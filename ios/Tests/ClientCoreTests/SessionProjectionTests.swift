import Foundation
import Testing
@testable import ClientCore

@Suite @MainActor struct SessionProjectionTests {
    @Test func reopeningKeepsItsBoundaryThroughRecoveryAndLiveUpdates() throws {
        let items = try (1...250).map { try itemObject(id: "item-\($0)", order: $0) }
        var projection = V2SessionProjection(snapshot: try snapshot(items: items), maximumItems: 1000)
        let trimmed = projection.limitToLatest(100)
        #expect(trimmed)
        #expect(projection.data.items.map(\.orderSeq) == Array(151...250))
        #expect(projection.data.hasOlderItems && projection.data.cursor == "seq:10")
        try projection.apply(event("timeline.item_updated", seq: 11, payload: [
            "item": itemObject(id: "item-50", order: 50, revision: 2, seq: 11)]))
        #expect(projection.data.items.count == 100 && projection.data.items.first?.orderSeq == 151)
        try projection.apply(event("timeline.item_updated", seq: 12, payload: [
            "item": itemObject(id: "item-200", order: 200, revision: 2, seq: 12, text: "Updated")]))
        #expect(projection.data.items.first { $0.id == "item-200" }?.displayText == "Updated")
        try projection.apply(event("timeline.item_created", seq: 13, payload: [
            "item": itemObject(id: "item-251", order: 251, seq: 13)]))
        #expect(projection.data.items.count == 101 && projection.data.items.last?.orderSeq == 251)
        #expect(projection.data.cursor == "seq:13")
    }

    @Test func singleItemEventsKeepOrderBoundsAndIdentity() throws {
        let items = try [1, 2, 3].map { try itemObject(id: "item-\($0)", order: $0) }
        var projection = V2SessionProjection(snapshot: try snapshot(items: items), maximumItems: 3)
        // A created item past the window trims the oldest row and marks older history.
        try projection.apply(event("timeline.item_created", seq: 11, payload: ["item": itemObject(id: "item-4", order: 4, seq: 11)]))
        #expect(projection.data.items.map(\.id) == ["item-2", "item-3", "item-4"] && projection.data.hasOlderItems)
        // Stale revisions never replace a newer row; equal revisions follow updatedSeq.
        try projection.apply(event("timeline.item_updated", seq: 12, payload: ["item": itemObject(id: "item-3", order: 3, revision: 0, seq: 12, text: "Stale")]))
        #expect(projection.data.items[1].displayText == "Hello")
        try projection.apply(event("timeline.item_updated", seq: 13, payload: ["item": itemObject(id: "item-3", order: 3, revision: 1, seq: 13, text: "Fresh")]))
        #expect(projection.data.items[1].displayText == "Fresh" && projection.data.items.count == 3)
        // An item that moves to another orderSeq is relocated, not duplicated.
        try projection.apply(event("timeline.item_updated", seq: 14, payload: ["item": itemObject(id: "item-2", order: 9, revision: 2, seq: 14)]))
        #expect(projection.data.items.map(\.id) == ["item-3", "item-4", "item-2"])
        // Equality is decided by identity fields plus the wire tree, never by hash alone.
        let a: V2TimelineItem = try decode(itemObject(text: "A"))
        let b: V2TimelineItem = try decode(itemObject(text: "B"))
        let again: V2TimelineItem = try decode(itemObject(text: "A"))
        #expect(a != b && a == again && a.hashValue == again.hashValue)
    }

    @Test func allBackendSessionStatusesAndFutureStatesDecodeInMetadata() throws {
        for status in ["idle", "waiting", "pending", "running", "stopping", "waiting_approval", "error", "blocked"] {
            var raw = try fixtureObject("session")["session"] as! [String: Any]
            raw["status"] = status
            let meta: V2SessionMeta = try decode(raw)
            #expect(meta.status.rawValue == status)
        }
        var raw = try fixtureObject("session")["session"] as! [String: Any]
        raw["status"] = "future_status"; raw["connectorStatus"] = "future_presence"
        let meta: V2SessionMeta = try decode(raw)
        #expect(meta.status == .unknown && meta.connectorStatus == .unknown)
    }

    @Test func sameSequenceLiveTransitionsAreNotDeduplicated() throws {
        var projection = V2SessionProjection(snapshot: try snapshot(), maximumItems: 100)
        var state = try fixtureObject("state")["state"] as! [String: Any]
        state["status"] = "running"
        let running = try event("runtime.state.updated", id: "A", payload: ["state": state])
        state["status"] = "idle"
        let idle = try event("runtime.state.updated", id: "B", payload: ["state": state])
        try projection.apply(running); try projection.apply(idle); try projection.apply(running)
        #expect(projection.data.state?.status == .running)
        #expect(projection.data.cursor == "seq:10")
    }

    @Test func timelineUsesRevisionAndHistoryDoesNotAcknowledgeEvents() throws {
        var projection = V2SessionProjection(snapshot: try snapshot(hasMore: true), maximumItems: 3)
        let newer = try itemObject(revision: 3, seq: 11, text: "Streamed")
        let update = try event("timeline.item_updated", seq: 11, id: "once", payload: ["item": newer])
        try projection.apply(update); try projection.apply(update)
        let page = V2SessionTimelinePage(sessionId: "session", items: [try decode(itemObject(revision: 1))], nextSeq: 1000, hasMore: false, serverTime: nil)
        projection.applyHistory(page)
        #expect(projection.data.items.count == 1)
        #expect(projection.data.items[0].revision == 3)
        #expect(projection.data.cursor == "seq:11")
    }

    @Test func boundedHistoryWindowAndReturningToLatest() throws {
        let recent = try [itemObject(id: "3", order: 3), itemObject(id: "4", order: 4)]
        var projection = V2SessionProjection(snapshot: try snapshot(items: recent, hasMore: true), maximumItems: 3)
        let older = try [itemObject(id: "1", order: 1), itemObject(id: "2", order: 2)].map { try decode($0, as: V2TimelineItem.self) }
        projection.applyHistory(V2SessionTimelinePage(sessionId: "session", items: older, nextSeq: 50, hasMore: false, serverTime: nil))
        // Browsing history keeps both sides even past the idle window; the
        // reader's newer rows are never dropped to make the list shorter.
        #expect(projection.data.items.map(\.id) == ["1", "2", "3", "4"])
        #expect(!projection.data.hasOlderItems)
        #expect(!projection.data.hasNewerItems)
        // A live create outside the anchored window is deferred as newer; it
        // must not push the reading row out.
        try projection.apply(event("timeline.item_created", seq: 11, payload: ["item": itemObject(id: "5", order: 5, seq: 11)]))
        #expect(projection.data.items.map(\.id) == ["1", "2", "3", "4"])
        #expect(projection.data.hasNewerItems)
        projection.applyLatest(V2SessionTimelinePage(sessionId: "session", items: try recent.map { try decode($0) }, nextSeq: 11, hasMore: true, serverTime: nil))
        #expect(projection.data.items.map(\.id) == ["3", "4"])
        #expect(!projection.data.hasNewerItems)
    }

    @Test func historyWindowKeepsTheVisibleAnchorAndTheNewestTail() throws {
        // Latest page 481...500; the reader is at 495 near the tail. One older
        // page arrives with the visible anchor at 495.
        let recent = try (481...500).map { try itemObject(id: "item-\($0)", order: $0) }
        var projection = V2SessionProjection(snapshot: try snapshot(items: recent), maximumItems: 20)
        let older = try (461...480).map { try decode(itemObject(id: "item-\($0)", order: $0), as: V2TimelineItem.self) }
        projection.applyHistory(V2SessionTimelinePage(sessionId: "session", items: older,
            nextSeq: 500, hasMore: false, serverTime: nil), anchorOrderSeq: 495)
        #expect(projection.data.items.map(\.orderSeq) == Array(461...500))
        #expect(projection.data.items.contains { $0.orderSeq == 495 })
        #expect(!projection.data.hasOlderItems)
        #expect(!projection.data.hasNewerItems)
    }

    @Test func historyBrowsingKeepsTheFarNewestEnd() throws {
        // The reader is near the old end. Browsing must still keep the newer
        // rows the reader already has; only returning to the newest edge may
        // trim the idle window.
        let recent = try (481...500).map { try itemObject(id: "item-\($0)", order: $0) }
        var projection = V2SessionProjection(snapshot: try snapshot(items: recent), maximumItems: 12)
        let older = try (461...480).map { try decode(itemObject(id: "item-\($0)", order: $0), as: V2TimelineItem.self) }
        projection.applyHistory(V2SessionTimelinePage(sessionId: "session", items: older,
            nextSeq: 500, hasMore: false, serverTime: nil), anchorOrderSeq: 465)
        #expect(projection.data.items.map(\.orderSeq) == Array(461...500))
        #expect(!projection.data.hasOlderItems)
        #expect(!projection.data.hasNewerItems)
    }

    @Test func returningToTheNewestEdgeStopsAnchoringLiveRows() throws {
        let recent = try (481...500).map { try itemObject(id: "item-\($0)", order: $0) }
        var projection = V2SessionProjection(snapshot: try snapshot(items: recent), maximumItems: 20)
        let older = try (461...480).map { try decode(itemObject(id: "item-\($0)", order: $0), as: V2TimelineItem.self) }
        projection.applyHistory(V2SessionTimelinePage(sessionId: "session", items: older,
            nextSeq: 500, hasMore: false, serverTime: nil), anchorOrderSeq: 495)
        projection.followLatest()
        try projection.apply(event("timeline.item_created", seq: 501, payload: [
            "item": itemObject(id: "item-501", order: 501, seq: 501)]))
        #expect(projection.data.items.map(\.orderSeq) == Array(482...501))
    }

    @Test func historyPagingNeverDropsTheNewestRowsUntilTheWindowIsFull() throws {
        let recent = try (101...300).map { try itemObject(id: "item-\($0)", order: $0) }
        var projection = V2SessionProjection(snapshot: try snapshot(items: recent), maximumItems: 1000)
        let older = try (1...100).map { try decode(itemObject(id: "item-\($0)", order: $0), as: V2TimelineItem.self) }
        projection.applyHistory(V2SessionTimelinePage(sessionId: "session", items: older,
            nextSeq: 300, hasMore: false, serverTime: nil), anchorOrderSeq: 101)
        #expect(projection.data.items.map(\.orderSeq) == Array(1...300))
        #expect(!projection.data.hasOlderItems)
        #expect(!projection.data.hasNewerItems)
    }

    @Test func localLatestCanKeepTheNewerFlagUntilTheNetworkConfirms() throws {
        let seed = try [itemObject(id: "2", order: 2, seq: 2), itemObject(id: "3", order: 3, seq: 3),
                        itemObject(id: "4", order: 4, seq: 4)].map { try decode($0, as: V2TimelineItem.self) }
        var projection = V2SessionProjection(snapshot: try snapshot(items: [
            try itemObject(id: "2", order: 2, seq: 2), try itemObject(id: "3", order: 3, seq: 3),
            try itemObject(id: "4", order: 4, seq: 4)]), maximumItems: 3)
        let local = try [itemObject(id: "3", order: 3, seq: 3), itemObject(id: "4", order: 4, seq: 4)]
            .map { try decode($0, as: V2TimelineItem.self) }
        projection.applyLatest(V2SessionTimelinePage(sessionId: "session", items: local,
            nextSeq: 4, hasMore: true, serverTime: nil), hasNewerAfterApply: true)
        #expect(projection.data.items.map(\.id) == ["3", "4"])
        #expect(projection.data.hasNewerItems)
        projection.applyLatest(V2SessionTimelinePage(sessionId: "session", items: seed,
            nextSeq: 4, hasMore: true, serverTime: nil))
        #expect(!projection.data.hasNewerItems)
    }

    @Test func lateLatestPagePreservesNewerSocketChanges() throws {
        var projection = V2SessionProjection(snapshot: try snapshot(), maximumItems: 3)
        try projection.apply(event("timeline.item_updated", seq: 11, payload: ["item": itemObject(revision: 2, seq: 11)]))
        projection.applyLatest(try fixture("timeline"))
        #expect(projection.data.items[0].revision == 2)
        #expect(projection.data.cursor == "seq:11")
    }

    @Test func resetReplacesTimelineAndUnknownEventsRemainAccessible() throws {
        var projection = V2SessionProjection(snapshot: try snapshot(), maximumItems: 2)
        try projection.apply(event("timeline.snapshot", seq: 11, payload: ["items": []]))
        #expect(projection.data.items.isEmpty)
        let extensionEvent = try event("vendor.progress", seq: 12, payload: ["progress": 0.5])
        try projection.apply(extensionEvent)
        #expect(projection.data.lastExtensionEvent == extensionEvent)
        try projection.apply(event("session.subscribed", seq: 999))
        #expect(projection.data.cursor == "seq:12")
        try projection.apply(event("timeline.item_created", seq: 13, sessionID: "another", payload: ["item": itemObject()]))
        #expect(projection.data.items.isEmpty)
    }

    /// The live socket now takes a single-row fast path instead of the batch
    /// merge. Every invariant the batch path enforced — ordered by
    /// `(orderSeq, id)`, unique ids, bounded window, newest revision wins —
    /// must still hold after a random sequence of creates, updates and moves.
    @Test func singleItemFastPathKeepsOrderUniquenessAndWindow() throws {
        let seed = try (1...20).map { try itemObject(id: "item-\($0)", order: $0) }
        var projection = V2SessionProjection(snapshot: try snapshot(items: seed), maximumItems: 8)
        var expectedRevision = Dictionary(uniqueKeysWithValues: (1...20).map { ("item-\($0)", 1) })
        var generator = SystemRandomNumberGenerator()
        for step in 0..<300 {
            let order = Int.random(in: 1...30, using: &generator)
            let id = "item-\(order)"
            let revision = Int.random(in: 2...5, using: &generator)
            let seq = 100 + step
            let update = try event("timeline.item_created", seq: seq, payload: [
                "item": itemObject(id: id, order: order, revision: revision, seq: seq)])
            try projection.apply(update)
            expectedRevision[id] = max(expectedRevision[id] ?? 0, revision)
        }
        let items = projection.data.items
        #expect(items.count <= 8)
        #expect(Set(items.map(\.id)).count == items.count)
        #expect(zip(items, items.dropFirst()).allSatisfy {
            ($0.0.orderSeq, $0.0.id) < ($0.1.orderSeq, $0.1.id)
        })
        for item in items {
            #expect(item.revision == expectedRevision[item.id])
        }
    }

    @Test func runtimeIdentityAndFreshnessAreSeparateFromCachedContent() throws {
        var projection = V2SessionProjection(snapshot: try snapshot(), maximumItems: 2)
        let live = V2SessionLiveState(state: try fixture("state", as: V2RuntimeStateResponse.self).state,
                                    capabilities: try fixture("capabilities", as: V2RuntimeCapabilityResponse.self).capabilitySet, notices: [])
        projection.applyLive(live)
        #expect(projection.data.liveStateIsFresh)
        var state = try fixtureObject("state")["state"] as! [String: Any]
        state["runtimeId"] = "another"
        try projection.apply(event("runtime.state.updated", payload: ["state": state]))
        #expect(projection.data.state?.runtimeId == "rti_work")
        projection.markStale()
        #expect(!projection.data.liveStateIsFresh)
        #expect(projection.data.items.count == 1)
    }
}

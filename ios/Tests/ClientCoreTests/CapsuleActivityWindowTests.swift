import Foundation
import Testing
@testable import ClientCore

/// ios-capsule-activity-window-tasks.md §3/§8: an unterminated SubAgent card
/// must keep the capsule usable no matter how much later traffic pushed the
/// card out of the client's loaded window, and the panel must be able to reach
/// every card the capsule counts (方案 A + §8 增量).
@Suite @MainActor struct CapsuleActivityWindowTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// A window row. Turn boundaries are the user rows the timeline already
    /// treats as visible-turn starts (`V2TimelineItem.startsVisibleTurn`).
    private func row(_ id: String, order: Int, revision: Int = 1, seq: Int = 10,
                     type: String = "message", role: String? = nil, status: String? = nil,
                     content: [String: Any]) throws -> [String: Any] {
        var value = try itemObject(id: id, order: order, revision: revision, seq: seq)
        value["type"] = type
        value["content"] = content
        if let role { value["role"] = role }
        if let status { value["status"] = status }
        return value
    }

    private func userRow(_ id: String, order: Int, seq: Int = 10) throws -> [String: Any] {
        try row(id, order: order, seq: seq, type: "message", role: "user", content: ["text": id])
    }

    /// A running Agent call card, the connector's `content.kind` convention.
    private func agentCard(_ id: String = "card", order: Int, status: String = "running",
                           description: String = "F1 实施子代理", revision: Int = 1, seq: Int = 10,
                           agents: [String: Any]? = nil, parentItemId: String? = nil) throws -> [String: Any] {
        var content: [String: Any] = ["kind": "agent_call", "action": "invoke", "description": description]
        if let agents { content["agents"] = agents }
        if let parentItemId { content["parentItemId"] = parentItemId }
        return try row(id, order: order, revision: revision, seq: seq, type: "tool", status: status, content: content)
    }

    private func decodeItems(_ values: [[String: Any]]) throws -> [V2TimelineItem] {
        try values.map { try decode($0, as: V2TimelineItem.self) }
    }

    private func capsule(_ projection: V2SessionProjection, at now: Date = CapsuleActivityWindowTests.now)
    -> SubAgentCapsuleState {
        SubAgentProgress.capsuleState(inWindow: projection.data.items,
                                      activeCards: projection.data.activeAgentCards, now: now)
    }

    // MARK: Window independence

    @Test func aCardPushedOutOfTheWindowStillDrivesTheCapsule() throws {
        // The device case: the card sits at order 220 of 567, so 347 rows
        // follow it and `open()` trims the window to the newest 100.
        var values = try (1...567).map { order -> [String: Any] in
            order == 220 ? try agentCard(order: order) : try row("item-\(order)", order: order, content: ["text": "x"])
        }
        var projection = V2SessionProjection(snapshot: try snapshot(items: values), maximumItems: 1000,
                                             now: { Self.now })
        #expect(projection.data.items.contains { $0.id == "card" })

        let trimmed = projection.limitToLatest(100)
        #expect(trimmed)
        #expect(!projection.data.items.contains { $0.id == "card" })
        #expect(projection.data.items.count == 100)
        #expect(projection.data.activeAgentCards.map(\.item.id) == ["card"])

        let state = capsule(projection)
        #expect(state.isVisible)
        #expect(state.runningCount == 1)
        #expect(state.title == "F1 实施子代理")
        #expect(state.latestRunningID == "card")
        // The regression this pins: read from the window alone the capsule is gone.
        #expect(!SubAgentProgress.capsuleState(projection.data.items).isVisible)
    }

    @Test func aTerminalFrameForAnOutOfWindowCardClosesTheCapsule() throws {
        var values = try (1...567).map { order -> [String: Any] in
            order == 220 ? try agentCard(order: order) : try row("item-\(order)", order: order, content: ["text": "x"])
        }
        var projection = V2SessionProjection(snapshot: try snapshot(items: values), maximumItems: 1000,
                                             now: { Self.now })
        let trimmed = projection.limitToLatest(100)
        #expect(trimmed)
        #expect(capsule(projection).isVisible)

        let finished = try agentCard(order: 220, status: "done", revision: 2, seq: 11)
        try projection.apply(event("timeline.item_updated", seq: 11, payload: ["item": finished]))
        // The frame is rejected by the window guard — and still has to reach the
        // sidecar, or the capsule would keep announcing finished work.
        #expect(!projection.data.items.contains { $0.id == "card" })
        #expect(projection.data.activeAgentCards.isEmpty)
        #expect(!capsule(projection).isVisible)
    }

    @Test func anOlderFrameNeitherRevivesNorClosesANewerCard() throws {
        var projection = V2SessionProjection(
            snapshot: try snapshot(items: [try agentCard(order: 3, revision: 5, seq: 30)]),
            maximumItems: 10, now: { Self.now })
        // A frame that lost the revision race must not overwrite the stored card…
        try projection.apply(event("timeline.item_updated", seq: 11, payload: [
            "item": try agentCard(order: 3, description: "过期标题", revision: 4, seq: 20)]))
        #expect(projection.data.activeAgentCards.first?.item.revision == 5)
        #expect(capsule(projection).title == "F1 实施子代理")
        // …and a stale terminal frame must not close it either.
        try projection.apply(event("timeline.item_updated", seq: 12, payload: [
            "item": try agentCard(order: 3, status: "done", revision: 4, seq: 20)]))
        #expect(projection.data.activeAgentCards.map(\.item.id) == ["card"])
        #expect(capsule(projection).isVisible)

        // The winning terminal frame does close it.
        try projection.apply(event("timeline.item_updated", seq: 13, payload: [
            "item": try agentCard(order: 3, status: "done", revision: 6, seq: 40)]))
        #expect(projection.data.activeAgentCards.isEmpty)
    }

    @Test func aLaunchingCardStaysActiveEvenWhenTheItemReadsDone() throws {
        // The launch receipt outranks the item status: the subagent is dispatched
        // and alive while the connector has not folded its first task event yet.
        let launching = try agentCard("launch", order: 5, status: "done",
                                      agents: ["t1": ["status": SubAgentProgress.asyncLaunchedStatus]])
        let stored = SubAgentProgress.absorbingActiveCards(try decode(launching), into: [], now: Self.now)
        #expect(stored.map(\.item.id) == ["launch"])
        let state = SubAgentProgress.capsuleState(inWindow: [], activeCards: stored, now: Self.now)
        #expect(state.isVisible)
        #expect(state.phaseWord == String(localized: "启动中"))

        // The receipt clears and the same terminal item finally closes the card.
        let closed = try agentCard("launch", order: 5, status: "done", revision: 2, seq: 11,
                                   agents: ["t1": ["status": "completed"]])
        #expect(SubAgentProgress.absorbingActiveCards(try decode(closed), into: stored, now: Self.now).isEmpty)
    }

    @Test func theWindowAndSidecarUnionCountsACardOnceAndKeepsTheNewerVersion() throws {
        let inWindow = try decode(agentCard(order: 3, description: "窗口版本", revision: 5, seq: 30), as: V2TimelineItem.self)
        let newer = try decode(agentCard(order: 3, description: "更新版本", revision: 7, seq: 40), as: V2TimelineItem.self)
        let older = try decode(agentCard(order: 3, description: "过期版本", revision: 4, seq: 20), as: V2TimelineItem.self)

        let merged = SubAgentProgress.capsuleItems(inWindow: [inWindow],
                                                    activeCards: [V2ActiveAgentCard(item: newer, confirmedAt: Self.now)],
                                                    now: Self.now)
        #expect(merged.count == 1)
        #expect(SubAgentProgress.card(merged[0])?.taskName == "更新版本")
        #expect(SubAgentProgress.capsuleState(inWindow: [inWindow],
                                               activeCards: [V2ActiveAgentCard(item: newer, confirmedAt: Self.now)],
                                               now: Self.now).runningCount == 1)
        // A sidecar copy older than the window's never overwrites the window's.
        let kept = SubAgentProgress.capsuleItems(inWindow: [inWindow],
                                                  activeCards: [V2ActiveAgentCard(item: older, confirmedAt: Self.now)],
                                                  now: Self.now)
        #expect(SubAgentProgress.card(kept[0])?.taskName == "窗口版本")
    }

    @Test func anUnconfirmedCardAgesOutAndTheFuseKeepsTheNewestWork() throws {
        let running = try decode(agentCard(order: 1), as: V2TimelineItem.self)
        let stored = SubAgentProgress.absorbingActiveCards(running, into: [], now: Self.now)
        #expect(stored.count == 1)
        let muchLater = Self.now.addingTimeInterval(SubAgentProgress.activeCardStaleAfter + 1)
        // Read after the ageing window with no new frame: the capsule closes and
        // the sidecar drops the entry rather than pinning it forever. (A frame
        // arriving now would itself re-confirm the card — that is the point.)
        #expect(!SubAgentProgress.capsuleState(inWindow: [], activeCards: stored, now: muchLater).isVisible)
        let unrelated = try decode(row("after", order: 2, type: "message", content: ["text": "x"]),
                                   as: V2TimelineItem.self)
        #expect(SubAgentProgress.absorbingActiveCards(unrelated, into: stored, now: muchLater).isEmpty)

        var fused: [V2ActiveAgentCard] = []
        for order in 1...(SubAgentProgress.maximumActiveAgentCards + 5) {
            let card = try decode(agentCard("card-\(order)", order: order), as: V2TimelineItem.self)
            fused = SubAgentProgress.absorbingActiveCards(card, into: fused, now: Self.now)
        }
        #expect(fused.count == SubAgentProgress.maximumActiveAgentCards)
        #expect(fused.last?.item.id == "card-\(SubAgentProgress.maximumActiveAgentCards + 5)")
        #expect(!fused.contains { $0.item.id == "card-1" })
    }

    @Test func nestedCardsAndPlainRowsNeverEnterTheSidecar() throws {
        var stored: [V2ActiveAgentCard] = []
        stored = SubAgentProgress.absorbingActiveCards(
            try decode(agentCard("nested", order: 2, parentItemId: "outer")), into: stored, now: Self.now)
        stored = SubAgentProgress.absorbingActiveCards(
            try decode(row("text-1", order: 1, type: "message", content: ["text": "hello"])),
            into: stored, now: Self.now)
        #expect(stored.isEmpty)
    }

    // MARK: §8 panel reachability

    /// Two running cards dispatched in different turns: the device case where the
    /// capsule says "2" and the turn page held one.
    private func twoTurnItems() throws -> [V2TimelineItem] {
        try decodeItems([
            try userRow("ask-1", order: 1),
            try agentCard("card-a", order: 2, description: "@621 胶囊修复实施"),
            try userRow("ask-2", order: 3),
            try agentCard("card-b", order: 4, description: "@778 F1 红队专项"),
        ])
    }

    @Test func aCardFromAnotherTurnStaysReachableFromThePanel() throws {
        let window = try twoTurnItems()
        let page = SubAgentProgress.turnScopedTopLevelCards(in: window, containing: "card-b")
        #expect(page.map(\.id) == ["card-b"])
        // The per-turn page is untouched; the other turn's card is offered beside it.
        let others = SubAgentProgress.otherActiveCards(inWindow: window, activeCards: [], page: page)
        #expect(others.map(\.id) == ["card-a"])
        #expect(others.first?.taskName == "@621 胶囊修复实施")
        #expect(others.first?.phase == .running)
        // Both cards are reachable, and the capsule's count matches what the panel offers.
        #expect(Set(page.map(\.id)).union(others.map(\.id)) == ["card-a", "card-b"])
        #expect(SubAgentProgress.capsuleState(inWindow: window, activeCards: []).runningCount == 2)
        // The entry renders from the card itself: a name and a live phase, never blank.
        #expect(SubAgentProgress.card(try decode(agentCard("card-a", order: 2), as: V2TimelineItem.self))?.phase.isActive == true)
    }

    @Test func theOtherTurnsEntryEmptiesWhenThoseCardsReachATerminalPhase() throws {
        let window = try twoTurnItems()
        let page = SubAgentProgress.turnScopedTopLevelCards(in: window, containing: "card-b")
        var stored: [V2ActiveAgentCard] = []
        stored = SubAgentProgress.absorbingActiveCards(try decode(agentCard("card-a", order: 2)),
                                                        into: stored, now: Self.now)
        #expect(SubAgentProgress.otherActiveCards(inWindow: window, activeCards: stored, page: page)
            .map(\.id) == ["card-a"])

        // The window's own copy of card-a finishes: no terminal update frame can
        // reach the sidecar for a card that is already out of the window, so the
        // window's version has to win the union as well.
        var settled = window
        settled[1] = try decode(agentCard("card-a", order: 2, status: "done", revision: 2, seq: 20))
        #expect(SubAgentProgress.otherActiveCards(inWindow: settled, activeCards: stored, page: page).isEmpty)
        #expect(SubAgentProgress.capsuleState(inWindow: settled, activeCards: stored, now: Self.now).runningCount == 1)
        // And the frame the window drops still retires the sidecar entry.
        var projection = V2SessionProjection(snapshot: try snapshot(items: [try agentCard("card-a", order: 2)]),
                                             maximumItems: 10, now: { Self.now })
        projection.applyHistory(V2SessionTimelinePage(sessionId: "session", items: window, nextSeq: 10,
                                                      hasMore: true, serverTime: nil))
        _ = projection.limitToLatest(2)
        #expect(!projection.data.items.contains { $0.id == "card-a" })
        try projection.apply(event("timeline.item_updated", seq: 11, payload: [
            "item": try agentCard("card-a", order: 2, status: "done", revision: 2, seq: 20)]))
        // card-a is retired even though the window threw its frame away; the
        // still-running card-b stays.
        #expect(projection.data.activeAgentCards.map(\.item.id) == ["card-b"])
        #expect(capsule(projection).runningCount == 1)
        #expect(capsule(projection).latestRunningID == "card-b")
    }

    @Test func anOutOfWindowCardIsReportedAsNotLoadedRatherThanBlank() throws {
        let outside = try decode(agentCard("far", order: 2, description: "更早的回合"), as: V2TimelineItem.self)
        let entry = V2ActiveAgentCard(item: outside, confirmedAt: Self.now)
        let others = SubAgentProgress.otherActiveCards(inWindow: [], activeCards: [entry], page: [])
        #expect(others.map(\.id) == ["far"])
        // No row, so the panel cannot offer tool/thinking/output rows — and must say so.
        #expect(!SubAgentProgress.isContentLoaded(others[0], in: []))
        #expect(SubAgentProgress.card(outside)?.taskName == "更早的回合")
        #expect(others[0].phase == .running)
        // A card the window still holds needs no such notice.
        #expect(SubAgentProgress.isContentLoaded(SubAgentProgress.card(outside)!, in: [outside]))
    }

    @Test func thePanelReachAndTheCapsuleShareOneSource() throws {
        // Same union, same phases: whatever the capsule counts, the panel can offer.
        var stored: [V2ActiveAgentCard] = []
        for order in [220, 400] {
            stored = SubAgentProgress.absorbingActiveCards(try decode(agentCard("card-\(order)", order: order)),
                                                            into: stored, now: Self.now)
        }
        let window = try decodeItems([try agentCard("card-400", order: 400)])
        let page = SubAgentProgress.turnScopedTopLevelCards(in: window, containing: "card-400")
        let state = SubAgentProgress.capsuleState(inWindow: window, activeCards: stored, now: Self.now)
        let reachable = page.map(\.id) + SubAgentProgress.otherActiveCards(inWindow: window, activeCards: stored,
                                                                        page: page).map(\.id)
        #expect(state.runningCount == 2)
        #expect(Set(reachable) == ["card-220", "card-400"])
        // A card present in both layers is offered once.
        #expect(reachable.count == 2)
    }
}
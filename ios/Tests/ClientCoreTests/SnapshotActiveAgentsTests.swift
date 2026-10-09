import Foundation
import Testing
@testable import ClientCore

/// session-open-coverage P1: the snapshot's `activeAgents` field seeds the
/// capsule's active-card sidecar, so a cold open whose window does not hold the
/// card — and whose subagent emits no frame — still shows it. The seed reuses
/// `SubAgentProgress.absorbingActiveCards`, so terminal, nested, foreign-session
/// and supersede behavior are the ones the live path already pins.
@Suite @MainActor struct SnapshotActiveAgentsTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// A card in the connector's `content.kind == "agent_call"` convention.
    private func agentCard(_ id: String = "card", order: Int = 220, status: String = "running",
                           description: String = "F1 实施子代理", revision: Int = 1, seq: Int = 10,
                           sessionID: String = "session", agents: [String: Any]? = nil,
                           usage: [String: Any]? = nil) throws -> [String: Any] {
        var value = try itemObject(id: id, sessionID: sessionID, order: order, revision: revision, seq: seq)
        value["type"] = "tool"
        value["status"] = status
        var content: [String: Any] = ["kind": "agent_call", "action": "invoke", "description": description]
        if let agents { content["agents"] = agents }
        if let usage { content["usage"] = usage }
        value["content"] = content
        return value
    }

    /// The snapshot fixture with the agent list injected. `nil` leaves the key
    /// out entirely — the pre-field server shape.
    private func snapshotObject(activeAgents: [Any]? = nil, items: [[String: Any]] = []) throws -> [String: Any] {
        var object = try fixtureObject("snapshot")
        var timeline = object["timeline"] as! [String: Any]
        timeline["items"] = items
        object["timeline"] = timeline
        if let activeAgents { object["activeAgents"] = activeAgents }
        return object
    }

    // MARK: Decoding

    @Test func aSnapshotCarriesItsActiveAgentCards() throws {
        let object = try snapshotObject(activeAgents: [
            try agentCard(order: 220, description: "F1 实施",
                          usage: ["toolCalls": 7, "tokens": 33_555, "durationMs": 24_723]),
            try agentCard("second", order: 400, description: "红队复核"),
        ])
        let snapshot = try decode(object, as: V2SessionSnapshot.self)
        #expect(snapshot.activeAgents.map(\.id) == ["card", "second"])
        let first = try #require(snapshot.activeAgents.first.flatMap(SubAgentProgress.card))
        #expect(first.taskName == "F1 实施")
        #expect(first.phase == .running)
        #expect(first.toolCalls == 7)
        #expect(first.tokens == 33_555)
        #expect(first.durationMs == 24_723)
    }

    @Test func aSnapshotWithoutTheFieldReadsEmpty() throws {
        let snapshot = try decode(try snapshotObject(), as: V2SessionSnapshot.self)
        #expect(snapshot.activeAgents.isEmpty)
    }

    @Test func oneMalformedCardIsDroppedWithoutFailingTheSnapshot() throws {
        // Prove the element really is undecodable — a missing `id` — so the
        // snapshot surviving shows the element-level catch, not a lenient card.
        #expect((try? decode(["nope": true], as: V2TimelineItem.self)) == nil)
        let object = try snapshotObject(activeAgents: [["nope": true], try agentCard("kept", order: 300)])
        let snapshot = try decode(object, as: V2SessionSnapshot.self)
        #expect(snapshot.activeAgents.map(\.id) == ["kept"])
    }

    // MARK: The seed

    @Test func theSeedDrivesTheCapsuleWithAnEmptyWindow() throws {
        let snapshot = try decode(try snapshotObject(activeAgents: [try agentCard(order: 220)]),
                                  as: V2SessionSnapshot.self)
        let data = V2SessionData(snapshot: snapshot, now: Self.now)
        #expect(data.items.isEmpty)
        #expect(data.activeAgentCards.map(\.item.id) == ["card"])
        #expect(data.activeAgentCards.first?.confirmedAt == Self.now)

        let state = SubAgentProgress.capsuleState(inWindow: data.items, activeCards: data.activeAgentCards, now: Self.now)
        #expect(state.runningCount >= 1)
        #expect(state.isVisible)
        #expect(state.title == "F1 实施子代理")

        // The seed is a confirmation like any other: read long after the
        // snapshot (an old archive), it ages out instead of pinning the capsule.
        let muchLater = Self.now.addingTimeInterval(SubAgentProgress.activeCardStaleAfter + 1)
        #expect(!SubAgentProgress.capsuleState(inWindow: data.items, activeCards: data.activeAgentCards,
                                               now: muchLater).isVisible)
    }

    @Test func aTerminalCardIsNeverSeeded() throws {
        let snapshot = try decode(try snapshotObject(activeAgents: [
            try agentCard("done-card", order: 220, status: "done"),
            try agentCard("failed-card", order: 230, status: "failed"),
        ]), as: V2SessionSnapshot.self)
        let data = V2SessionData(snapshot: snapshot, now: Self.now)
        #expect(data.activeAgentCards.isEmpty)
        #expect(!SubAgentProgress.capsuleState(inWindow: data.items, activeCards: data.activeAgentCards,
                                               now: Self.now).isVisible)
    }

    @Test func anotherSessionsCardIsNotSeeded() throws {
        let snapshot = try decode(try snapshotObject(activeAgents: [try agentCard(order: 220, sessionID: "other")]),
                                  as: V2SessionSnapshot.self)
        #expect(V2SessionData(snapshot: snapshot, now: Self.now).activeAgentCards.isEmpty)
    }

    // MARK: Cold open through the projection

    /// The regression P1 exists for: no cached card, the card outside the
    /// window, and the subagent silent — the capsule used to be missing.
    @Test func aColdOpenProjectionBuildsTheCapsuleBeforeAnyFrame() throws {
        let snapshot = try decode(try snapshotObject(activeAgents: [try agentCard(order: 900)]))
        let projection = V2SessionProjection(snapshot: snapshot, maximumItems: 100)
        #expect(projection.data.items.isEmpty)
        #expect(projection.data.activeAgentCards.map(\.item.id) == ["card"])
        #expect(SubAgentProgress.capsuleState(inWindow: projection.data.items,
                                              activeCards: projection.data.activeAgentCards).runningCount == 1)
        // Without the seed the same projection has no capsule at all.
        #expect(!SubAgentProgress.capsuleState(projection.data.items).isVisible)
    }

    @Test func aCardSeededAndAlsoInTheWindowIsCountedOnce() throws {
        let object = try snapshotObject(
            activeAgents: [try agentCard(order: 220, description: "快照版本")],
            items: [try agentCard(order: 220, description: "窗口版本", revision: 3, seq: 30)])
        let projection = V2SessionProjection(snapshot: try decode(object), maximumItems: 100)
        #expect(projection.data.activeAgentCards.count == 1)
        let state = SubAgentProgress.capsuleState(inWindow: projection.data.items,
                                                  activeCards: projection.data.activeAgentCards)
        #expect(state.runningCount == 1)
        #expect(state.title == "窗口版本")
    }
}

import Foundation
import Testing
@testable import ClientCore

// The chat profile's live mark owner (pp 2026-11-17). The trailing step group
// keeps the dots through the gaps between steps; the moment a message unit
// follows it — body text or a steering row — the group settles and the
// standalone working row (or the text's own body) owns the live state.
//
// The steering case is the regression: the group above a steer bubble is
// already done (the SDK reads a steer at a tool boundary). Walking past the
// steering row to keep the group live drew the group's dots AND the
// 「正在处理中」 row under the solid bubble at the same time (device
// 2026-11-17 23:50:39).

private func liveTailItem(id: String, order: Int, type: String = "message",
                          role: String? = "assistant", status: String = "done",
                          content: [String: Any] = [:],
                          source: [String: Any] = [:]) throws -> V2TimelineItem {
    var object: [String: Any] = [
        "id": id, "sessionId": "session", "type": type, "status": status,
        "content": content, "source": source, "orderSeq": order,
        "revision": 1, "updatedSeq": order, "contentHash": id,
    ]
    if let role { object["role"] = role }
    return try decode(object)
}

private func thinkingStep(_ id: String, order: Int) throws -> V2TimelineItem {
    try liveTailItem(id: id, order: order, type: "reasoning",
                     content: ["text": "think"],
                     source: ["itemId": "msg-1", "turnId": "turn-1"])
}

private func toolStep(_ id: String, order: Int) throws -> V2TimelineItem {
    try liveTailItem(id: id, order: order, type: "tool",
                     content: ["kind": "tool", "toolName": "Bash",
                               "input": ["command": "sleep 5"]],
                     source: ["itemId": id, "nativeMessageId": "msg-1",
                              "turnId": "turn-1", "blockIndex": order])
}

private func steeringRow(_ id: String, order: Int) throws -> V2TimelineItem {
    try liveTailItem(id: id, order: order, role: "user",
                     content: ["text": "1"],
                     source: ["itemType": "steeringUserMessage",
                              "itemId": "msg-steer", "turnId": "turn-1"])
}

private func bodyRow(_ id: String, order: Int) throws -> V2TimelineItem {
    try liveTailItem(id: id, order: order,
                     content: ["text": "all done"],
                     source: ["itemId": "msg-body", "turnId": "turn-1"])
}

private func units(_ items: [V2TimelineItem]) -> [TimelineChatUnit] {
    TimelineChatGrouping.units(items: items, profile: .generic,
                               interactionTargets: [])
}

@Suite("Chat live-tail owner")
struct TimelineChatLiveTailTests {

    @Test func trailingStepGroupOwnsTheMark() throws {
        let grouped = units([try thinkingStep("r1", order: 1),
                             try toolStep("t1", order: 2)])
        #expect(TimelineChatLiveTail.stepGroupOwnsMark(grouped))
    }

    @Test func steerRowTakesTheMarkFromTheGroupAbove() throws {
        let grouped = units([try thinkingStep("r1", order: 1),
                             try toolStep("t1", order: 2),
                             try steeringRow("u1", order: 3)])
        // The steer stays its own unit; it is the strict last unit, so the
        // group above must settle and the working row draws below the bubble.
        #expect(grouped.count == 2)
        guard case let .message(_, rowIDs) = grouped.last else {
            Issue.record("the steering row did not become the trailing message unit")
            return
        }
        #expect(rowIDs == ["u1"])
        #expect(!TimelineChatLiveTail.stepGroupOwnsMark(grouped))
        // The adapter's working-row gate reads the same row: the steer is a
        // user row that does not start a visible turn.
        let steer = try steeringRow("u1", order: 3)
        #expect(steer.role == .user)
        #expect(!steer.startsVisibleTurn)
    }

    @Test func bodyTextTakesTheMark() throws {
        let grouped = units([try thinkingStep("r1", order: 1),
                             try toolStep("t1", order: 2),
                             try bodyRow("b1", order: 3)])
        #expect(!TimelineChatLiveTail.stepGroupOwnsMark(grouped))
    }

    @Test func emptyTimelineHasNoMark() {
        #expect(!TimelineChatLiveTail.stepGroupOwnsMark([]))
    }
}

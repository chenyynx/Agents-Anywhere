import Foundation
import Testing
@testable import ClientCore

// The chat profile's step model (pp 2026-10-29): consecutive thinking/tool
// rows form one group; a body row or a turn boundary breaks it; the settled
// row's counts dedupe by target the same way the label plan does.

private func stepItem(id: String, order: Int, type: String = "message",
                      role: String? = "assistant", status: String = "done",
                      content: [String: Any] = [:], source: [String: Any] = [:]) throws -> V2TimelineItem {
    var object: [String: Any] = [
        "id": id, "sessionId": "session", "type": type, "status": status,
        "content": content, "source": source, "orderSeq": order,
        "revision": 1, "updatedSeq": order, "contentHash": id,
    ]
    if let role { object["role"] = role }
    return try decode(object)
}

private func thinkingItem(_ id: String, order: Int, text: String = "think",
                          turn: String? = "turn-1",
                          status: String = "done") throws -> V2TimelineItem {
    var source: [String: Any] = ["itemId": id]
    if let turn { source["turnId"] = turn }
    return try stepItem(id: id, order: order, type: "reasoning", status: status,
                        content: ["text": text], source: source)
}

private func toolItem(_ id: String, order: Int, name: String,
                      input: [String: Any] = [:],
                      turn: String? = "turn-1",
                      status: String = "done") throws -> V2TimelineItem {
    var source: [String: Any] = ["itemId": id, "nativeMessageId": "msg-1", "blockIndex": order]
    if let turn { source["turnId"] = turn }
    return try stepItem(id: id, order: order, type: "tool", status: status,
                        content: ["kind": "tool", "toolName": name, "input": input],
                        source: source)
}

private func bodyItem(_ id: String, order: Int, text: String,
                      turn: String? = "turn-1") throws -> V2TimelineItem {
    var source: [String: Any] = ["itemId": "msg-body"]
    if let turn { source["turnId"] = turn }
    return try stepItem(id: id, order: order, content: ["text": text], source: source)
}

private func userItem(_ id: String, order: Int) throws -> V2TimelineItem {
    try stepItem(id: id, order: order, role: "user",
                 content: ["text": "hi"], source: ["itemId": "msg-user"])
}

@Suite("Chat step-group grouping")
struct TimelineStepGroupingTests {
    @Test func consecutiveStepsFormOneGroupAndBodyBreaksIt() throws {
        let items = [
            try thinkingItem("r1", order: 1),
            try toolItem("t1", order: 2, name: "Read"),
            try thinkingItem("r2", order: 3),
            try toolItem("t2", order: 4, name: "Bash"),
            try bodyItem("b1", order: 5, text: "All done."),
        ]
        let units = TimelineChatGrouping.units(items: items, profile: .generic,
                                               interactionTargets: [])
        #expect(units.count == 2)
        guard case let .stepGroup(group, rowIDs) = units[0] else {
            Issue.record("first unit is not a step group")
            return
        }
        #expect(rowIDs == ["r1", "t1", "r2", "t2"])
        #expect(group.steps.count == 4)
        #expect(group.id == "steps:r1")
        guard case let .message(key, messageRowIDs) = units[1] else {
            Issue.record("second unit is not a message")
            return
        }
        #expect(messageRowIDs == ["b1"])
        #expect(key == "msg-body")
    }

    @Test func declaredTurnChangeBreaksTheGroup() throws {
        let items = [
            try thinkingItem("r1", order: 1, turn: "turn-1"),
            try toolItem("t1", order: 2, name: "Read", turn: "turn-1"),
            try thinkingItem("r2", order: 3, turn: "turn-2"),
        ]
        let units = TimelineChatGrouping.units(items: items, profile: .generic,
                                               interactionTargets: [])
        #expect(units.count == 2)
        guard case let .stepGroup(first, _) = units[0],
              case let .stepGroup(second, _) = units[1] else {
            Issue.record("expected two step groups")
            return
        }
        #expect(first.steps.count == 2)
        #expect(second.steps.count == 1)
    }

    @Test func userMessageBreaksTheGroup() throws {
        let items = [
            try thinkingItem("r1", order: 1),
            try userItem("u1", order: 2),
            try thinkingItem("r2", order: 3),
        ]
        let units = TimelineChatGrouping.units(items: items, profile: .generic,
                                               interactionTargets: [])
        #expect(units.count == 3)
        guard case .stepGroup = units[0],
              case .message = units[1],
              case .stepGroup = units[2] else {
            Issue.record("expected step, message, step")
            return
        }
    }

    @Test func liveStepIsTheTrailingRunningStep() throws {
        let items = [
            try thinkingItem("r1", order: 1, status: "done"),
            try toolItem("t1", order: 2, name: "Read", status: "running"),
        ]
        let units = TimelineChatGrouping.units(items: items, profile: .generic,
                                               interactionTargets: [])
        guard case let .stepGroup(group, _) = units[0] else {
            Issue.record("expected a step group")
            return
        }
        #expect(group.isRunning)
        #expect(group.liveStep?.id == "t1")
    }
}

@Suite("Chat step-group summary")
struct TimelineStepGroupSummaryTests {
    private func group(_ steps: [TimelineStep]) -> TimelineStepGroup {
        TimelineStepGroup(id: "steps:test", steps: steps)
    }

    private func tool(_ id: String, name: String, input: [String: Any]) throws -> TimelineStep {
        .tool(call: CodeToolCall(item: try toolItem(id, order: 1, name: name, input: input)))
    }

    @Test func countsDedupeTargetsPerCategory() throws {
        let steps: [TimelineStep] = [
            .thinking(id: "r1", text: "think", status: .done),
            try tool("t1", name: "Read", input: ["file_path": "/repo/a.swift"]),
            try tool("t2", name: "Read", input: ["file_path": "/repo/a.swift"]),
            try tool("t3", name: "Bash", input: ["command": "swift test"]),
            try tool("t4", name: "Edit", input: ["file_path": "/repo/b.swift"]),
        ]
        let summary = TimelineStepSummarizer.summary(steps: steps, cwd: nil)
        #expect(summary.thinkingCount == 1)
        #expect(summary.readFiles == 1)   // one distinct file, two calls
        #expect(summary.ranCommands == 1)
        #expect(summary.editedFiles == 1)
        #expect(summary.toolCount == 4)
        let line = TimelineStepSummaryText.line(summary, locale: Locale(identifier: "zh_CN"))
        #expect(line.contains("1"))
    }

    @Test func liveThinkingLineIsTheLastNonEmptyLine() {
        let step = TimelineStep.thinking(id: "r", text: "\nfirst line\n\n  second line  \n",
                                         status: .running)
        #expect(step.liveThinkingLine == "second line")
        #expect(TimelineStep.thinking(id: "r", text: "\n\n", status: .running)
            .liveThinkingLine == nil)
    }
}

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

// The wire gives a reasoning row the enclosing message as its `itemId` and a
// tool row the same message as `nativeMessageId`; the step grouping keys on
// that shared message identity, exactly like the Code planner.
private func thinkingItem(_ id: String, order: Int, text: String = "think",
                          message: String = "msg-1",
                          turn: String? = "turn-1",
                          status: String = "done") throws -> V2TimelineItem {
    var source: [String: Any] = ["itemId": message]
    if let turn { source["turnId"] = turn }
    return try stepItem(id: id, order: order, type: "reasoning", status: status,
                        content: ["text": text], source: source)
}

private func toolItem(_ id: String, order: Int, name: String,
                      input: [String: Any] = [:],
                      message: String = "msg-1",
                      turn: String? = "turn-1",
                      status: String = "done",
                      interrupted: Bool = false,
                      parent: String? = nil) throws -> V2TimelineItem {
    var source: [String: Any] = ["itemId": id, "nativeMessageId": message,
                                 "blockIndex": order]
    if let turn { source["turnId"] = turn }
    var content: [String: Any] = ["kind": "tool", "toolName": name, "input": input]
    if interrupted { content["turnInterrupted"] = true }
    if let parent { content["parentItemId"] = parent }
    return try stepItem(id: id, order: order, type: "tool", status: status,
                        content: content, source: source)
}

private func bodyItem(_ id: String, order: Int, text: String,
                      message: String = "msg-body",
                      turn: String? = "turn-1") throws -> V2TimelineItem {
    var source: [String: Any] = ["itemId": message]
    if let turn { source["turnId"] = turn }
    return try stepItem(id: id, order: order, content: ["text": text], source: source)
}

private func userItem(_ id: String, order: Int) throws -> V2TimelineItem {
    try stepItem(id: id, order: order, role: "user",
                 content: ["text": "hi"], source: ["itemId": "msg-user"])
}

/// An Agent card row: `content.kind == "agent_call"`, published by the card's
/// own fold — it can carry a different turn id than the message rows it was
/// dispatched from (pp 2026-11-18 server row 2865).
private func agentCardItem(_ id: String, order: Int,
                           turn: String) throws -> V2TimelineItem {
    try stepItem(id: id, order: order, type: "tool",
                 content: ["kind": "agent_call", "action": "invoke"],
                 source: ["itemId": id, "turnId": turn])
}

@Suite("Chat step-group grouping")
struct TimelineStepGroupingTests {

    /// A session-blocking interaction card is drawn in the composer dock, so
    /// its anchor row merges into the running step group like any other step.
    /// Only a non-blocking (inline) card keeps the standalone row it renders
    /// under (pp 2026-11-16).
    @Test func aBlockingInteractionAnchorMergesIntoTheStepGroup() throws {
        let items = [
            try thinkingItem("r1", order: 1),
            try toolItem("q1", order: 2, name: "AskUserQuestion",
                         input: ["questions": [["question": "弹窗表现如何？"]]]),
        ]
        let merged = TimelineChatGrouping.units(items: items, profile: .generic,
                                                interactionTargets: ["q1"],
                                                standaloneTargets: [])
        #expect(merged.count == 1)
        guard case let .stepGroup(_, rowIDs) = merged[0] else {
            Issue.record("blocking anchor did not merge")
            return
        }
        #expect(rowIDs == ["r1", "q1"])

        let inline = TimelineChatGrouping.units(items: items, profile: .generic,
                                                interactionTargets: ["q1"],
                                                standaloneTargets: ["q1"])
        #expect(inline.count == 2)
        guard case let .standalone(rowID) = inline[1] else {
            Issue.record("inline anchor lost its standalone row")
            return
        }
        #expect(rowID == "q1")
    }

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
        #expect(group.id == "steps:msg-1")
        guard case let .message(key, messageRowIDs) = units[1] else {
            Issue.record("second unit is not a message")
            return
        }
        #expect(messageRowIDs == ["b1"])
        #expect(key == "msg-body")
    }

    @Test func stepsAcrossAssistantMessagesStayOneGroupUntilText() throws {
        // One turn, two API assistant messages back to back: pp's model keeps
        // one live row for the whole step run — the row must not settle into a
        // summary between messages. Body text (or a turn boundary) ends it.
        let items = [
            try thinkingItem("r1", order: 1, message: "msg-1"),
            try toolItem("t1", order: 2, name: "Read", message: "msg-1"),
            try thinkingItem("r2", order: 3, message: "msg-2"),
            try toolItem("t2", order: 4, name: "Bash", message: "msg-2"),
        ]
        let units = TimelineChatGrouping.units(items: items, profile: .generic,
                                               interactionTargets: [])
        #expect(units.count == 1)
        guard case let .stepGroup(group, rowIDs) = units[0] else {
            Issue.record("expected one step group")
            return
        }
        #expect(rowIDs == ["r1", "t1", "r2", "t2"])
        #expect(group.id == "steps:msg-1")
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

    @Test func anInterruptedRowMarksTheWholeGroupAsResidue() throws {
        let items = [
            try thinkingItem("r1", order: 1),
            try toolItem("t1", order: 2, name: "Bash", status: "failed",
                         interrupted: true),
        ]
        let units = TimelineChatGrouping.units(items: items, profile: .generic,
                                               interactionTargets: [])
        guard case let .stepGroup(group, _) = units[0] else {
            Issue.record("expected a step group")
            return
        }
        #expect(group.hasInterruptedStep)
    }

    /// The SubAgent panel renders exactly the rows the main timeline hides
    /// (L2.1). Its grouping call must opt out of the child-row filter; the
    /// default stays the timeline's rule.
    @Test func subAgentChildRowsGroupOnlyWhenThePanelAsks() throws {
        let child = try toolItem("t1", order: 1, name: "Read",
                                 input: ["file_path": "/repo/a.swift"],
                                 parent: "card-1")
        let timeline = TimelineChatGrouping.units(items: [child], profile: .generic,
                                                  interactionTargets: [])
        #expect(timeline.isEmpty)
        let panel = TimelineChatGrouping.units(items: [child], profile: .generic,
                                               interactionTargets: [],
                                               excludesSubAgentChildren: false)
        #expect(panel.count == 1)
        guard case let .stepGroup(group, rowIDs) = panel.first else {
            Issue.record("panel grouping did not produce a step group")
            return
        }
        #expect(rowIDs == ["t1"])
        #expect(group.steps.count == 1)
    }

    @Test func aPlainFailureDoesNotMarkTheGroupAsInterrupted() throws {
        let items = [
            try thinkingItem("r1", order: 1),
            try toolItem("t1", order: 2, name: "Bash", status: "failed"),
        ]
        let units = TimelineChatGrouping.units(items: items, profile: .generic,
                                               interactionTargets: [])
        guard case let .stepGroup(group, _) = units[0] else {
            Issue.record("expected a step group")
            return
        }
        #expect(!group.hasInterruptedStep)
    }
}

    /// pp 2026-11-18：Agent 卡片行由自己的折叠发布，可能带着和同回合其它行
    /// 不同的 turnId。它不该切步骤组——否则一个回合被切成三行，页脚分桶
    /// 也跟着切（服务器第 2865 行：邻居全是 6447524c，卡片是 ed82e9b7）。
    @Test func anAgentCardWithItsOwnTurnDoesNotSplitTheStepRun() throws {
        let items = [
            try thinkingItem("r1", order: 1, turn: "turn-a"),
            try toolItem("t1", order: 2, name: "Bash", turn: "turn-a"),
            try agentCardItem("card", order: 3, turn: "turn-b"),
            try thinkingItem("r2", order: 4, turn: "turn-a"),
            try bodyItem("b1", order: 5, text: "done", turn: "turn-a"),
        ]
        let units = TimelineChatGrouping.units(items: items, profile: .generic,
                                               interactionTargets: [])
        #expect(units.count == 2)
        guard case let .stepGroup(_, rowIDs) = units[0] else {
            Issue.record("the run did not stay one step group")
            return
        }
        #expect(rowIDs == ["r1", "t1", "card", "r2"])
        guard case .message = units[1] else {
            Issue.record("the body row must stay its own message unit")
            return
        }
    }

    /// 卡片真的开启一个新回合（后面的行也都换了 turn）时，边界仍然生效。
    @Test func anAgentCardThatOpensANewTurnStillSplitsTheRun() throws {
        let items = [
            try thinkingItem("r1", order: 1, turn: "turn-a"),
            try agentCardItem("card", order: 2, turn: "turn-b"),
            try thinkingItem("r2", order: 3, turn: "turn-b"),
        ]
        let units = TimelineChatGrouping.units(items: items, profile: .generic,
                                               interactionTargets: [])
        #expect(units.count == 2)
    }

@Suite("Chat step-group summary")
struct TimelineStepGroupSummaryTests {
    private func group(_ steps: [TimelineStep]) -> TimelineStepGroup {
        TimelineStepGroup(id: "steps:test", steps: steps)
    }

    private func tool(_ id: String, name: String, input: [String: Any]) throws -> TimelineStep {
        .tool(call: CodeToolCall(item: try toolItem(id, order: 1, name: name, input: input)))
    }

    /// A subagent dispatch row the way the runtimes project it: an
    /// `agent_call` tool row with a dispatch action.
    private func agentStep(_ id: String, status: String,
                           action: String = "invoke") throws -> TimelineStep {
        var value = try itemObject(id: id, text: "")
        value["type"] = "tool"; value["role"] = "assistant"; value["status"] = status
        value["content"] = ["kind": "agent_call", "action": action,
                            "description": "Third 2-minute timing test"]
        return .tool(call: CodeToolCall(item: try decode(value)))
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

    @Test func aQuestionIsItsOwnCountedCategory() throws {
        // A step group with 2 thinking + 1 question used to title itself
        // 「思考 2 次」 while its sheet listed three rows: the summarizer's
        // verb switch never sees a question because `CodeToolLabelPlan`
        // folds it into the generic `other/.tools` phrase (pp 2026-11-16).
        let steps: [TimelineStep] = [
            .thinking(id: "r1", text: "think", status: .done),
            try tool("q1", name: "AskUserQuestion",
                     input: ["questions": [["question": "弹窗表现如何？"]]]),
            .thinking(id: "r2", text: "think again", status: .done),
        ]
        let summary = TimelineStepSummarizer.summary(steps: steps, cwd: nil)
        #expect(summary.thinkingCount == 2)
        #expect(summary.askedCount == 1)
        #expect(summary.toolCount == 1)
        let line = TimelineStepSummaryText.line(summary, locale: Locale(identifier: "zh_CN"))
        #expect(line.contains("思考 2 次"))
        #expect(line.contains("询问 1 次"))
    }

    @Test func aSubagentCallIsItsOwnCountedCategory() throws {
        // pp 2026-11-18: one thinking step plus one subagent run used to read
        // 「思考 1 次」 with no mention of the agent — the label plan folds a
        // task into `.ranAgent`, which the summarizer's verb switch never saw.
        let steps: [TimelineStep] = [
            .thinking(id: "r1", text: "think", status: .done),
            try tool("a1", name: "Task", input: ["description": "Third 2-minute timing test"]),
        ]
        let summary = TimelineStepSummarizer.summary(steps: steps, cwd: nil)
        #expect(summary.thinkingCount == 1)
        #expect(summary.agentCount == 1)
        #expect(summary.toolCount == 1)
        let line = TimelineStepSummaryText.line(summary, locale: Locale(identifier: "zh_CN"))
        #expect(line.contains("思考 1 次"))
        #expect(line.contains("运行了 1 个智能体"))
    }

    /// A dispatched subagent that is still running reads present-tense: the
    /// row must not say 「运行了」 while the agent works in the background
    /// (pp 2026-11-18, 文案改进行时). The live dots stay on the working row;
    /// this row keeps its icon.
    @Test func aRunningSubagentUsesThePresentTensePhrase() throws {
        let steps: [TimelineStep] = [
            .thinking(id: "r1", text: "think", status: .done),
            try agentStep("a1", status: "running"),
        ]
        let summary = TimelineStepSummarizer.summary(steps: steps, cwd: nil)
        #expect(summary.agentCount == 1)
        #expect(summary.activeAgentCount == 1)
        let line = TimelineStepSummaryText.line(summary, locale: Locale(identifier: "zh_CN"))
        #expect(line.contains("正在运行 1 个智能体"))
        #expect(!line.contains("运行了"))
    }

    @Test func aSettledSubagentKeepsThePastTensePhrase() throws {
        let steps: [TimelineStep] = [try agentStep("a1", status: "done")]
        let summary = TimelineStepSummarizer.summary(steps: steps, cwd: nil)
        #expect(summary.activeAgentCount == 0)
        let line = TimelineStepSummaryText.line(summary, locale: Locale(identifier: "zh_CN"))
        #expect(line.contains("运行了 1 个智能体"))
    }

    /// The settled row borrows the activity sweep while a dispatched agent is
    /// still working (pp 2026-11-19): 「正在运行 N 个智能体」 alone read as a
    /// finished row. Only the text sweeps — the icon stays the group's own.
    @Test func aRunningBackgroundAgentKeepsTheSettledRowSweeping() throws {
        let runningSteps: [TimelineStep] = [
            .thinking(id: "r1", text: "think", status: .done),
            try agentStep("a1", status: "running"),
        ]
        let running = TimelineStepGroup(
            id: "steps:running", steps: runningSteps,
            summary: TimelineStepSummarizer.summary(steps: runningSteps, cwd: nil))
        #expect(running.hasRunningBackgroundAgent)

        let settledSteps: [TimelineStep] = [try agentStep("a1", status: "done")]
        let settled = TimelineStepGroup(
            id: "steps:settled", steps: settledSteps,
            summary: TimelineStepSummarizer.summary(steps: settledSteps, cwd: nil))
        #expect(!settled.hasRunningBackgroundAgent)

        // A control call on an agent that already exists is not a dispatch:
        // it must not keep the row sweeping.
        let controlSteps: [TimelineStep] = [
            try agentStep("a1", status: "running", action: "wait"),
        ]
        let control = TimelineStepGroup(
            id: "steps:control", steps: controlSteps,
            summary: TimelineStepSummarizer.summary(steps: controlSteps, cwd: nil))
        #expect(!control.hasRunningBackgroundAgent)
    }

    /// The turn's working row keeps its mark while the turn streams, even when
    /// the only running step is a **background** dispatch (pp 2026-11-19:
    /// 「我还在调工具，那还是保持三个点」). Pins the rule against re-adding a
    /// per-hand-off live-pose guard — with such a guard this expectation goes
    /// red, because the dispatch reports `runInBackground`.
    @Test func aRunningBackgroundDispatchKeepsTheTurnMark() throws {
        var value = try itemObject(id: "a1", text: "")
        value["type"] = "tool"; value["role"] = "assistant"; value["status"] = "running"
        value["content"] = ["kind": "agent_call", "action": "invoke",
                            "description": "Third 2-minute timing test",
                            "runInBackground": true]
        let steps: [TimelineStep] = [
            .thinking(id: "r1", text: "think", status: .done),
            .tool(call: CodeToolCall(item: try decode(value))),
        ]
        let group = TimelineStepGroup(id: "steps:background", steps: steps)
        #expect(group.showsRunningPose(isLiveTail: false, allowsRunningPose: true))
        // The turn-membership gate still decides: without the current turn's
        // allowance the group must settle (reply over, agent still running).
        #expect(!group.showsRunningPose(isLiveTail: false, allowsRunningPose: false))
    }

    @Test func mixedSubagentStatesCountOnlyTheRunningOnes() throws {
        let steps: [TimelineStep] = [
            try agentStep("a1", status: "done"),
            try agentStep("a2", status: "running"),
        ]
        let summary = TimelineStepSummarizer.summary(steps: steps, cwd: nil)
        #expect(summary.agentCount == 2)
        #expect(summary.activeAgentCount == 1)
        let line = TimelineStepSummaryText.line(summary, locale: Locale(identifier: "zh_CN"))
        #expect(line.contains("正在运行 1 个智能体"))
    }

    /// A control call is not a dispatch: even while it runs it must not turn
    /// the phrase present-tense for an agent that is not working. The wire's
    /// real action words for these are `send_input` / `wait` / `close`, plus
    /// `unknown` (DSH's `list_agents` degrades to it).
    @Test func aRunningControlCallIsNotCountedAsRunning() throws {
        for action in ["send_input", "wait", "close", "unknown"] {
            let summary = TimelineStepSummarizer.summary(
                steps: [try agentStep("a1", status: "running", action: action)], cwd: nil)
            #expect(summary.agentCount == 1)
            #expect(summary.activeAgentCount == 0)
            let line = TimelineStepSummaryText.line(summary, locale: Locale(identifier: "zh_CN"))
            #expect(line.contains("运行了 1 个智能体"))
        }
    }

    @Test func severalSubagentCallsCountOnceEach() throws {
        let steps: [TimelineStep] = [
            try tool("a1", name: "Task", input: ["description": "first"]),
            try tool("a2", name: "Task", input: ["description": "second"]),
        ]
        let summary = TimelineStepSummarizer.summary(steps: steps, cwd: nil)
        #expect(summary.agentCount == 2)
        #expect(summary.toolCount == 2)
        let line = TimelineStepSummaryText.line(summary, locale: Locale(identifier: "zh_CN"))
        #expect(line.contains("运行了 2 个智能体"))
    }

    @Test func liveThinkingLineIsTheLastNonEmptyLine() {
        let step = TimelineStep.thinking(id: "r", text: "\nfirst line\n\n  second line  \n",
                                         status: .running)
        #expect(step.liveThinkingLine == "second line")
        #expect(TimelineStep.thinking(id: "r", text: "\n\n", status: .running)
            .liveThinkingLine == nil)
    }
}

@Suite("Chat step-group live mark eligibility")
struct TimelineStepGroupLiveMarkTests {
    private func group(_ steps: [TimelineStep]) -> TimelineStepGroup {
        TimelineStepGroup(id: "steps:test", steps: steps)
    }

    @Test func terminalFailureResidueCannotCarryTheLiveMark() {
        for status in [V2TimelineItemStatus.interrupted, .failed, .cancelled] {
            #expect(!group([.thinking(id: "r", text: "think", status: status)])
                .canCarryLiveMark)
        }
    }

    @Test func aRunningStepAlwaysCarriesTheMark() {
        #expect(group([.thinking(id: "r", text: "think", status: .running)])
            .canCarryLiveMark)
    }

    @Test func aSettledLiveTurnBetweenStepsStillCarriesTheMark() {
        #expect(group([.thinking(id: "r", text: "think", status: .done)])
            .canCarryLiveMark)
    }

    @Test func anyTerminalFailureInTheGroupDisqualifiesIt() {
        #expect(!group([
            .thinking(id: "r1", text: "think", status: .done),
            .thinking(id: "r2", text: "think", status: .interrupted),
        ]).canCarryLiveMark)
    }

    @Test func aFailedToolKeepsTheMarkWhileTheTurnStillRuns() {
        // The agent moves on after a failed tool; while the runtime reports
        // the turn running the row must keep the live pose, otherwise a
        // mid-turn ⚠️ settles it (pp 2026-11-10).
        let failed = group([
            .thinking(id: "r1", text: "think", status: .done),
            .thinking(id: "r2", text: "think", status: .failed),
        ])
        #expect(failed.canCarryLiveMark(turnIsRunning: true))
        #expect(!failed.canCarryLiveMark(turnIsRunning: false))
    }

    @Test func interruptedResidueCannotCarryTheMarkWhileANewTurnRuns() {
        // Device 2026-11-14: a queued send started a new turn while the
        // previous (interrupted) group was still the last unit; the durable
        // marker must keep it settled even though the new turn is streaming.
        var residue = group([.thinking(id: "r", text: "think", status: .done)])
        residue.hasInterruptedStep = true
        #expect(!residue.canCarryLiveMark(turnIsRunning: true))
        #expect(!residue.canCarryLiveMark(turnIsRunning: false))
    }

    @Test func aFreshIdleSuppressesTheStaleRunningPose() {
        // The stop ack proves the turn is over; a step snapshot that still
        // says `running` is stale data and must not keep animating
        // (pp 2026-11-14: the row spun for ~2.4 s after the interrupt while
        // the connector was still publishing the settled rows).
        let running = group([.thinking(id: "r", text: "think", status: .running)])
        #expect(running.showsRunningPose(isLiveTail: false, allowsRunningPose: true))
        #expect(!running.showsRunningPose(isLiveTail: false, allowsRunningPose: false))
    }

    @Test func theLiveTailStillDrawsTheBetweenStepsPose() {
        // A settled group draws the live pose only because it is the tail;
        // `allowsRunningPose` alone cannot animate a group with no running
        // step (the adapter sets the tail while the turn streams).
        let settled = group([.thinking(id: "r", text: "think", status: .done)])
        #expect(settled.showsRunningPose(isLiveTail: true, allowsRunningPose: true))
        #expect(settled.showsRunningPose(isLiveTail: true, allowsRunningPose: false))
        #expect(!settled.showsRunningPose(isLiveTail: false, allowsRunningPose: true))
        #expect(!settled.showsRunningPose(isLiveTail: false, allowsRunningPose: false))
    }
}

@Suite("Step sheet tail follow")
struct StepSheetTailFollowTests {
    private func viewport(offset: CGFloat,
                          content: CGFloat = 2000,
                          container: CGFloat = 600) -> TimelineViewport {
        TimelineViewport(contentHeight: content, containerHeight: container,
                         offsetY: offset)
    }

    @Test func aSettledSheetDoesNotFollowByDefault() {
        #expect(!StepSheetTailFollow().followsTail)
    }

    @Test func aSampleAwayFromTheBottomDoesNotReleaseTheLatch() {
        // This is the sample a content growth produces: the page, not the
        // reader, moved the bottom edge away. The follow must survive it,
        // otherwise the first new step would stop the sheet from following.
        var follow = StepSheetTailFollow(followsTail: true)
        follow.consume(viewport(offset: 100))
        #expect(follow.followsTail)
    }

    @Test func theReaderTakingOverReleasesTheLatch() {
        var follow = StepSheetTailFollow(followsTail: true)
        follow.readerTookOver()
        follow.consume(viewport(offset: 100))
        #expect(!follow.followsTail)
    }

    @Test func restingAtTheBottomReArmsTheLatch() {
        var follow = StepSheetTailFollow(followsTail: true)
        follow.readerTookOver()
        follow.consume(viewport(offset: 1400))
        #expect(follow.followsTail)
    }

    @Test func anUnmeasuredSampleCannotReArmTheLatch() {
        // The zero sample arrives before the list has laid out; an "empty
        // viewport is at its bottom" reading must not re-arm the follow.
        var follow = StepSheetTailFollow(followsTail: false)
        follow.consume(TimelineViewport())
        #expect(!follow.followsTail)
    }
}

@Suite("Running-turn step groups")
struct TimelineRunningTurnStepGroupsTests {
    private func group(_ id: String, steps: [String]) -> TimelineChatUnit {
        .stepGroup(TimelineStepGroup(id: id, steps: []), rowIDs: steps)
    }

    @Test func groupsAfterTheLastPromptBelongToTheRunningTurn() {
        let units: [TimelineChatUnit] = [
            group("steps:old", steps: ["s0"]),
            .message(key: "m", rowIDs: ["body"]),
            group("steps:a", steps: ["s1"]),
            group("steps:b", steps: ["s2"]),
        ]
        let orders = ["s0": 2, "s1": 4, "s2": 7]
        let ids = TimelineRunningTurnStepGroups.ids(
            units: units, orderSeq: { orders[$0] }, lastUserOrder: 3)
        #expect(ids == ["steps:a", "steps:b"])
    }

    @Test func aGroupThatStartedBeforeTheLastPromptIsExcluded() {
        // The turn boundary is the group's FIRST row: a group that spans the
        // prompt belongs to the settled turn even though its tail is newer.
        let units: [TimelineChatUnit] = [group("steps:spanning",
                                               steps: ["before", "after"])]
        let orders = ["before": 1, "after": 5]
        let ids = TimelineRunningTurnStepGroups.ids(
            units: units, orderSeq: { orders[$0] }, lastUserOrder: 3)
        #expect(ids.isEmpty)
    }

    @Test func aGroupWhoseFirstRowIsNotResolvableIsExcluded() {
        let units: [TimelineChatUnit] = [group("steps:a", steps: ["missing"])]
        let ids = TimelineRunningTurnStepGroups.ids(
            units: units, orderSeq: { _ in nil }, lastUserOrder: 0)
        #expect(ids.isEmpty)
    }

    @Test func aGroupWithNoRowsIsExcluded() {
        let units: [TimelineChatUnit] = [group("steps:a", steps: [])]
        let ids = TimelineRunningTurnStepGroups.ids(
            units: units, orderSeq: { _ in 5 }, lastUserOrder: 0)
        #expect(ids.isEmpty)
    }
}

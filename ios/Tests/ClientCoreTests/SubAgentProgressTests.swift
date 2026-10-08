import Foundation
import Testing
@testable import ClientCore

/// L2 iOS batch (claude-subagent-progress-tasks.md §3.2/§3.3): capsule state,
/// phase words, number formats, panel tabs/children and the widened grouping.
@Suite struct SubAgentProgressTests {
    private func item(_ id: String, type: String = "tool", status: String = "running", order: Int = 1,
                      role: String? = nil, createdAt: String? = nil, updatedAt: String? = nil,
                      source: [String: Any]? = nil,
                      content: [String: Any]) throws -> V2TimelineItem {
        var value = try itemObject(id: id, order: order)
        value["type"] = type; value["status"] = status; value["content"] = content
        if let role { value["role"] = role }
        if let createdAt { value["createdAt"] = createdAt }
        if let updatedAt { value["updatedAt"] = updatedAt }
        if let source { value["source"] = source }
        return try decode(value)
    }

    private func cardItem(_ id: String = "card", order: Int = 1, status: String = "running",
                          description: String? = "排查服务状态", agentType: String? = nil,
                          prompt: String? = nil, agents: [String: Any]? = nil, usage: [String: Any]? = nil,
                          summary: String? = nil, agentId: String? = nil, parentItemId: String? = nil,
                          createdAt: String? = nil, updatedAt: String? = nil, endTime: Int? = nil) throws -> V2TimelineItem {
        var content: [String: Any] = ["kind": "agent_call", "action": "invoke"]
        if let description { content["description"] = description }
        if let agentType { content["agentType"] = agentType }
        if let prompt { content["prompt"] = prompt }
        if let agents { content["agents"] = agents }
        if let usage { content["usage"] = usage }
        if let summary { content["summary"] = summary }
        if let agentId { content["agentId"] = agentId }
        if let parentItemId { content["parentItemId"] = parentItemId }
        if let endTime { content["endTime"] = endTime }
        return try item(id, status: status, order: order, createdAt: createdAt, updatedAt: updatedAt, content: content)
    }

    /// The epoch-ms `endTime` the connector folds onto a terminal card.
    private func millis(_ iso: String) -> Int {
        let formatter = ISO8601DateFormatter()
        return Int(formatter.date(from: iso)!.timeIntervalSince1970 * 1000)
    }

    private func card(_ item: V2TimelineItem) throws -> SubAgentCard {
        try #require(SubAgentProgress.card(item))
    }

    /// The connector's launch receipt: the subagent is dispatched but has not
    /// reported a task event yet, so this entry is still `async_launched`.
    private func asyncEntry(_ status: String = "async_launched") -> [String: Any] {
        ["t1": ["status": status, "subagentType": "general-purpose"]]
    }

    // MARK: Card projection

    @Test func cardParsingReadsTheConnectorConvention() throws {
        let parsed = try card(try cardItem(description: "分析日志", agentType: "Explore", prompt: "Check the logs",
            agents: ["t1": ["status": "running", "lastToolName": "Bash", "subagentType": "Explore"]],
            usage: ["toolCalls": 7, "tokens": 33_555, "durationMs": 24_723],
            summary: "AUDIT DONE", agentId: "t1"))
        #expect(parsed.id == "card")
        #expect(parsed.taskName == "分析日志")
        #expect(parsed.agentType == "Explore")
        #expect(parsed.badge == "Explore")
        #expect(parsed.prompt == "Check the logs")
        #expect(parsed.phase == .running)
        #expect(parsed.toolCalls == 7 && parsed.tokens == 33_555 && parsed.durationMs == 24_723)
        #expect(parsed.summary == "AUDIT DONE")
        #expect(parsed.isTopLevel)
        // Default type names earn no badge; the task name falls back to Agent.
        let plain = try card(try cardItem(description: nil, agentType: "general-purpose"))
        #expect(plain.badge == nil && plain.agentType == "general-purpose")
        #expect(plain.taskName == String(localized: "Agent"))
        // Non-card items never project.
        #expect(SubAgentProgress.card(try item("tool", content: ["kind": "command", "command": "ls"])) == nil)
        #expect(SubAgentProgress.card(try item("text", type: "message", content: ["text": "hi"])) == nil)
    }

    @Test func nestedCardsCarryTheirParentAndTheEntryPointFiltersThem() throws {
        let outer = try cardItem("outer", order: 1)
        let nested = try cardItem("nested", order: 2, parentItemId: "outer")
        #expect(SubAgentProgress.topLevelCards(in: [outer, nested]).map(\.id) == ["outer"])
        #expect(SubAgentProgress.cards(in: [outer, nested]).map(\.id) == ["outer", "nested"])
        #expect(try card(nested).parentItemID == "outer")
        #expect(try !card(nested).isTopLevel)
    }

    @Test func phaseWordsAreDefensive() throws {
        func phase(_ status: String) throws -> SubAgentPhase { try card(try cardItem(status: status)).phase }
        #expect(try phase("running") == .running)
        #expect(try phase("pending") == .running)
        #expect(try phase("done") == .completed)
        #expect(try phase("failed") == .failed)
        #expect(try phase("interrupted") == .interrupted)
        #expect(try phase("cancelled") == .interrupted)
        #expect(try phase("running").word == "运行中")
        #expect(try phase("done").word == "已完成")
        #expect(try phase("failed").word == "失败")
        #expect(try phase("interrupted").word == "已中断")
        // An unrecognized wire status travels verbatim (未知原文).
        let custom = try phase("vendor_paused")
        #expect(custom == .unknown("vendor_paused") && custom.word == "vendor_paused")
        // A missing status has nothing to pass through.
        var value = try itemObject(id: "card", order: 1)
        value["type"] = "tool"; value["content"] = ["kind": "agent_call"]
        value.removeValue(forKey: "status")
        let missing = try card(try decode(value))
        #expect(missing.phase == .unknown(nil) && missing.phase.word == "未知")
        // 启动中 is a word of its own — it must not borrow 运行中's.
        let starting = try card(try cardItem(status: "running", agents: asyncEntry()))
        #expect(starting.phase == .starting && starting.phase.word == "启动中")
    }

    // MARK: Launch window (async_launched)
    //
    // The item status and the agents entry disagree on purpose: a launch
    // receipt keeps the entry at `async_launched` while the item is already
    // `running`, and an old connector may even stamp `done` on it. The entry
    // is the only thing that knows, so it outranks the item status.

    @Test func doneWithAsyncAgentEntryDefendsToStarting() throws {
        // The false-done window: the item is terminal, the subagent is not.
        let stale = try card(try cardItem(status: "done", agents: asyncEntry()))
        #expect(stale.phase == .starting && stale.phase.word == "启动中")
        // Mid-launch the item already reads "running" — 启动中 must win over it.
        let launching = try card(try cardItem(status: "running", agents: asyncEntry()))
        #expect(launching.phase == .starting)
        // …and over "pending" / "waiting_approval" too.
        #expect(try card(try cardItem(status: "pending", agents: asyncEntry())).phase == .starting)
        // Failures stay failures: a launch never launders a real failure.
        #expect(try card(try cardItem(status: "failed", agents: asyncEntry())).phase == .failed)
        #expect(try card(try cardItem(status: "interrupted", agents: asyncEntry())).phase == .interrupted)
    }

    @Test func doneWithoutAsyncAgentEntryStaysCompleted() throws {
        // No agents entry at all: the pre-existing mapping, untouched.
        #expect(try card(try cardItem(status: "done")).phase == .completed)
        // A finished subagent says so on its entry: no launch signal to honor.
        let finished = try card(try cardItem(status: "done", agents: asyncEntry("completed")))
        #expect(finished.phase == .completed && finished.phase.word == "已完成")
        // An entry without a status is not a launch (缺失不显), or every card
        // with an agents map would be stuck at 启动中 forever.
        let bare = try card(try cardItem(status: "done", agents: ["t1": ["subagentType": "Explore"]]))
        #expect(bare.phase == .completed)
        // Only the single-entry map launches: with several tasks the primary
        // entry is the one that reports a real state.
        let multi = try card(try cardItem(status: "running",
            agents: ["t1": ["status": "async_launched"], "t2": ["status": "running"]]))
        #expect(multi.phase == .running)
    }

    @Test func startingIsActiveAndKeepsTheCapsuleAndDefaultTab() throws {
        let starting = try cardItem("a", order: 1, description: "排查日志", agents: asyncEntry())
        let state = SubAgentProgress.capsuleState([starting, try cardItem("b", order: 2, status: "done")])
        #expect(state.isVisible && state.runningCount == 1)
        #expect(state.latestRunningID == "a" && state.title == "排查日志")
        // VoiceOver follows the phase word instead of a hardcoded 运行中.
        #expect(state.accessibilityText == "排查日志，启动中")
        let running = SubAgentProgress.capsuleState([try cardItem("a", order: 1, description: "排查日志")])
        #expect(running.accessibilityText == "排查日志，运行中")
        // …and a failing batch still overrides both.
        let failed = SubAgentProgress.capsuleState(try [
            cardItem("x", order: 1, status: "failed", agents: asyncEntry("failed")),
            cardItem("y", order: 2, agents: asyncEntry())])
        #expect(failed.hasFailure && failed.accessibilityText.hasSuffix("，失败"))
    }

    @Test func startingIsNotAFailure() throws {
        let parsed = try card(try cardItem(status: "done", agents: asyncEntry()))
        #expect(!parsed.phase.isFailure)
        // A fresh dispatch clears an older batch's failure like any other.
        let failed = try cardItem("old", order: 1, status: "failed",
                                  createdAt: "2026-10-05T10:00:00Z", endTime: millis("2026-10-05T10:05:00Z"))
        let fresh = try cardItem("new", order: 2, agents: asyncEntry(), createdAt: "2026-10-05T10:10:00Z")
        let state = SubAgentProgress.capsuleState([failed, fresh])
        #expect(state.isVisible && !state.hasFailure)
    }

    @Test func startingHidesTheFinalOutputSection() throws {
        // The panel shows 最终输出 only when `!phase.isActive`; a launching card
        // that already carries a summary (a folded early receipt) must not
        // pass that gate while the subagent is still launching.
        let launching = try card(try cardItem(status: "done", agents: asyncEntry(), summary: "EARLY DRAFT"))
        #expect(launching.phase.isActive && launching.summary == "EARLY DRAFT")
        // The same card once the entry reports a real state closes normally.
        let closed = try card(try cardItem(status: "done", agents: asyncEntry("completed"), summary: "FINAL"))
        #expect(!closed.phase.isActive)
    }

    @Test func unknownStatusStillPassesThrough() throws {
        // The launch signal never invents a phase for an unrecognized status:
        // 防御式透传 keeps the wire text verbatim.
        let custom = try card(try cardItem(status: "vendor_paused", agents: asyncEntry()))
        #expect(custom.phase == .unknown("vendor_paused") && custom.phase.word == "vendor_paused")
        // …and a launching card is not active, so it cannot hold the capsule.
        #expect(!custom.phase.isActive)
        // The item status is the passthrough source; the entry is the fallback.
        var value = try itemObject(id: "card", order: 1)
        value["type"] = "tool"
        value.removeValue(forKey: "status")
        value["content"] = ["kind": "agent_call", "agents": ["t1": ["status": "vendor_paused"]]]
        let fallback = try card(try decode(value))
        #expect(fallback.phase == .unknown("vendor_paused"))
    }

    // MARK: Capsule

    @Test func capsuleShowsTheTaskNameForOneAndTheCountForSeveral() throws {
        let first = try cardItem("a", order: 1, description: "排查系统资源")
        let second = try cardItem("b", order: 2, description: "排查进程")
        let single = SubAgentProgress.capsuleState([first])
        #expect(single.isVisible && single.runningCount == 1)
        #expect(single.title == "排查系统资源")
        #expect(single.latestRunningID == "a")
        let pair = SubAgentProgress.capsuleState([first, second])
        #expect(pair.title == "2 项任务进行中")
        // All-terminal cards leave no capsule.
        let done = SubAgentProgress.capsuleState([try cardItem("done", status: "done")])
        #expect(!done.isVisible && done.latestRunningID == nil)
        // The newest running card is the capsule's default chip in the flat panel.
        let mixed = SubAgentProgress.capsuleState([try cardItem("old", order: 1, status: "done"),
                                                   try cardItem("new", order: 2)])
        #expect(mixed.latestRunningID == "new" && mixed.runningCount == 1)
    }

    @Test func capsuleTurnsRedWhileAnySubAgentFailed() throws {
        let normal = SubAgentProgress.capsuleState(try [cardItem("a", order: 1), cardItem("b", order: 2, status: "done")])
        #expect(!normal.hasFailure)
        let failed = SubAgentProgress.capsuleState(try [cardItem("a", order: 1, status: "failed"), cardItem("b", order: 2)])
        #expect(failed.hasFailure && failed.isVisible)
        let interrupted = SubAgentProgress.capsuleState(try [cardItem("a", order: 1, status: "interrupted"), cardItem("b", order: 2)])
        #expect(interrupted.hasFailure)
        // Nested cards stay inside the parent's panel: they neither run the
        // capsule nor tint it.
        let nestedOnly = SubAgentProgress.capsuleState(try [cardItem("a", order: 1, status: "failed", parentItemId: "outer")])
        #expect(!nestedOnly.isVisible && !nestedOnly.hasFailure)
    }

    // MARK: Capsule failure scope (pp 2026-10-03, option A: newest batch only)

    @Test func capsuleClearsOlderFailuresOnceANewSubAgentIsDispatched() throws {
        let failed = try cardItem("old", order: 1, status: "failed",
                                  createdAt: "2026-10-03T10:00:00Z", endTime: millis("2026-10-03T10:05:00Z"))
        let fresh = try cardItem("new", order: 2, createdAt: "2026-10-03T10:10:00Z")
        let state = SubAgentProgress.capsuleState([failed, fresh])
        #expect(state.isVisible && !state.hasFailure)
    }

    @Test func capsuleStaysRedForAFreshBatchFailure() throws {
        let stale = try cardItem("stale", order: 1, status: "failed",
                                 createdAt: "2026-10-03T09:00:00Z", endTime: millis("2026-10-03T09:05:00Z"))
        let failed = try cardItem("failed", order: 2, status: "failed",
                                  createdAt: "2026-10-03T10:00:00Z", endTime: millis("2026-10-03T10:05:00Z"))
        let running = try cardItem("running", order: 3, createdAt: "2026-10-03T10:00:00Z")
        let state = SubAgentProgress.capsuleState([stale, failed, running])
        #expect(state.isVisible && state.hasFailure)
    }

    @Test func capsuleKeepsRedForAParallelFailureOfTheRunningBatch() throws {
        // Dispatched together: the failure ends while its sibling still runs
        // and nothing newer was dispatched, so the capsule stays red.
        let failed = try cardItem("failed", order: 1, status: "failed",
                                  createdAt: "2026-10-03T10:00:00Z", endTime: millis("2026-10-03T10:05:00Z"))
        let running = try cardItem("running", order: 2, createdAt: "2026-10-03T10:00:00Z")
        #expect(SubAgentProgress.capsuleState([failed, running]).hasFailure)
    }

    @Test func capsuleFailureWithoutTimingStaysRed() throws {
        // No parseable dispatch or end time anywhere: the failure must not be
        // silently swallowed just because the clock is missing.
        let failed = try cardItem("failed", order: 1, status: "failed", createdAt: "", updatedAt: "")
        let running = try cardItem("running", order: 2)
        #expect(SubAgentProgress.capsuleState([failed, running]).hasFailure)
    }

    // MARK: Formats

    @Test func tokenAndDurationFormatsFollowTheDesignRanges() {
        #expect(SubAgentUsageFormat.tokens(0) == "0")
        #expect(SubAgentUsageFormat.tokens(999) == "999")
        #expect(SubAgentUsageFormat.tokens(1_000) == "1k")
        #expect(SubAgentUsageFormat.tokens(31_200) == "31.2k")
        #expect(SubAgentUsageFormat.tokens(33_555) == "33.6k")
        #expect(SubAgentUsageFormat.tokens(999_999) == "1M")
        #expect(SubAgentUsageFormat.tokens(1_000_000) == "1M")
        #expect(SubAgentUsageFormat.tokens(1_200_000) == "1.2M")
        #expect(SubAgentUsageFormat.duration(milliseconds: 400) == "0.4s")
        #expect(SubAgentUsageFormat.duration(milliseconds: 4_858) == "4.9s")
        #expect(SubAgentUsageFormat.duration(milliseconds: 6_000) == "6s")
        #expect(SubAgentUsageFormat.duration(milliseconds: 60_000) == "1m")
        #expect(SubAgentUsageFormat.duration(milliseconds: 90_000) == "1.5m")
        #expect(SubAgentUsageFormat.duration(milliseconds: 120_000) == "2m")
    }

    @Test func statsLineDropsMissingAndZeroCounters() throws {
        let full = try card(try cardItem(usage: ["toolCalls": 7, "tokens": 33_555, "durationMs": 24_723]))
        #expect(SubAgentProgress.statsLine(for: full) == "7 个工具 · 24.7s · 33.6k")
        let bare = try card(try cardItem())
        #expect(SubAgentProgress.statsLine(for: bare) == "")
        let zeros = try card(try cardItem(usage: ["toolCalls": 0, "tokens": 0, "durationMs": 0]))
        #expect(SubAgentProgress.statsLine(for: zeros) == "")
        let closed = try card(try cardItem(status: "done", usage: ["toolCalls": 3]))
        #expect(SubAgentProgress.statsLine(for: closed) == "3 个工具")
    }

    @Test func statsLineCarriesTheMetricsOnly() throws {
        // The phase word moved into the status badge; the visible line keeps
        // no "用时" and no "tokens" suffix, and each counter keeps its place.
        let full = try card(try cardItem(usage: ["toolCalls": 12, "tokens": 31_200, "durationMs": 8_100]))
        let line = SubAgentProgress.statsLine(for: full)
        #expect(line == "12 个工具 · 8.1s · 31.2k")
        #expect(!line.contains("用时"))
        #expect(!line.contains("tokens"))
        #expect(!line.contains("运行中"))
        // One counter at a time still renders, and never with a leading separator.
        let toolsOnly = try card(try cardItem(usage: ["toolCalls": 12, "tokens": 0, "durationMs": 0]))
        #expect(SubAgentProgress.statsLine(for: toolsOnly) == "12 个工具")
        let timeOnly = try card(try cardItem(usage: ["toolCalls": 0, "tokens": 0, "durationMs": 8_100]))
        #expect(SubAgentProgress.statsLine(for: timeOnly) == "8.1s")
        let tokensOnly = try card(try cardItem(usage: ["toolCalls": 0, "tokens": 31_200, "durationMs": 0]))
        #expect(SubAgentProgress.statsLine(for: tokensOnly) == "31.2k")
    }

    @Test func statsAccessibilityLabelReadsAsOneSentence() throws {
        // The badge dot, the badge word and the metrics must not become three
        // separate stops: one label, phase first, unit words restored.
        let full = try card(try cardItem(usage: ["toolCalls": 7, "tokens": 33_555, "durationMs": 24_723]))
        #expect(SubAgentProgress.statsAccessibilityLabel(for: full) == "运行中，7 个工具，用时 24.7s，33.6k tokens")
        let bare = try card(try cardItem())
        #expect(SubAgentProgress.statsAccessibilityLabel(for: bare) == "运行中")
        let zeros = try card(try cardItem(usage: ["toolCalls": 0, "tokens": 0, "durationMs": 0]))
        #expect(SubAgentProgress.statsAccessibilityLabel(for: zeros) == "运行中")
        let closed = try card(try cardItem(status: "done", usage: ["toolCalls": 3]))
        #expect(SubAgentProgress.statsAccessibilityLabel(for: closed) == "已完成，3 个工具")
        // A failed card speaks its failure, whatever the counters say.
        let failed = try card(try cardItem(status: "failed"))
        #expect(SubAgentProgress.statsAccessibilityLabel(for: failed) == "失败")
    }

    // MARK: Panel data (flat, pp 2026-10-08: 不分回合)

    @Test func panelListsOnlyActiveCardsInDispatchOrder() throws {
        let finished = try cardItem("a", order: 1, status: "done", description: "First")
        let running = try cardItem("b", order: 2, description: "Second")
        let later = try cardItem("c", order: 3)
        let items = [later, finished, running]
        // The session list keeps every top-level card, in dispatch order…
        let all = SubAgentProgress.sessionCards(inWindow: items, activeCards: [])
        #expect(all.map(\.id) == ["a", "b", "c"])
        // …while the flat strip is the active subset: the finished card exits (退场).
        #expect(SubAgentProgress.activeCards(inWindow: items, activeCards: []).map(\.id) == ["b", "c"])
    }

    @Test func activeStripCountsALaunchingCardAndAgesOutTheTerminalOne() throws {
        // A subagent still launching (async receipt) is active, exactly like a
        // running one — otherwise the dispatch would never earn a chip.
        let finished = try cardItem("a", order: 1, status: "done")
        let launched = try cardItem("b", order: 2, agents: asyncEntry())
        #expect(SubAgentProgress.activeCards(inWindow: [finished, launched], activeCards: []).map(\.id) == ["b"])
        // All-terminal sessions leave an empty strip (the capsule is gone too).
        #expect(SubAgentProgress.activeCards(inWindow: [finished], activeCards: []).isEmpty)
        #expect(SubAgentProgress.sessionCards(inWindow: [finished], activeCards: []).map(\.id) == ["a"])
    }

    @Test func selectionPrefersTheRequestedCardThenTheNewest() throws {
        let a = try cardItem("a", order: 1)
        let b = try cardItem("b", order: 2)
        let cards = SubAgentProgress.sessionCards(inWindow: [b, a], activeCards: [])
        #expect(cards.map(\.id) == ["a", "b"])
        #expect(SubAgentProgress.resolveSelection(cards, requested: "a")?.id == "a")
        // A request naming a card the session no longer holds falls to the newest.
        #expect(SubAgentProgress.resolveSelection(cards, requested: "missing")?.id == "b")
        #expect(SubAgentProgress.resolveSelection(cards, requested: nil)?.id == "b")
        // Nothing to show: no selection.
        #expect(SubAgentProgress.resolveSelection([], requested: "a") == nil)
    }

    @Test func selectionKeepsACompletedCardThatTheUserIsReading() throws {
        // The user opened a timeline card that has since finished: the session
        // list still holds it, so the id resolves and the final output stays
        // readable while the chip strip has already dropped it.
        let done = try cardItem("a", order: 1, status: "done")
        let running = try cardItem("b", order: 2)
        let cards = SubAgentProgress.sessionCards(inWindow: [done, running], activeCards: [])
        #expect(SubAgentProgress.resolveSelection(cards, requested: "a")?.id == "a")
        #expect(SubAgentProgress.activeCards(inWindow: [done, running], activeCards: []).map(\.id) == ["b"])
    }

    @Test func capsuleOpensTheNewestRunningCard() throws {
        let old = try cardItem("old", order: 1)
        let fresh = try cardItem("fresh", order: 2)
        let state = SubAgentProgress.capsuleState([old, fresh])
        #expect(state.runningCount == 2)
        #expect(state.latestRunningID == "fresh")
    }

    @Test func childrenFollowTheParentItemIdConvention() throws {
        let parent = try cardItem("card", order: 1)
        let tool = try item("t1", status: "done", order: 2,
                            content: ["kind": "command", "command": "ls", "parentItemId": "card"])
        let thinking = try item("r1", type: "system", status: "done", order: 3,
                                content: ["kind": "reasoning", "text": "hmm", "parentItemId": "card"])
        let mainTool = try item("m1", status: "done", order: 4, content: ["kind": "command", "command": "pwd"])
        let items = [parent, tool, thinking, mainTool]
        #expect(SubAgentProgress.children(of: "card", in: items).map(\.id) == ["t1", "r1"])
        #expect(SubAgentProgress.children(of: "m1", in: items).isEmpty)
    }

    // MARK: Panel activity list (pp 2026-10-05: 穿插)

    /// The panel's body is one chronological list, not per-kind sections: the
    /// activity rows keep the connector's publication order — reasoning, tool,
    /// reasoning, text — and nothing re-groups or re-orders them.
    @Test func panelActivityRowsInterleaveInTimelineOrder() throws {
        let card = try cardItem("card", order: 1, status: "done")
        let firstThought = try item("r1", type: "system", status: "done", order: 2,
                                    content: ["kind": "reasoning", "text": "first thought", "parentItemId": "card"])
        let tool = try item("t1", status: "done", order: 3,
                            content: ["kind": "command", "command": "ls", "parentItemId": "card"])
        let secondThought = try item("r2", type: "reasoning", status: "done", order: 4,
                                     content: ["text": "second thought", "parentItemId": "card"])
        let reply = try item("m1", type: "message", status: "done", order: 5, role: "assistant",
                             content: ["text": "Step 1.", "parentItemId": "card"])
        let items = [card, firstThought, tool, secondThought, reply]
        #expect(SubAgentProgress.activityRows(of: "card", in: items).map(\.id)
            == ["r1", "t1", "r2", "m1"])
    }

    /// The panel applies the chat's own visibility gate, so rows the chat
    /// hides never enter the activity list: the empty reasoning dead row
    /// (2026-10-05) and a hidden status. Main-agent rows stay out entirely.
    @Test func panelActivityRowsDropWhatTheChatHides() throws {
        let card = try cardItem("card", order: 1, status: "done")
        let deadRow = try item("r-empty", type: "system", status: "done", order: 2,
                               content: ["kind": "reasoning", "text": "", "signature": "sig", "parentItemId": "card"])
        let hiddenTool = try item("t-hidden", status: "hidden", order: 3,
                                  content: ["kind": "command", "command": "ls", "parentItemId": "card"])
        let tool = try item("t1", status: "done", order: 4,
                            content: ["kind": "command", "command": "pwd", "parentItemId": "card"])
        let mainRow = try item("m-main", type: "message", status: "done", order: 5, role: "assistant",
                               content: ["text": "outside"])
        #expect(SubAgentProgress.activityRows(of: "card", in: [card, deadRow, hiddenTool, tool, mainRow]).map(\.id)
            == ["t1"])
    }

    /// The two empty cases: a card nothing was attributed to, and a card whose
    /// rows sit outside the loaded window (the panel's not-loaded notice —
    /// its own facts still render, but there is no activity to list).
    @Test func panelActivityRowsAreEmptyWithoutRowsOrBeforeTheCardLoads() throws {
        let parentCard = try cardItem("card", order: 1)
        #expect(SubAgentProgress.activityRows(of: "card", in: [parentCard]).isEmpty)
        let other = try cardItem("other", order: 1, status: "done")
        let otherTool = try item("t1", status: "done", order: 2,
                                 content: ["kind": "command", "command": "ls", "parentItemId": "other"])
        let items = [other, otherTool]
        #expect(!SubAgentProgress.isContentLoaded(try card(parentCard), in: items))
        #expect(SubAgentProgress.activityRows(of: "card", in: items).isEmpty)
    }

    // MARK: Main timeline filter (L2.1: keep only the dispatch card)

    @Test @MainActor func subagentRowsNeverEnterTheMainTimeline() throws {
        let tool = ChatTimelineRowModel(try item("t1", content: ["kind": "command", "command": "ls", "parentItemId": "card"]))
        let thinking = ChatTimelineRowModel(try item("r1", type: "system",
            content: ["kind": "reasoning", "text": "hmm", "parentItemId": "card"]))
        // The row projection still classifies them; only the main list drops them.
        #expect(tool.structure.groupKind == .agents("card"))
        #expect(thinking.structure.groupKind == .agents("card"))
        // Main-agent rows keep their existing groups.
        let mainTool = ChatTimelineRowModel(try item("m1", content: ["kind": "command", "command": "pwd"]))
        #expect(mainTool.structure.groupKind == .tools)
        #expect(TimelineGrouping.groups([tool, thinking], interactionTargets: []).isEmpty)
        // ...and they do not break the surrounding main-agent run: the rows that
        // stay keep the grouping they had before the filter.
        let second = ChatTimelineRowModel(try item("m2", order: 2, content: ["kind": "command", "command": "ls"]))
        let alone = TimelineGrouping.groups([mainTool, tool, thinking], interactionTargets: [])
        #expect(alone.map(\.kind) == [.single] && alone[0].rows.map(\.id) == ["m1"])
        let pair = TimelineGrouping.groups([mainTool, second, tool, thinking], interactionTargets: [])
        #expect(pair.map(\.kind) == [.tools] && pair[0].rows.map(\.id) == ["m1", "m2"])
    }

    @Test @MainActor func nestedAgentCallsStayOutAndKeepTheirCallCountTitle() throws {
        let first = ChatTimelineRowModel(try item("n1", content: ["kind": "agent_call", "parentItemId": "card"]))
        let second = ChatTimelineRowModel(try item("n2", content: ["kind": "agent_call", "parentItemId": "card"]))
        #expect(TimelineGrouping.groups([first, second], interactionTargets: []).isEmpty)
        // The `.agents` kind and its title stay on the model layer.
        let group = ChatTimelineGroup(kind: .agents("card"), rows: [first, second])
        #expect(group.title == "2 次 SubAgent 调用")
    }

    @Test @MainActor func theDispatchCardStaysInTheMainTimeline() throws {
        let card = ChatTimelineRowModel(try cardItem("card", order: 1))
        let child = ChatTimelineRowModel(try item("t1", order: 2,
            content: ["kind": "command", "command": "ls", "parentItemId": "card"]))
        // The card itself carries no parentItemId, so it keeps flowing into the
        // main tool run as an ordinary tool row.
        #expect(SubAgentProgress.parentItemID(card.value) == nil)
        // Alone it is a single-row group (the pre-existing lone-pending rule).
        let alone = TimelineGrouping.groups([card, child], interactionTargets: [])
        #expect(alone.count == 1 && alone[0].kind == .single)
        #expect(alone[0].rows.map(\.id) == ["card"])
        // Beside another main-agent tool it joins that run as before.
        let tool = ChatTimelineRowModel(try item("m1", order: 3, content: ["kind": "command", "command": "pwd"]))
        let joined = TimelineGrouping.groups([tool, card, child], interactionTargets: [])
        #expect(joined.map(\.kind) == [.tools] && joined[0].rows.map(\.id) == ["m1", "card"])
    }

    @Test @MainActor func anInteractionAnchorChildRowStaysVisibleAsItsOwnGroup() throws {
        let first = ChatTimelineRowModel(try item("m1", order: 1, content: ["kind": "command", "command": "ls"]))
        let second = ChatTimelineRowModel(try item("m2", order: 2, content: ["kind": "command", "command": "pwd"]))
        let card = ChatTimelineRowModel(try cardItem("card", order: 3))
        let anchor = ChatTimelineRowModel(try item("t1", order: 4,
            content: ["kind": "command", "command": "grep", "parentItemId": "card"]))
        let other = ChatTimelineRowModel(try item("t2", order: 5,
            content: ["kind": "command", "command": "cat", "parentItemId": "card"]))
        // Only the anchored child row survives, and it renders on its own so the
        // approval card can attach to it; the rest keeps the pre-filter grouping.
        let groups = TimelineGrouping.groups([first, second, card, anchor, other], interactionTargets: ["t1"])
        #expect(groups.count == 2)
        #expect(groups.map(\.kind) == [.tools, .single])
        #expect(groups[0].rows.map(\.id) == ["m1", "m2", "card"])
        #expect(groups.last?.rows.map(\.id) == ["t1"])
    }

    @Test @MainActor func theMainTimelineFilterLeavesThePanelAndCapsuleSourcesIntact() throws {
        let parent = try cardItem("card", order: 1)
        let tool = try item("t1", status: "done", order: 2,
                            content: ["kind": "command", "command": "ls", "parentItemId": "card"])
        let thinking = try item("r1", type: "system", status: "done", order: 3,
                                content: ["kind": "reasoning", "text": "hmm", "parentItemId": "card"])
        let items = [parent, tool, thinking]
        // Both consumers project the raw rows, never the grouped list.
        #expect(SubAgentProgress.topLevelCards(in: items).map(\.id) == ["card"])
        #expect(SubAgentProgress.children(of: "card", in: items).map(\.id) == ["t1", "r1"])
        let capsule = SubAgentProgress.capsuleState(items)
        #expect(capsule.isVisible && capsule.runningCount == 1 && capsule.latestRunningID == "card")
    }

    @Test @MainActor func subagentTextStaysOutOfTheTurnReply() throws {
        var user = try itemObject(id: "user", order: 1, text: "开工")
        user["type"] = "message"; user["role"] = "user"
        let question = ChatTimelineRowModel(try decode(user))
        let reply = ChatTimelineRowModel(try item("reply", type: "message", status: "done", order: 2,
                                                  content: ["text": "First"]))
        // The footer only exists once the turn's rows are all terminal.
        let card = ChatTimelineRowModel(try cardItem("card", order: 3, status: "done"))
        let step = ChatTimelineRowModel(try item("step", type: "message", status: "done", order: 4,
                                                 content: ["text": "Step 1.", "parentItemId": "card"]))
        let groups = TimelineGrouping.groups([question, reply, card, step], interactionTargets: [])
        let actions = TimelineTurnActions.build(groups: groups, suppressLatest: false)
        #expect(actions.count == 1)
        #expect(actions.values.first?.copyText == "First")
    }

    // MARK: Shared header subtitle

    @Test func headerSubtitleMatchesTheChatHeaderLine() throws {
        let meta: V2SessionMeta = try decode(try fixtureObject("snapshot")["session"] as! [String: Any])
        #expect(SessionHeaderSubtitle.text(metadata: meta, deviceName: "phone", fallbackRuntimeName: nil) == "Work · phone")
        #expect(SessionHeaderSubtitle.text(metadata: meta, deviceName: nil, fallbackRuntimeName: nil) == "Work · device")
        #expect(SessionHeaderSubtitle.text(metadata: nil, deviceName: "phone", fallbackRuntimeName: "Claude") == "Claude · phone")
        #expect(SessionHeaderSubtitle.text(metadata: nil, deviceName: nil, fallbackRuntimeName: nil)
            == String(localized: "Agent"))
    }
}

/// ios-subagent-capsule-glyph §2/§3/§7: the glyph's tool classification and
/// phase resolution (both pure), plus the capsule's single-card wiring.
@Suite struct SubAgentGlyphPhaseTests {
    private func item(_ id: String, type: String = "tool", status: String = "running", order: Int = 1,
                      content: [String: Any]) throws -> V2TimelineItem {
        var value = try itemObject(id: id, order: order)
        value["type"] = type; value["status"] = status; value["content"] = content
        return try decode(value)
    }

    private func cardItem(_ id: String = "card", order: Int = 1, status: String = "running",
                          agents: [String: Any]? = nil) throws -> V2TimelineItem {
        var content: [String: Any] = ["kind": "agent_call", "action": "invoke", "description": "排查服务状态"]
        if let agents { content["agents"] = agents }
        return try item(id, status: status, order: order, content: content)
    }

    // MARK: Classification (§2)

    @Test func toolClassMapsTheNameTable() {
        for name in ["Read", "Glob", "Grep", "WebFetch", "WebSearch", "NotebookRead",
                     "read", "glob", "grep", "web_search", "web_fetch", "list", "ls", "cat"] {
            #expect(SubAgentGlyphPhase.toolClass(name) == .scouting)
        }
        for name in ["Write", "Edit", "MultiEdit", "NotebookEdit", "str_replace_editor", "apply_patch",
                     "write", "edit", "create_file"] {
            #expect(SubAgentGlyphPhase.toolClass(name) == .writing)
        }
        // Everything neutral or unlisted is nil (宁缺勿假 — never guess).
        for name in ["Bash", "shell", "bash", "pwsh", "Agent", "Task", "SendMessage", "TodoWrite",
                     "AskUserQuestion", "mcp__tools__change_title", "CronList", "SomeVendorTool", ""] {
            #expect(SubAgentGlyphPhase.toolClass(name) == nil)
        }
    }

    @Test func toolClassIsCaseAndWhitespaceInsensitive() {
        #expect(SubAgentGlyphPhase.toolClass("read") == .scouting)
        #expect(SubAgentGlyphPhase.toolClass("READ") == .scouting)
        #expect(SubAgentGlyphPhase.toolClass("ReAd") == .scouting)
        #expect(SubAgentGlyphPhase.toolClass("  Read  ") == .scouting)
        #expect(SubAgentGlyphPhase.toolClass("WRITE") == .writing)
        #expect(SubAgentGlyphPhase.toolClass("  edit ") == .writing)
        // Case never turns a neutral into a class.
        #expect(SubAgentGlyphPhase.toolClass("Bash") == nil)
        #expect(SubAgentGlyphPhase.toolClass("bash") == nil)
        #expect(SubAgentGlyphPhase.toolClass("BASH") == nil)
    }

    // MARK: Resolution (§3.2, 连续 2 次同类才切 + 保持)

    @Test func resolveNeedsTwoAdjacentSameClassCalls() {
        #expect(SubAgentGlyphPhase.resolve(toolHistory: []) == nil)
        #expect(SubAgentGlyphPhase.resolve(toolHistory: ["Read"]) == nil)
        #expect(SubAgentGlyphPhase.resolve(toolHistory: ["Read", "Read"]) == .scouting)
        #expect(SubAgentGlyphPhase.resolve(toolHistory: ["Read", "Edit"]) == nil)
        // A single trailing flip is held: the newest run of ≥2 still wins.
        #expect(SubAgentGlyphPhase.resolve(toolHistory: ["Read", "Read", "Edit"]) == .scouting)
        #expect(SubAgentGlyphPhase.resolve(toolHistory: ["Read", "Edit", "Edit"]) == .writing)
        // Pure alternation has no stable phase.
        #expect(SubAgentGlyphPhase.resolve(toolHistory: ["Read", "Edit", "Read", "Edit"]) == nil)
        // A neutral neither classifies nor breaks a run.
        #expect(SubAgentGlyphPhase.resolve(toolHistory: ["Read", "Read", "Bash", "Read"]) == .scouting)
        // All-neutral / unknown history resolves to nothing.
        #expect(SubAgentGlyphPhase.resolve(toolHistory: ["Bash", "Bash"]) == nil)
        #expect(SubAgentGlyphPhase.resolve(toolHistory: ["mcp__x__y", "Unknown"]) == nil)
    }

    // MARK: Live phase for a card (§3.3)

    @Test func livePhaseReadsChildToolRowsInOrder() throws {
        let card = try cardItem("card", order: 1)
        let parsed = try #require(SubAgentProgress.card(card))
        // Children arrive unsorted in the array; orderSeq decides the history.
        let first = try item("t1", status: "done", order: 5,
                             content: ["kind": "command", "toolName": "Edit", "parentItemId": "card"])
        let second = try item("t2", status: "done", order: 6,
                             content: ["kind": "command", "name": "Edit", "parentItemId": "card"])
        #expect(SubAgentGlyphPhase.livePhase(for: parsed, in: [card, second, first]) == .writing)
        // With no child rows the lone lastToolName never forms a run.
        let lonely = try #require(SubAgentProgress.card(try cardItem("lonely", order: 2,
            agents: ["t1": ["status": "running", "lastToolName": "Read"]])))
        #expect(SubAgentGlyphPhase.livePhase(for: lonely, in: []) == nil)
    }

    // MARK: Capsule wiring (§3)

    @Test func capsuleGlyphPhaseIsSingleCardOnly() throws {
        let card = try cardItem("card", order: 1)
        let read1 = try item("r1", status: "done", order: 2,
                             content: ["kind": "command", "toolName": "Read", "parentItemId": "card"])
        let read2 = try item("r2", status: "done", order: 3,
                             content: ["kind": "command", "toolName": "Read", "parentItemId": "card"])
        let single = SubAgentProgress.capsuleState([card, read1, read2])
        #expect(single.runningCount == 1 && single.glyphPhase == .scouting)

        // Two running cards → nil, the icon auto-cycles.
        let second = try cardItem("second", order: 4)
        let pair = SubAgentProgress.capsuleState([card, read1, read2, second])
        #expect(pair.runningCount == 2 && pair.glyphPhase == nil)

        // A running card with no rows and no lastToolName → nil.
        let empty = try cardItem("empty", order: 5)
        #expect(SubAgentProgress.capsuleState([empty]).glyphPhase == nil)

        // A running card whose only history is a single lastToolName → nil (a
        // lone name never forms a run, so the glyph auto-cycles).
        let lone = try cardItem("lone", order: 6,
                                agents: ["t1": ["status": "running", "lastToolName": "Read"]])
        #expect(SubAgentProgress.capsuleState([lone]).glyphPhase == nil)
    }
}

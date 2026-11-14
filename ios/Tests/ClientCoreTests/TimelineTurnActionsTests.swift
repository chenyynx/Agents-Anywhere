import Testing
@testable import ClientCore

@Suite @MainActor struct TimelineTurnActionsTests {
    private func row(_ id: String, type: String = "message", role: String = "assistant", text: String = "", status: String = "done") throws -> ChatTimelineRowModel {
        var value = try itemObject(id: id, text: text)
        value["type"] = type; value["role"] = role; value["status"] = status
        return ChatTimelineRowModel(try decode(value))
    }

    @Test func oneFooterCopiesAllReplyFragmentsAndExcludesToolsAndReasoning() throws {
        let rows = try [row("user", role: "user", text: "Question"), row("first", text: "First"),
            row("tool", type: "tool", text: "secret output"), row("reasoning", type: "reasoning", text: "Thought"),
            row("second", text: "Second"), row("last-tool", type: "tool")]
        let groups = TimelineGrouping.groups(rows, interactionTargets: [])
        let actions = TimelineTurnActions.build(groups: groups, suppressLatest: false)
        #expect(actions.count == 1)
        #expect(actions["last-tool"]?.copyText == "First\n\nSecond")
        #expect(actions["first"] == nil && actions["second"] == nil)
    }

    /// A finished reply waits for its turn to end. The footer must not hop to
    /// the latest finished segment while the turn is still streaming
    /// (pp 2026-11-14). A turn that is no longer the latest still commits
    /// when the next user message starts it.
    @Test func aFinishedReplyWaitsForTheTurnEnd() throws {
        let finishedRows = try [row("user-1", role: "user"), row("reply-1", text: "Done"),
            row("user-2", role: "user"), row("reply-2", text: "Also done")]
        let running = TimelineTurnActions.build(
            groups: TimelineGrouping.groups(finishedRows, interactionTargets: []),
            suppressLatest: true)
        #expect(running.count == 1)
        #expect(running["reply-1"]?.copyText == "Done")
        #expect(running["reply-2"] == nil)
        let ended = TimelineTurnActions.build(
            groups: TimelineGrouping.groups(finishedRows, interactionTargets: []),
            suppressLatest: false)
        #expect(ended.count == 2)
        #expect(ended["reply-2"]?.copyText == "Also done")

        let streamingRows = try [row("user-3", role: "user"),
            row("reply-3", text: "Streaming", status: "running")]
        let streaming = TimelineTurnActions.build(
            groups: TimelineGrouping.groups(streamingRows, interactionTargets: []),
            suppressLatest: true)
        #expect(streaming.isEmpty)
    }

    @Test func visibleActiveItemsAndNonAssistantTextDoNotGainActions() throws {
        let running = TimelineGrouping.groups(try [row("reply", text: "Still streaming", status: "running")], interactionTargets: [])
        #expect(TimelineTurnActions.build(groups: running, suppressLatest: false).isEmpty)
        let other = TimelineGrouping.groups(try [row("system", role: "system", text: "Notice"), row("user", role: "user", text: "Question")], interactionTargets: [])
        #expect(TimelineTurnActions.build(groups: other, suppressLatest: false).isEmpty)
    }

    /// A divider row (the compaction boundary) is not a reply host. Hosting
    /// the footer on it made a 91 pt jump when the next step group arrived
    /// (device probe 2026-10-31 05:40: the divider fell 121 → 30).
    @Test func aTurnDividerNeverHostsTheFooter() throws {
        let rows = try [row("user", role: "user", text: "Question"),
                        row("reply", text: "Answer"),
                        row("compact", type: "marker", role: "system", text: "")]
        let groups = TimelineGrouping.groups(rows, interactionTargets: [])
        let actions = TimelineTurnActions.build(groups: groups, suppressLatest: false)
        #expect(actions["reply"]?.copyText == "Answer")
        #expect(actions["compact"] == nil)
    }

    /// The Code page's step groups draw no footer. Excluding them from
    /// hosting keeps the action on the last reply group, so a new step group
    /// cannot remove the footer from a visible row.
    @Test func aRendererExcludedGroupNeverHostsTheFooter() throws {
        let rows = try [row("user", role: "user", text: "Question"),
                        row("reply", text: "Answer"),
                        row("steps", type: "tool", text: "")]
        let groups = TimelineGrouping.groups(rows, interactionTargets: [])
        let actions = TimelineTurnActions.build(
            groups: groups, suppressLatest: false,
            footerHostEligible: { $0.id != "steps" })
        #expect(actions["reply"]?.copyText == "Answer")
        #expect(actions["steps"] == nil)
    }

    /// A tool call continues the same turn. The finished reply's footer must
    /// wait for the turn end instead of appearing on the reply mid-turn.
    @Test func aToolSegmentWaitsForTheTurnEnd() throws {
        let runningRows = try [row("user", role: "user", text: "Question"),
                               row("reply", text: "Answer"),
                               row("tool", type: "tool", status: "running")]
        let running = TimelineTurnActions.build(
            groups: TimelineGrouping.groups(runningRows, interactionTargets: []),
            suppressLatest: true, footerHostEligible: { $0.id != "tool" })
        #expect(running.isEmpty)
        // When the turn ends the footer lands on the final reply host.
        let finishedRows = try [row("user", role: "user", text: "Question"),
                                row("reply", text: "Answer"),
                                row("tool", type: "tool", status: "done")]
        let finished = TimelineTurnActions.build(
            groups: TimelineGrouping.groups(finishedRows, interactionTargets: []),
            suppressLatest: false, footerHostEligible: { $0.id != "tool" })
        #expect(finished["reply"]?.copyText == "Answer")
        #expect(finished["tool"] == nil)
    }

    /// A running tool inside the turn keeps the commit closed even when the
    /// runtime status briefly reads idle: the footer returns only after the
    /// turn really ends.
    @Test func aRunningToolKeepsTheFooterClosed() throws {
        let rows = try [row("user", role: "user", text: "Question"),
                        row("reply", text: "Answer"),
                        row("tool", type: "tool", status: "running")]
        let actions = TimelineTurnActions.build(
            groups: TimelineGrouping.groups(rows, interactionTargets: []),
            suppressLatest: false, footerHostEligible: { $0.id != "tool" })
        #expect(actions.isEmpty)
    }

    @Test func pendingUserMessageKeepsThePreviousReplyActionsThroughItsEcho() throws {
        let rows = try [row("user", role: "user"), row("reply", text: "Completed answer")]
        let before = TimelineGrouping.groups(rows, interactionTargets: [])
        let pending = TimelineTurnActions.build(groups: before, suppressLatest: true, hasPendingUserMessage: true)
        #expect(pending["reply"]?.copyText == "Completed answer")
        let echoed = TimelineGrouping.groups(rows + [try row("echo", role: "user")], interactionTargets: [])
        let after = TimelineTurnActions.build(groups: echoed, suppressLatest: true)
        #expect(after["reply"]?.copyText == pending["reply"]?.copyText)
    }
}

@Suite("Turn footer gate")
struct TurnFooterGateTests {
    @Test func aRestoredFinishedTurnStartsClosed() {
        var gate = TurnFooterGate()
        let open = gate.update(userKey: "u1", runtimeIsRunning: false, authoritativeTurnEnds: 0)
        #expect(!open)
    }

    @Test func aRestoredRunningTurnStartsOpen() {
        var gate = TurnFooterGate()
        let open = gate.update(userKey: "u1", runtimeIsRunning: true, authoritativeTurnEnds: 0)
        #expect(open)
    }

    @Test func aNewUserMessageOpensTheTurn() {
        var gate = TurnFooterGate()
        _ = gate.update(userKey: "u1", runtimeIsRunning: false, authoritativeTurnEnds: 1)
        let open = gate.update(userKey: "u2", runtimeIsRunning: false, authoritativeTurnEnds: 1)
        #expect(open)
    }

    @Test func anAuthoritativeEndClosesTheTurnAndStatusFlapsDoNotReopenIt() {
        var gate = TurnFooterGate()
        _ = gate.update(userKey: "u1", runtimeIsRunning: true, authoritativeTurnEnds: 0)
        // A running/idle flap with no authoritative end keeps the turn open.
        let flapWhileOpen = gate.update(userKey: "u1", runtimeIsRunning: false, authoritativeTurnEnds: 0)
        #expect(flapWhileOpen)
        let afterEnd = gate.update(userKey: "u1", runtimeIsRunning: false, authoritativeTurnEnds: 1)
        #expect(!afterEnd)
        // The status flapping back to running does not reopen the footer.
        let flapAfterEnd = gate.update(userKey: "u1", runtimeIsRunning: true, authoritativeTurnEnds: 1)
        #expect(!flapAfterEnd)
    }

    @Test func theNextTurnReopensAfterAClosedTurn() {
        var gate = TurnFooterGate()
        _ = gate.update(userKey: "u1", runtimeIsRunning: true, authoritativeTurnEnds: 0)
        _ = gate.update(userKey: "u1", runtimeIsRunning: false, authoritativeTurnEnds: 1)
        let reopened = gate.update(userKey: "u2", runtimeIsRunning: true, authoritativeTurnEnds: 1)
        #expect(reopened)
        let closedAgain = gate.update(userKey: "u2", runtimeIsRunning: false, authoritativeTurnEnds: 2)
        #expect(!closedAgain)
    }

    @Test func aNilUserKeyDoesNotStrandAFinishedTurn() {
        var gate = TurnFooterGate()
        let first = gate.update(userKey: nil, runtimeIsRunning: false, authoritativeTurnEnds: 0)
        #expect(!first)
        let afterUserArrives = gate.update(userKey: "u1", runtimeIsRunning: false, authoritativeTurnEnds: 0)
        #expect(!afterUserArrives)
    }
}

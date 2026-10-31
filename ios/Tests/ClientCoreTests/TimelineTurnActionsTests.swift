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

    /// A finished reply gets its footer before the runtime reports idle. The
    /// connector closes the message row on the message boundary; the CLI turn
    /// result lands later, and waiting for it made the footer appear one beat
    /// after the reply (device 2026-10-31 16:14: text final at t=390.74,
    /// footer at t=392.30). A still-streaming reply must not gain one.
    @Test func aFinishedReplyGetsItsFooterBeforeTheTurnReportsIdle() throws {
        let finishedRows = try [row("user-1", role: "user"), row("reply-1", text: "Done"),
            row("user-2", role: "user"), row("reply-2", text: "Also done")]
        let finished = TimelineTurnActions.build(
            groups: TimelineGrouping.groups(finishedRows, interactionTargets: []),
            suppressLatest: true)
        #expect(finished.count == 2)
        #expect(finished["reply-1"]?.copyText == "Done")
        #expect(finished["reply-2"]?.copyText == "Also done")
        #expect(TimelineTurnActions.build(groups: TimelineGrouping.groups(finishedRows,
            interactionTargets: []), suppressLatest: false).count == 2)

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
    /// stay while the tool segment runs, or that row loses ~30 pt mid-turn and
    /// the bottom-follow page jumps down (device 2026-10-31 14:25: the reply
    /// measured 164→134 and the offset moved -30 in the same apply).
    @Test func aToolSegmentKeepsTheFinishedReplysFooter() throws {
        let runningRows = try [row("user", role: "user", text: "Question"),
                               row("reply", text: "Answer"),
                               row("tool", type: "tool", status: "running")]
        let running = TimelineTurnActions.build(
            groups: TimelineGrouping.groups(runningRows, interactionTargets: []),
            suppressLatest: true, footerHostEligible: { $0.id != "tool" })
        #expect(running["reply"]?.copyText == "Answer")
        #expect(running["tool"] == nil)
        // When the turn ends the footer stays on the final reply host.
        let finishedRows = try [row("user", role: "user", text: "Question"),
                                row("reply", text: "Answer"),
                                row("tool", type: "tool", status: "done")]
        let finished = TimelineTurnActions.build(
            groups: TimelineGrouping.groups(finishedRows, interactionTargets: []),
            suppressLatest: false, footerHostEligible: { $0.id != "tool" })
        #expect(finished["reply"]?.copyText == "Answer")
    }

    /// The runtime status flaps between running and idle across tool steps.
    /// When the flap looks idle but the tool row is still active, the footer
    /// must stay on the finished reply instead of flickering away and back
    /// (device 2026-10-31 14:55: the same row measured 146↔176 every few
    /// seconds).
    @Test func aRunningToolKeepsTheFooterWhenTheTurnLooksIdle() throws {
        let rows = try [row("user", role: "user", text: "Question"),
                        row("reply", text: "Answer"),
                        row("tool", type: "tool", status: "running")]
        let actions = TimelineTurnActions.build(
            groups: TimelineGrouping.groups(rows, interactionTargets: []),
            suppressLatest: false, footerHostEligible: { $0.id != "tool" })
        #expect(actions["reply"]?.copyText == "Answer")
        #expect(actions["tool"] == nil)
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

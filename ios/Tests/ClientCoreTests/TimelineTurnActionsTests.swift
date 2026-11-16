import Testing
@testable import ClientCore

@Suite @MainActor struct TimelineTurnActionsTests {
    private func row(_ id: String, type: String = "message", role: String = "assistant", text: String = "", status: String = "done", turnId: String? = nil) throws -> ChatTimelineRowModel {
        var value = try itemObject(id: id, text: text)
        value["type"] = type; value["role"] = role; value["status"] = status
        if let turnId {
            var source = value["source"] as? [String: Any] ?? [:]
            source["turnId"] = turnId
            value["source"] = source
        }
        return ChatTimelineRowModel(try decode(value))
    }

    /// The connector's compaction separator: a `marker` row whose wire kind is
    /// `compact`. It owns its own group in both render profiles.
    private func compactRow(_ id: String, state: String, status: String, turnId: String) throws -> ChatTimelineRowModel {
        var value = try itemObject(id: id, text: "")
        value["type"] = "marker"; value["role"] = "system"; value["status"] = status
        value["content"] = ["kind": "compact", "state": state]
        var source = value["source"] as? [String: Any] ?? [:]
        source["turnId"] = turnId
        value["source"] = source
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

    /// A compaction is session maintenance, not the latest turn's work: while
    /// the connector's compact marker runs (status `running`, wire kind
    /// `compact`), the finished turn keeps its footer. Counting the marker as
    /// active turn content hid copy/share — and the 30 pt action bar with
    /// them — for the whole compaction (pp 2026-11-15).
    @Test func aRunningCompactMarkerDoesNotHideTheFinishedTurnsFooter() throws {
        var marker = try itemObject(id: "compact")
        marker["type"] = "marker"
        marker["role"] = "system"
        marker["status"] = "running"
        marker["content"] = ["kind": "compact", "state": "started"]
        let compact = ChatTimelineRowModel(try decode(marker))
        let rows = try [row("user", role: "user", text: "Question"),
                        row("reply", text: "Answer"), compact]
        let actions = TimelineTurnActions.build(
            groups: TimelineGrouping.groups(rows, interactionTargets: []),
            suppressLatest: false)
        #expect(actions["reply"]?.copyText == "Answer")
    }

    /// The turn that follows a compaction opens with no user bubble (the CLI
    /// resumes with a scheduled reader turn). Without a boundary the finished
    /// turn is re-absorbed into the new one: its active rows block the final
    /// commit and the footer flickers with every step (pp 2026-11-16: after
    /// 「已压缩对话」 the copy/share bar appeared, then vanished as the new
    /// turn streamed — content ±30 in `timeline.mover` at 09:29:53/59, b1270).
    /// The compact marker's own turn id differs from the finished turn's, and
    /// the rows that follow name a third turn: that change is the boundary.
    @Test func aTurnAfterACompactionKeepsTheFinishedTurnsFooter() throws {
        let rows = try [row("user", role: "user", text: "Question", turnId: "turn-1"),
                        row("reply", text: "Answer", turnId: "turn-1"),
                        compactRow("compact", state: "completed", status: "done", turnId: "turn-compact"),
                        row("resumed", text: "Working again", status: "running", turnId: "turn-2")]
        let actions = TimelineTurnActions.build(
            groups: TimelineGrouping.groups(rows, interactionTargets: []),
            suppressLatest: true, allowsTurnIdBoundary: true)
        #expect(actions["reply"]?.copyText == "Answer")
        #expect(actions["resumed"] == nil)
    }

    /// The same rows with the new turn settled: the finished turn keeps its
    /// own footer and the resumed turn gets its own, instead of both buckets
    /// collapsing into one action on the newest reply.
    @Test func aSettledTurnAfterACompactionGetsItsOwnFooter() throws {
        let rows = try [row("user", role: "user", text: "Question", turnId: "turn-1"),
                        row("reply", text: "Answer", turnId: "turn-1"),
                        compactRow("compact", state: "completed", status: "done", turnId: "turn-compact"),
                        row("resumed", text: "Working again", turnId: "turn-2")]
        let actions = TimelineTurnActions.build(
            groups: TimelineGrouping.groups(rows, interactionTargets: []),
            suppressLatest: false, allowsTurnIdBoundary: true)
        #expect(actions["reply"]?.copyText == "Answer")
        #expect(actions["resumed"]?.copyText == "Working again")
    }

    /// A wake-up turn that ends must not take the previous turn's footer with
    /// it. pp 2026-11-16 10:05:54 (b1278): the wake-up turn's own reply
    /// replaced the previous reply as the footer host, copy text included.
    @Test func aWakeUpTurnsReplyKeepsThePreviousTurnsFooter() throws {
        let rows = try [row("user", role: "user", text: "Question", turnId: "turn-1"),
                        row("previous", text: "Previous answer", turnId: "turn-1"),
                        row("woken", text: "Woken answer", turnId: "turn-2")]
        let actions = TimelineTurnActions.build(
            groups: TimelineGrouping.groups(rows, interactionTargets: []),
            suppressLatest: false, allowsTurnIdBoundary: true)
        #expect(actions["previous"]?.copyText == "Previous answer")
        #expect(actions["woken"]?.copyText == "Woken answer")
        // A user-opened turn does not split on the wire's ids (see below).
        let merged = TimelineTurnActions.build(
            groups: TimelineGrouping.groups(rows, interactionTargets: []),
            suppressLatest: false)
        #expect(merged["previous"] == nil)
        #expect(merged["woken"]?.copyText == "Previous answer\n\nWoken answer")
    }

    /// An automatic compaction inside the user's own running turn is not a
    /// boundary: every row before and after the marker names the same turn,
    /// so the footer stays suppressed until the turn really ends. Committing
    /// here would show copy/share mid-turn.
    @Test func anAutomaticCompactionInsideATurnIsNotAFooterBoundary() throws {
        let rows = try [row("user", role: "user", text: "Question", turnId: "turn-1"),
                        row("reply", text: "First part", turnId: "turn-1"),
                        compactRow("compact", state: "completed", status: "done", turnId: "turn-1"),
                        row("more", text: "Second part", status: "running", turnId: "turn-1")]
        for allowsBoundary in [true, false] {
            let actions = TimelineTurnActions.build(
                groups: TimelineGrouping.groups(rows, interactionTargets: []),
                suppressLatest: true, allowsTurnIdBoundary: allowsBoundary)
            #expect(actions.isEmpty)
        }
    }

    /// A mid-turn turn-id flap (queued sends re-key rows between two ids)
    /// must not commit a footer while the user's turn still runs: the adapter
    /// only allows the wire boundary when no user bubble opened the turn.
    @Test func aMidTurnIdFlapDoesNotCommitAFooter() throws {
        let rows = try [row("user", role: "user", text: "Question", turnId: "turn-1"),
                        row("reply", text: "First part", turnId: "turn-1"),
                        row("tool", type: "tool", text: "", status: "done", turnId: "turn-1"),
                        row("more", text: "Second part", status: "running", turnId: "turn-2")]
        let actions = TimelineTurnActions.build(
            groups: TimelineGrouping.groups(rows, interactionTargets: []),
            suppressLatest: true, allowsTurnIdBoundary: false,
            footerHostEligible: { $0.id != "tool" })
        #expect(actions.isEmpty)
    }

    /// A background task completing wakes the runtime with no user bubble
    /// (connector `claude.scheduled.running`). While that episode runs the
    /// build suppresses the latest bucket, so the finished turn's footer must
    /// come from the closed state — otherwise copy/share disappears until the
    /// wake-up turn ends (pp 2026-11-16, `sess_iHSpxWxWtZWkXQ` 09:51:35 →
    /// 09:51:41).
    @Test func aWakeUpTurnWithoutAUserBubbleKeepsTheFinishedTurnsFooter() throws {
        let rows = try [row("user", role: "user", text: "Question", turnId: "turn-1"),
                        row("reply", text: "Answer", turnId: "turn-1")]
        let groups = TimelineGrouping.groups(rows, interactionTargets: [])
        // The turn is finished: the gate is closed and the footer commits.
        let closed = TimelineTurnActions.build(groups: groups, suppressLatest: false)
        #expect(closed["reply"]?.copyText == "Answer")
        // The wake-up turn runs without a user bubble.
        let duringWakeup = TimelineTurnActions.build(groups: groups, suppressLatest: true)
        #expect(duringWakeup.isEmpty)
        let restored = TimelineTurnActions.restoringFinishedFooters(
            duringWakeup, from: closed, groupIDs: ["user", "reply"])
        #expect(restored["reply"]?.copyText == "Answer")
    }

    /// Restoring never resurrects a footer for a group that left the window,
    /// and never overwrites an action the current build committed.
    @Test func restoringOnlyFillsGroupsThatStillExist() throws {
        let closed = TimelineTurnActions.build(
            groups: TimelineGrouping.groups(try [row("user", role: "user"), row("gone", text: "Old")],
                                            interactionTargets: []),
            suppressLatest: false)
        #expect(closed["gone"] != nil)
        let merged = TimelineTurnActions.restoringFinishedFooters(
            [:], from: closed, groupIDs: ["user"])
        #expect(merged.isEmpty)
        let kept = TimelineTurnActions.restoringFinishedFooters(
            [:], from: closed, groupIDs: ["user", "gone"])
        #expect(kept["gone"]?.copyText == "Old")
        // A group the current build already committed keeps its own action.
        let own = TimelineTurnActions.build(
            groups: TimelineGrouping.groups(try [row("user", role: "user"), row("gone", text: "New")],
                                            interactionTargets: []),
            suppressLatest: false)
        let untouched = TimelineTurnActions.restoringFinishedFooters(
            own, from: closed, groupIDs: ["user", "gone"])
        #expect(untouched["gone"]?.copyText == "New")
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

/// Which pending deliveries still open the new turn for the footer gate.
///
/// A `confirmed` record is retained by the presentation until its echo row
/// publishes (`SessionTimelinePresentation.synchronizePending`). Excluding it
/// from the turn-opening set made the previous turn's footer vanish for that
/// one refresh: the group lost its 30 pt action bar, the bottom clamped -30,
/// and the send's working-row follow started from the corrected offset —
/// the "jump then scroll" report (pp 2026-11-15).
@Suite @MainActor struct TurnOpeningDeliveryTests {
    @Test func aConfirmedPendingStillOpensTheTurnUntilItsEcho() {
        #expect(TimelineTurnActions.opensTurn(.sending))
        #expect(TimelineTurnActions.opensTurn(.accepted))
        #expect(TimelineTurnActions.opensTurn(.confirmed))
    }

    @Test func failedDeliveriesDoNotOpenTheTurn() {
        let failure = V2ClientFailure(kind: .transient, message: "boom")
        #expect(!TimelineTurnActions.opensTurn(.uncertain(failure)))
        #expect(!TimelineTurnActions.opensTurn(.rejected(failure)))
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

    @Test func anAuthoritativeEndClosesTheTurnAndAResumedTurnReopensIt() {
        var gate = TurnFooterGate()
        _ = gate.update(userKey: "u1", runtimeIsRunning: true, authoritativeTurnEnds: 0)
        // A running/idle flap with no authoritative end keeps the turn open.
        let flapWhileOpen = gate.update(userKey: "u1", runtimeIsRunning: false, authoritativeTurnEnds: 0)
        #expect(flapWhileOpen)
        let afterEnd = gate.update(userKey: "u1", runtimeIsRunning: false, authoritativeTurnEnds: 1)
        #expect(!afterEnd)
        // The runtime reports a turn in flight on the same user message: a
        // tool step resumed or the status was stale. Suppress again instead
        // of leaving the footer mid-turn (device 2026-11-14).
        let resumed = gate.update(userKey: "u1", runtimeIsRunning: true, authoritativeTurnEnds: 1)
        #expect(resumed)
    }

    @Test func aColdOpenMidTurnReopensWhenTheLiveStatusArrives() {
        var gate = TurnFooterGate()
        // The first refresh can precede the live runtime status; the app was
        // launched while a turn was already running (device 2026-11-14).
        let beforeStatus = gate.update(userKey: "u1", runtimeIsRunning: false, authoritativeTurnEnds: 0)
        #expect(!beforeStatus)
        let afterStatus = gate.update(userKey: "u1", runtimeIsRunning: true, authoritativeTurnEnds: 0)
        #expect(afterStatus)
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

    /// A command compaction opens a turn on the wire with no user bubble, so
    /// the runtime reports a turn in flight while the reply on screen is
    /// finished. The gate must not reopen on it (pp 2026-11-15: copy/share
    /// disappeared for the whole compaction).
    @Test func aCompactionDoesNotReopenAClosedTurn() {
        var gate = TurnFooterGate()
        _ = gate.update(userKey: "u1", runtimeIsRunning: true, authoritativeTurnEnds: 0)
        let closed = gate.update(userKey: "u1", runtimeIsRunning: false, authoritativeTurnEnds: 1)
        #expect(!closed)
        let duringCompaction = gate.update(userKey: "u1", runtimeIsRunning: true,
                                           authoritativeTurnEnds: 1, isCompacting: true)
        #expect(!duringCompaction)
    }

    /// The compact row settles before the runtime reports the turn's end, and
    /// that tail still belongs to the compaction. Reopening the gate on it
    /// hid the finished turn's footer until the runtime went idle (pp
    /// 2026-11-15 08:09:20.7 → 08:09:22.1, b1228: content 66602 → 66572 →
    /// 66602, i.e. the 30 pt action bar blinked out and back for 1.3 s).
    @Test func aCompactionTailDoesNotReopenAClosedTurn() {
        var gate = TurnFooterGate()
        _ = gate.update(userKey: "u1", runtimeIsRunning: true, authoritativeTurnEnds: 0)
        _ = gate.update(userKey: "u1", runtimeIsRunning: false, authoritativeTurnEnds: 1)
        let duringCompaction = gate.update(userKey: "u1", runtimeIsRunning: true,
                                           authoritativeTurnEnds: 1, isCompacting: true)
        #expect(!duringCompaction)
        // The marker row is finished on the wire; the runtime still runs.
        let settledRowStillRunning = gate.update(userKey: "u1", runtimeIsRunning: true,
                                                 authoritativeTurnEnds: 1, isCompacting: false)
        #expect(!settledRowStillRunning)
        // The turn ends; the footer must have stayed visible throughout.
        let idleAfterCompaction = gate.update(userKey: "u1", runtimeIsRunning: false,
                                              authoritativeTurnEnds: 1, isCompacting: false)
        #expect(!idleAfterCompaction)
        // A later user turn still opens and suppresses the new footer.
        let nextTurn = gate.update(userKey: "u2", runtimeIsRunning: true, authoritativeTurnEnds: 1)
        #expect(nextTurn)
    }

    /// A cold open during a compaction must not start suppressed and must not
    /// reopen on the compaction's tail either (same 30 pt blink as the
    /// in-session case).
    @Test func aColdOpenDuringACompactionStaysClosedThroughTheTail() {
        var gate = TurnFooterGate()
        let open = gate.update(userKey: "u1", runtimeIsRunning: true,
                               authoritativeTurnEnds: 0, isCompacting: true)
        #expect(!open)
        let settled = gate.update(userKey: "u1", runtimeIsRunning: true,
                                  authoritativeTurnEnds: 0, isCompacting: false)
        #expect(!settled)
        let idle = gate.update(userKey: "u1", runtimeIsRunning: false,
                               authoritativeTurnEnds: 1, isCompacting: false)
        #expect(!idle)
    }

    /// The compaction's own status can reopen the gate before its marker row
    /// reaches the client. Once the compaction is visible, a turn that no
    /// user bubble opened must close again, or the finished turn keeps its
    /// footer hidden for the whole compaction (pp 2026-11-15).
    @Test func aCompactionClosesATurnTheRuntimeStatusAloneReopened() {
        var gate = TurnFooterGate()
        _ = gate.update(userKey: "u1", runtimeIsRunning: true, authoritativeTurnEnds: 0)
        _ = gate.update(userKey: "u1", runtimeIsRunning: false, authoritativeTurnEnds: 1)
        let statusWindow = gate.update(userKey: "u1", runtimeIsRunning: true,
                                       authoritativeTurnEnds: 1)
        #expect(statusWindow)
        let compactionVisible = gate.update(userKey: "u1", runtimeIsRunning: true,
                                            authoritativeTurnEnds: 1, isCompacting: true)
        #expect(!compactionVisible)
    }

    /// A compaction inside the user's own running turn (automatic compaction
    /// mid-turn) must not reveal the footer early: the turn is still working.
    @Test func aCompactionLeavesAUserOpenedTurnOpen() {
        var gate = TurnFooterGate()
        _ = gate.update(userKey: "u0", runtimeIsRunning: false, authoritativeTurnEnds: 1)
        let userTurn = gate.update(userKey: "u1", runtimeIsRunning: true, authoritativeTurnEnds: 1)
        #expect(userTurn)
        let duringCompaction = gate.update(userKey: "u1", runtimeIsRunning: true,
                                           authoritativeTurnEnds: 1, isCompacting: true)
        #expect(duringCompaction)
    }

    /// A cold open during a compaction lands on a finished turn, not a
    /// running one: the footer must not start suppressed.
    @Test func aColdOpenDuringACompactionStartsClosed() {
        var gate = TurnFooterGate()
        let open = gate.update(userKey: "u1", runtimeIsRunning: true,
                               authoritativeTurnEnds: 0, isCompacting: true)
        #expect(!open)
    }

    /// A background-task notification wakes the runtime as a scheduled turn:
    /// the gate reopens without a user bubble, so the finished turn's footer
    /// must be restored from the closed state (pp 2026-11-16).
    @Test func aWakeUpTurnIsAUserlessEpisode() {
        var gate = TurnFooterGate()
        _ = gate.update(userKey: "u1", runtimeIsRunning: false, authoritativeTurnEnds: 0)
        #expect(!gate.isUserlessEpisode)
        #expect(!gate.isAnchoredToUserBubble)
        _ = gate.update(userKey: "u2", runtimeIsRunning: true, authoritativeTurnEnds: 0)
        #expect(!gate.isUserlessEpisode)
        #expect(gate.isAnchoredToUserBubble)
        _ = gate.update(userKey: "u2", runtimeIsRunning: false, authoritativeTurnEnds: 1)
        #expect(!gate.isUserlessEpisode)
        #expect(!gate.isAnchoredToUserBubble)
        let wakeup = gate.update(userKey: "u2", runtimeIsRunning: true, authoritativeTurnEnds: 1)
        #expect(wakeup)
        #expect(gate.isUserlessEpisode)
        #expect(!gate.isAnchoredToUserBubble)
    }

    @Test func aNilUserKeyDoesNotStrandAFinishedTurn() {
        var gate = TurnFooterGate()
        let first = gate.update(userKey: nil, runtimeIsRunning: false, authoritativeTurnEnds: 0)
        #expect(!first)
        let afterUserArrives = gate.update(userKey: "u1", runtimeIsRunning: false, authoritativeTurnEnds: 0)
        #expect(!afterUserArrives)
    }
}

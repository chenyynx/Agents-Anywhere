import Testing
@testable import ClientCore

@Suite @MainActor struct TimelineTurnActionsTests {
    private func row(_ id: String, type: String = "message", role: String = "assistant", text: String = "", status: String = "done", turnId: String? = nil, seq: Int = 10, parentItemID: String? = nil) throws -> ChatTimelineRowModel {
        var value = try itemObject(id: id, seq: seq, text: text)
        value["type"] = type; value["role"] = role; value["status"] = status
        if let parentItemID {
            value["content"] = ["text": text, "parentItemId": parentItemID]
        }
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

    /// The durable turn-end contract, independent of runtime-state freshness.
    @Test func latestTurnSealComparesTheBucketAndTheEndRecord() {
        #expect(TimelineTurnActions.latestTurnSeal(
            bucketTurnID: "turn-a", bucketMaxMainSeq: 10,
            latestTurnId: nil, latestTurnEndSeq: 0) == nil)
        #expect(TimelineTurnActions.latestTurnSeal(
            bucketTurnID: nil, bucketMaxMainSeq: 10,
            latestTurnId: "turn-a", latestTurnEndSeq: 10) == nil)
        #expect(TimelineTurnActions.latestTurnSeal(
            bucketTurnID: "turn-a", bucketMaxMainSeq: 10,
            latestTurnId: "turn-a", latestTurnEndSeq: 5) == true)
        #expect(TimelineTurnActions.latestTurnSeal(
            bucketTurnID: "turn-b", bucketMaxMainSeq: 10,
            latestTurnId: "turn-a", latestTurnEndSeq: 10) == true)
        #expect(TimelineTurnActions.latestTurnSeal(
            bucketTurnID: "turn-b", bucketMaxMainSeq: 11,
            latestTurnId: "turn-a", latestTurnEndSeq: 10) == false)
        // Offline cannot prove a newer turn is open; keep the last known
        // footer (the 2.2.0 offline rule) instead of suppressing it.
        #expect(TimelineTurnActions.latestTurnSeal(
            bucketTurnID: "turn-b", bucketMaxMainSeq: 11,
            latestTurnId: "turn-a", latestTurnEndSeq: 10,
            connectorOffline: true) == nil)
        // A runtime state that covers every main row and says idle is the
        // same proof from the other side: the ledger id is merely late, so
        // fall back to the state rule instead of withholding the footer
        // (pp 2026-11-24: 0.4–1.2 s of finished reply without its footer).
        #expect(TimelineTurnActions.latestTurnSeal(
            bucketTurnID: "turn-b", bucketMaxMainSeq: 11,
            latestTurnId: "turn-a", latestTurnEndSeq: 10,
            stateCoversMain: true) == nil)
        // Without that coverage the newer bucket is one the state never saw.
        #expect(TimelineTurnActions.latestTurnSeal(
            bucketTurnID: "turn-b", bucketMaxMainSeq: 11,
            latestTurnId: "turn-a", latestTurnEndSeq: 10,
            stateCoversMain: false) == false)
    }

    /// A matching id commits the latest bucket even when the runtime-state
    /// gate is closed; a newer turn with no end record stays suppressed even
    /// when the gate is open. No id on the rows keeps the old rule.
    @Test func aDeclaredTurnEndSealsOnlyTheMatchingOrOlderBucket() throws {
        let rows = try [
            row("u-a", role: "user", turnId: "turn-a", seq: 10),
            row("r-a", text: "A", turnId: "turn-a", seq: 11),
            row("u-b", role: "user", turnId: "turn-b", seq: 20),
            row("r-b", text: "B", turnId: "turn-b", seq: 21),
        ]
        let groups = TimelineGrouping.groups(rows, interactionTargets: [])

        let matched = TimelineTurnActions.build(
            groups: groups, suppressLatest: true,
            latestTurnId: "turn-b", latestTurnEndSeq: 15)
        #expect(matched["r-a"]?.copyText == "A")
        #expect(matched["r-b"]?.copyText == "B")

        let newer = TimelineTurnActions.build(
            groups: groups, suppressLatest: false,
            latestTurnId: "turn-a", latestTurnEndSeq: 15)
        #expect(newer["r-a"]?.copyText == "A")
        #expect(newer["r-b"] == nil)

        // Offline keeps the 2.2.0 behavior: a meta that lags the rows is not
        // proof that the newer turn is open, so the last known footer stays.
        let offline = TimelineTurnActions.build(
            groups: groups, suppressLatest: false,
            latestTurnId: "turn-a", latestTurnEndSeq: 15,
            connectorOffline: true)
        #expect(offline["r-b"]?.copyText == "B")

        // The latest bucket is older than the recorded end: history commits.
        let older = TimelineTurnActions.build(
            groups: groups, suppressLatest: true,
            latestTurnId: "turn-c", latestTurnEndSeq: 25)
        #expect(older["r-b"]?.copyText == "B")

        // No declared id anywhere: the runtime-state fallback is unchanged.
        let idlessRows = try [
            row("u-a", role: "user", seq: 10),
            row("r-a", text: "A", seq: 11),
            row("u-b", role: "user", seq: 20),
            row("r-b", text: "B", seq: 21),
        ]
        let fallback = TimelineTurnActions.build(
            groups: TimelineGrouping.groups(idlessRows, interactionTargets: []),
            suppressLatest: false, latestTurnId: "turn-b", latestTurnEndSeq: 15)
        #expect(fallback["r-b"]?.copyText == "B")
    }

    /// A covering idle state seals the newest bucket as soon as the turn
    /// ends; the ledger id is only needed when the state cannot cover the
    /// rows it is judging (pp 2026-11-24 23:52:52 → 23:52:53.65).
    @Test func aCoveringIdleStateSealsWithoutWaitingForTheLedgerId() throws {
        let rows = try [
            row("u-a", role: "user", turnId: "turn-a", seq: 10),
            row("r-a", text: "A", turnId: "turn-a", seq: 11),
            row("u-b", role: "user", turnId: "turn-b", seq: 20),
            row("r-b", text: "B", turnId: "turn-b", seq: 21),
        ]
        let groups = TimelineGrouping.groups(rows, interactionTargets: [])
        // The runtime already says idle and its `updatedSeq` covers the rows;
        // the session meta still names the previous turn (the Server records
        // the ledger behind its timeline fence).
        let covering = TimelineTurnActions.build(
            groups: groups, suppressLatest: false,
            latestTurnId: "turn-a", latestTurnEndSeq: 15,
            stateCoversMain: true)
        #expect(covering["r-b"]?.copyText == "B")
        // A state that predates the newest bucket cannot seal it: that is a
        // turn the state never saw, and the id must arrive first.
        let uncovered = TimelineTurnActions.build(
            groups: groups, suppressLatest: false,
            latestTurnId: "turn-a", latestTurnEndSeq: 15,
            stateCoversMain: false)
        #expect(uncovered["r-b"] == nil)
    }

    /// A scheduled/wake turn has no user bubble; its first assistant row still
    /// names the bucket, so a matching durable id seals it.
    @Test func aScheduledTurnSealsOnAMatchingIdWithoutAUserBubble() throws {
        let rows = try [row("wake-reply", text: "Wake", turnId: "turn-scheduled", seq: 30)]
        let actions = TimelineTurnActions.build(
            groups: TimelineGrouping.groups(rows, interactionTargets: []),
            suppressLatest: true,
            latestTurnId: "turn-scheduled", latestTurnEndSeq: 31)
        #expect(actions["wake-reply"]?.copyText == "Wake")
    }

    /// A running row still vetoes a matching id: the id says the turn ended,
    /// but visible activity means the client has not caught up yet.
    @Test func anActiveRowStillVetoesAMatchingTurnEnd() throws {
        let rows = try [
            row("u", role: "user", turnId: "turn-a", seq: 10),
            row("r", text: "A", turnId: "turn-a", seq: 11),
            row("tool", type: "tool", status: "running", turnId: "turn-a", seq: 12),
        ]
        let actions = TimelineTurnActions.build(
            groups: TimelineGrouping.groups(rows, interactionTargets: []),
            suppressLatest: true, latestTurnId: "turn-a", latestTurnEndSeq: 20,
            footerHostEligible: { $0.id != "tool" })
        #expect(actions.isEmpty)
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
            suppressLatest: true)
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
            suppressLatest: false)
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
            suppressLatest: false)
        #expect(actions["previous"]?.copyText == "Previous answer")
        #expect(actions["woken"]?.copyText == "Woken answer")
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
        for liveTurnGroupID in [nil, "user"] as [String?] {
            let actions = TimelineTurnActions.build(
                groups: TimelineGrouping.groups(rows, interactionTargets: []),
                suppressLatest: true, liveTurnGroupID: liveTurnGroupID)
            #expect(actions.isEmpty)
        }
    }

    /// A mid-turn turn-id flap (queued sends re-key rows between two ids)
    /// must not commit a footer while the user's turn still runs: the live
    /// user turn's bucket keeps the bubble-only split.
    @Test func aMidTurnIdFlapDoesNotCommitAFooter() throws {
        let rows = try [row("user", role: "user", text: "Question", turnId: "turn-1"),
                        row("reply", text: "First part", turnId: "turn-1"),
                        row("tool", type: "tool", text: "", status: "done", turnId: "turn-1"),
                        row("more", text: "Second part", status: "running", turnId: "turn-2")]
        let actions = TimelineTurnActions.build(
            groups: TimelineGrouping.groups(rows, interactionTargets: []),
            suppressLatest: true, liveTurnGroupID: "user",
            footerHostEligible: { $0.id != "tool" })
        #expect(actions.isEmpty)
    }

    /// Only the trailing bucket keeps the bubble-only split; history splits
    /// on the wire's ids even while the next user turn runs. Splitting only
    /// when the gate stood closed re-merged each finished user turn with the
    /// scheduled turn that followed it, so its copy/share bar vanished for
    /// the whole next turn and returned at its end — six bars toggled 94 ↔ 88
    /// with every send and turn end (pp 2026-11-16, b1279, the six hosts were
    /// exactly the user turns followed by a wake-up turn).
    @Test func historySplitsOnTheWireIdsWhileTheNextUserTurnRuns() throws {
        let rows = try [row("user-a", role: "user", text: "Question A", turnId: "turn-a"),
                        row("reply-a", text: "Answer A", turnId: "turn-a"),
                        row("wake", text: "Wake-up answer", turnId: "turn-wake"),
                        row("user-b", role: "user", text: "Question B", turnId: "turn-b"),
                        row("reply-b", text: "Streaming B", status: "running", turnId: "turn-b")]
        let actions = TimelineTurnActions.build(
            groups: TimelineGrouping.groups(rows, interactionTargets: []),
            suppressLatest: true, liveTurnGroupID: "user-b")
        #expect(actions["reply-a"]?.copyText == "Answer A")
        #expect(actions["wake"]?.copyText == "Wake-up answer")
        #expect(actions["reply-b"] == nil)
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

    /// pp 2026-11-18: a just-sent bubble has no row until its echo arrives,
    /// so the live id must resolve to nothing — parking it on the previous
    /// bubble merged the following turns and dropped their footers for 2.6 s
    /// (`timeline.turn.footer` hosts 30 → 29 → 30). No runtime status is
    /// consulted: `waiting` is also reported while a turn waits for an answer.
    @Test func theLiveGroupResolvesOnlyWhileItsOwnTurnIsTheLiveOne() throws {
        let settled = TimelineGrouping.groups(
            try [row("user", role: "user", text: "Question"),
                 row("reply", text: "Answer")],
            interactionTargets: [])
        let live = TimelineGrouping.groups(
            try [row("user", role: "user", text: "Question"),
                 row("reply", text: "Streaming", status: "running")],
            interactionTargets: [])
        #expect(TimelineTurnActions.resolveLiveTurnGroupID(
            isLiveUserTurn: true, hasUnEchoedPending: false,
            latestUserRowID: "user", groups: settled) == "user")
        // A settled turn owns no live group: the running status belongs to the
        // un-echoed new turn, which has no rows yet — protecting the old bubble
        // merged every turn after it (pp 2026-11-18: hosts 30 → 29 → 30).
        #expect(TimelineTurnActions.resolveLiveTurnGroupID(
            isLiveUserTurn: true, hasUnEchoedPending: true,
            latestUserRowID: "user", groups: settled) == nil)
        // A queued send riding a still-running turn keeps that turn's group
        // (pp 2026-11-14: the turn-id flap must not split it mid-turn).
        #expect(TimelineTurnActions.resolveLiveTurnGroupID(
            isLiveUserTurn: true, hasUnEchoedPending: true,
            latestUserRowID: "user", groups: live) == "user")
        #expect(TimelineTurnActions.resolveLiveTurnGroupID(
            isLiveUserTurn: false, hasUnEchoedPending: false,
            latestUserRowID: "user", groups: settled) == nil)
        #expect(TimelineTurnActions.resolveLiveTurnGroupID(
            isLiveUserTurn: true, hasUnEchoedPending: false,
            latestUserRowID: nil, groups: settled) == nil)
    }

    /// The shape behind the 2026-11-18 flicker: the user's bubble, then two
    /// bubble-less turns (background-task wake-ups). With the live id parked
    /// on the old bubble, turn-id splitting is off and the earlier turn's
    /// footer disappears; the fixed wiring passes no live id while the send
    /// awaits its echo, and both footers survive.
    @Test func aStaleLiveGroupMergesTheFollowingTurnsAndDropsTheirFooters() throws {
        let rows = try [row("user", role: "user", text: "Question", turnId: "turn-1"),
                        row("first", text: "First answer", turnId: "turn-2"),
                        row("second", text: "Second answer", turnId: "turn-3")]
        let groups = TimelineGrouping.groups(rows, interactionTargets: [])
        let stale = TimelineTurnActions.build(
            groups: groups, suppressLatest: true, hasPendingUserMessage: true,
            liveTurnGroupID: "user")
        #expect(stale["second"] != nil)
        #expect(stale["first"] == nil)
        let fixed = TimelineTurnActions.build(
            groups: groups, suppressLatest: true, hasPendingUserMessage: true,
            liveTurnGroupID: nil)
        #expect(fixed["first"] != nil)
        #expect(fixed["second"] != nil)
    }

    /// pp 2026-11-23 06:38: a background fork was still running when the user
    /// sent. The live group must not park on the previous user bubble for a
    /// row the footer build already ignores — doing so turned turn-id
    /// splitting off, merged the bubble-less turns after the bubble and
    /// blinked the earlier turn's footer (hosts 9 → 8 → 9; the send's bottom
    /// follow ran 30 pt short, then a second +30 follow landed with the
    /// echo).
    @Test func aRunningBackgroundCardDoesNotParkTheLiveGroupOnTheOldBubble() throws {
        let rows = try [row("user", role: "user", text: "Question", turnId: "t1"),
                        row("first", text: "First answer", turnId: "t1"),
                        row("wake", text: "Wake-up answer", turnId: "t2"),
                        toolRow("task",
                                content: ["kind": "agent_call", "action": "invoke",
                                          "runInBackground": true],
                                status: "running", turnId: "t3"),
                        row("second", text: "Second answer", turnId: "t3")]
        let groups = TimelineGrouping.groups(rows, interactionTargets: [])
        let resolved = TimelineTurnActions.resolveLiveTurnGroupID(
            isLiveUserTurn: true, hasUnEchoedPending: true,
            latestUserRowID: "user", groups: groups)
        #expect(resolved == nil)
        // With no parked live id the bubble-less turns keep their own footers
        // while the background card is still running.
        let actions = TimelineTurnActions.build(
            groups: groups, suppressLatest: false, hasPendingUserMessage: true,
            liveTurnGroupID: resolved)
        #expect(actions["first"] != nil)
        #expect(actions["wake"] != nil)
        #expect(actions["second"] != nil)

        // A foreground running tool still keeps the queued-send protection.
        let foreground = TimelineGrouping.groups(
            try [row("user", role: "user", text: "Question"),
                 toolRow("bash", content: ["kind": "command", "command": "ls"],
                         status: "running")],
            interactionTargets: [])
        #expect(TimelineTurnActions.resolveLiveTurnGroupID(
            isLiveUserTurn: true, hasUnEchoedPending: true,
            latestUserRowID: "user", groups: foreground) == "user")

        // The task-event shape (`agents[*].isBackgrounded`, the shape the real
        // fork card carried) is the same exemption.
        let flagged = TimelineGrouping.groups(
            try [row("user", role: "user", text: "Question"),
                 toolRow("task",
                         content: ["kind": "agent_call", "action": "invoke",
                                   "agents": ["agent-1": ["status": "running",
                                                          "isBackgrounded": true]]],
                         status: "running")],
            interactionTargets: [])
        #expect(TimelineTurnActions.resolveLiveTurnGroupID(
            isLiveUserTurn: true, hasUnEchoedPending: true,
            latestUserRowID: "user", groups: flagged) == nil)

        // A running compaction marker is maintenance, not the turn's activity.
        let compacting = TimelineGrouping.groups(
            try [row("user", role: "user", text: "Question"),
                 row("reply", text: "Answer"),
                 compactRow("compact", state: "started", status: "running",
                            turnId: "turn-compact")],
            interactionTargets: [])
        #expect(TimelineTurnActions.resolveLiveTurnGroupID(
            isLiveUserTurn: true, hasUnEchoedPending: true,
            latestUserRowID: "user", groups: compacting) == nil)
    }

    /// The `timeline.footer.gate` ids must be the resolution's own inputs:
    /// the grouping drops sub-agent child rows, so a probe scanning
    /// `timeline.rows` could name a row the resolution never sees. `ignored`
    /// names the exempt active row (the 2026-11-23 background fork) that
    /// `active` cannot show.
    @Test func footerProbeIDsFollowTheGroupingAndTheExemption() throws {
        var child = try itemObject(id: "child")
        child["type"] = "tool"; child["role"] = "assistant"; child["status"] = "running"
        child["content"] = ["kind": "command", "command": "ls", "parentItemId": "task"]
        let childRow = ChatTimelineRowModel(try decode(child))
        let rows = try [row("user", role: "user", text: "Question"),
                        toolRow("task",
                                content: ["kind": "agent_call", "action": "invoke",
                                          "runInBackground": true],
                                status: "running"),
                        childRow]
        let groups = TimelineGrouping.groups(rows, interactionTargets: [])
        #expect(!groups.contains { group in group.rows.contains { $0.id == "child" } })
        #expect(TimelineTurnActions.liveActivityRowIDs(
            groups: groups, latestUserRowID: "user").isEmpty)
        #expect(TimelineTurnActions.ignoredActivityRowIDs(
            groups: groups, latestUserRowID: "user") == ["task"])
    }

    /// A tool row with arbitrary content, for the background hand-off rows.
    private func toolRow(_ id: String, content: [String: Any],
                         status: String = "running", turnId: String? = nil) throws -> ChatTimelineRowModel {
        var value = try itemObject(id: id, text: "")
        value["type"] = "tool"; value["role"] = "assistant"; value["status"] = status
        value["content"] = content
        if let turnId {
            var source = value["source"] as? [String: Any] ?? [:]
            source["turnId"] = turnId
            value["source"] = source
        }
        return ChatTimelineRowModel(try decode(value))
    }

    /// pp 2026-11-18（真机确认后收窄）：后台派发**不拆回合**。一段引导正文 →
    /// 前台工具 → 后台子代理派发 → 回合的最后一条正文，仍然只是同一个回合：
    /// 页脚只出现在回合末的最后一条正文上，引导语不带。
    /// 真机 transcript：M1 正文 → Bash → Edit → Agent(bg) → M5 正文 → 用户
    /// 下一条消息（回合在 M5 后结束）。
    @Test func aBackgroundDispatchDoesNotSplitTheTurn() throws {
        let rows = try [row("user", role: "user", text: "Question", turnId: "t1"),
                        row("first", text: "First answer", turnId: "t1"),
                        toolRow("bash", content: ["kind": "command", "command": "ls"],
                                status: "done", turnId: "t1"),
                        toolRow("task",
                                content: ["kind": "agent_call", "action": "invoke",
                                          "runInBackground": true],
                                status: "running", turnId: "t1"),
                        row("second", text: "Second answer", turnId: "t1")]
        let actions = TimelineTurnActions.build(
            groups: TimelineGrouping.groups(rows, interactionTargets: []),
            suppressLatest: false)
        #expect(actions["first"] == nil)
        #expect(actions["second"]?.copyText == "First answer\n\nSecond answer")
        #expect(actions.count == 1)
    }

    /// 原问题（不等子代理）：回合结束时后台卡仍在 running，不能挡住这个
    /// 回合的页脚——后台派发行不计入活跃。
    @Test func aRunningBackgroundCardDoesNotSuppressTheTurnsFooter() throws {
        let rows = try [row("user", role: "user", text: "Question", turnId: "t1"),
                        row("first", text: "First answer", turnId: "t1"),
                        toolRow("task",
                                content: ["kind": "agent_call", "action": "invoke",
                                          "runInBackground": true],
                                status: "running", turnId: "t1")]
        let actions = TimelineTurnActions.build(
            groups: TimelineGrouping.groups(rows, interactionTargets: []),
            suppressLatest: false,
            // The adapter excludes the one-line step groups from hosting.
            footerHostEligible: { group in
                !group.rows.contains { $0.structure.type == .tool }
            })
        #expect(actions["first"]?.copyText == "First answer")
        #expect(actions.count == 1)
    }

    /// Claude 的任务事件把同一事实写在 `agents[*].isBackgrounded` 上：这种
    /// 线缆形状同样让后台卡不挡页脚。
    @Test func anEventFlaggedBackgroundAgentDoesNotSuppress() throws {
        let rows = try [row("user", role: "user", text: "Question", turnId: "t1"),
                        row("first", text: "First answer", turnId: "t1"),
                        toolRow("task",
                                content: ["kind": "agent_call", "action": "invoke",
                                          "agents": ["agent-1": ["status": "running",
                                                                 "isBackgrounded": true]]],
                                status: "running", turnId: "t1")]
        let actions = TimelineTurnActions.build(
            groups: TimelineGrouping.groups(rows, interactionTargets: []),
            suppressLatest: false,
            // The adapter excludes the one-line step groups from hosting.
            footerHostEligible: { group in
                !group.rows.contains { $0.structure.type == .tool }
            })
        #expect(actions["first"]?.copyText == "First answer")
        #expect(actions.count == 1)
    }

    /// A background subagent's child rows keep streaming after the main
    /// turn's idle state (pp 2026-11-24: four agents kept publishing child
    /// rows for the whole minute after the main reply). They belong to the
    /// child's own run and must not veto the state's coverage; counting them
    /// made every switch into such a session wait for a live read instead of
    /// sealing the finished turn immediately.
    @Test func aSubAgentChildRowNewerThanTheStateDoesNotBlockTheSeal() throws {
        let rows = try [timelineItem("user", seq: 100, type: "message", role: "user"),
                        timelineItem("reply", seq: 120, type: "message",
                                     role: "assistant", status: "done"),
                        timelineItem("child", seq: 900, type: "tool",
                                     role: "assistant", parent: "task")]
        let coverage = TimelineTurnActions.footerStateCoverage(rows: rows, stateSeq: 200)
        #expect(coverage.maxMainSeq == 120)
        #expect(coverage.maxAnySeq == 900)
        #expect(coverage.coversMainRows)
        #expect(TimelineTurnActions.footerRuntimeStateIsTrustworthy(
            stateExists: true, isFresh: false, connectorOffline: false,
            stateCoversRows: coverage.coversMainRows))
    }

    /// A main-agent row newer than the stale state is activity it never saw
    /// (the final reply can land after the idle frame): the seal keeps
    /// waiting, exactly as the 2026-11-23 rule requires. This is the guard in
    /// the other direction — it passes on the old all-rows rule too, so it
    /// proves "not too permissive", not that the main-row narrowing works.
    @Test func aMainRowNewerThanTheStateStillBlocksTheSeal() throws {
        let rows = try [timelineItem("user", seq: 100, type: "message", role: "user"),
                        timelineItem("reply", seq: 900, type: "message",
                                     role: "assistant", status: "done")]
        let coverage = TimelineTurnActions.footerStateCoverage(rows: rows, stateSeq: 200)
        #expect(coverage.maxMainSeq == 900)
        #expect(!coverage.coversMainRows)
        #expect(!TimelineTurnActions.footerRuntimeStateIsTrustworthy(
            stateExists: true, isFresh: false, connectorOffline: false,
            stateCoversRows: coverage.coversMainRows))
    }

    /// The card a background subagent reports into has no `parentItemId`, so
    /// it reads as a main row — but the connector republishes it on every
    /// child step (usage, last tool), long after the main turn ended. Counting
    /// it made every switch into a session with a live background agent look
    /// like "a row newer than the state" and pay the live-read wait again
    /// (pp 2026-11-24 07:12:54: stateSeq 1231196, card 1231198, footer at
    /// +1.23 s while the session was idle).
    @Test func aBackgroundAgentCardNewerThanTheStateDoesNotBlockTheSeal() throws {
        let rows = try [timelineItem("user", seq: 100, type: "message", role: "user", status: "done"),
                        timelineItem("reply", seq: 120, type: "message",
                                     role: "assistant", status: "done"),
                        timelineItem("task", seq: 900, type: "tool", role: "assistant",
                                     content: ["kind": "agent_call", "action": "invoke",
                                               "agents": ["agent-1": ["status": "running",
                                                                      "isBackgrounded": true]]])]
        let coverage = TimelineTurnActions.footerStateCoverage(rows: rows, stateSeq: 200)
        #expect(coverage.maxMainSeq == 120)
        #expect(coverage.maxBackgroundSeq == 900)
        #expect(coverage.maxAnySeq == 900)
        #expect(coverage.coversMainRows)
        #expect(TimelineTurnActions.footerRuntimeStateIsTrustworthy(
            stateExists: true, isFresh: false, connectorOffline: false,
            stateCoversRows: coverage.coversMainRows))
    }

    /// A card rebuilt from the transcript (or re-minted after a connector
    /// restart lost its task overlay) can arrive without `isBackgrounded`.
    /// The adapter's monotonic latch remembers the card and must keep it out
    /// of the coverage watermark too, not just out of activity.
    @Test func aLatchedBackgroundCardIsExcludedFromCoverageWithoutTheWireFlag() throws {
        let rows = try [timelineItem("user", seq: 100, type: "message", role: "user", status: "done"),
                        timelineItem("reply", seq: 120, type: "message",
                                     role: "assistant", status: "done"),
                        timelineItem("task", seq: 900, type: "tool", role: "assistant",
                                     content: ["kind": "agent_call", "action": "invoke",
                                               "agents": ["agent-1": ["status": "running"]]])]
        let coverage = TimelineTurnActions.footerStateCoverage(
            rows: rows, stateSeq: 200, latchedBackgroundIDs: ["task"])
        #expect(coverage.maxMainSeq == 120)
        #expect(coverage.maxBackgroundSeq == 900)
        #expect(coverage.coversMainRows)
    }

    /// The other direction: a **foreground** Agent call is ordinary main-agent
    /// work. A card newer than the stale state is activity it never saw, so
    /// the seal still waits — the exclusion is the background claim, not the
    /// card shape.
    @Test func aForegroundAgentCardNewerThanTheStateStillBlocksTheSeal() throws {
        let rows = try [timelineItem("user", seq: 100, type: "message", role: "user", status: "done"),
                        timelineItem("reply", seq: 120, type: "message",
                                     role: "assistant", status: "done"),
                        timelineItem("task", seq: 900, type: "tool", role: "assistant",
                                     content: ["kind": "agent_call", "action": "invoke",
                                               "agents": ["agent-1": ["status": "running"]]])]
        let coverage = TimelineTurnActions.footerStateCoverage(rows: rows, stateSeq: 200)
        #expect(coverage.maxMainSeq == 900)
        #expect(coverage.maxBackgroundSeq == 0)
        #expect(!coverage.coversMainRows)
    }

    /// Once a card proved it was a background dispatch, a later rebuild that
    /// drops the flag (a transcript re-projection, or a card re-minted after a
    /// connector restart lost its in-memory task overlay) must not turn the
    /// still-running card back into activity: the latch keeps the exemption
    /// and the finished turn keeps its footer (pp 2026-11-24: footer absent
    /// ~1 min with four background agents, back only when a later publication
    /// carried the flag again).
    @Test func aLatchedBackgroundCardStaysExemptAfterTheWireDropsTheFlag() throws {
        let rows = try [row("user", role: "user", text: "Question", turnId: "t1"),
                        row("first", text: "First answer", turnId: "t1"),
                        toolRow("task",
                                content: ["kind": "agent_call", "action": "invoke",
                                          "agents": ["agent-1": ["status": "running"]]],
                                status: "running", turnId: "t1")]
        let groups = TimelineGrouping.groups(rows, interactionTargets: [])
        let hostEligible: (ChatTimelineGroup) -> Bool = { group in
            !group.rows.contains { $0.structure.type == .tool }
        }
        // Without the latch the flagless card is activity and withholds the
        // footer.
        let unlatched = TimelineTurnActions.build(
            groups: groups, suppressLatest: false, footerHostEligible: hostEligible)
        #expect(unlatched.isEmpty)
        // The latch keeps the exemption after the flag disappears.
        let latched = TimelineTurnActions.build(
            groups: groups, suppressLatest: false,
            latchedBackgroundIDs: ["task"], footerHostEligible: hostEligible)
        #expect(latched["first"]?.copyText == "First answer")
        #expect(latched.count == 1)
        // The same latch feeds the live-group resolution and both probes; a
        // flagless running card otherwise parks the group on the old bubble
        // (2026-11-23 06:38) and reads as activity in diagnostics.
        #expect(TimelineTurnActions.resolveLiveTurnGroupID(
            isLiveUserTurn: true, hasUnEchoedPending: true,
            latestUserRowID: "user", groups: groups) == "user")
        #expect(TimelineTurnActions.resolveLiveTurnGroupID(
            isLiveUserTurn: true, hasUnEchoedPending: true,
            latestUserRowID: "user", groups: groups,
            latchedBackgroundIDs: ["task"]) == nil)
        #expect(TimelineTurnActions.liveActivityRowIDs(
            groups: groups, latestUserRowID: "user") == ["task"])
        #expect(TimelineTurnActions.liveActivityRowIDs(
            groups: groups, latestUserRowID: "user",
            latchedBackgroundIDs: ["task"]).isEmpty)
        #expect(TimelineTurnActions.ignoredActivityRowIDs(
            groups: groups, latestUserRowID: "user",
            latchedBackgroundIDs: ["task"]) == ["task"])
    }

    /// The latch fold the adapter runs each refresh: active rows that prove a
    /// background hand-off join it, rows that left the window are pruned, and
    /// a flagless running card does not join.
    @Test func theBackgroundLatchKeepsClaimsAndPrunesRowsThatLeftTheWindow() throws {
        let claiming = try timelineItem(
            "card", seq: 10, type: "tool", role: "assistant", status: "running",
            content: ["kind": "agent_call", "action": "invoke",
                      "agents": ["agent-1": ["status": "running",
                                             "isBackgrounded": true]]])
        let flagless = try timelineItem(
            "flagless", seq: 11, type: "tool", role: "assistant", status: "running",
            content: ["kind": "agent_call", "action": "invoke"])
        // A terminal card keeps its claim only while the row still exists; a
        // done row must not mint a new one either.
        let doneClaim = try timelineItem(
            "done-card", seq: 12, type: "tool", role: "assistant", status: "done",
            content: ["kind": "agent_call", "action": "invoke",
                      "agents": ["agent-2": ["status": "completed",
                                             "isBackgrounded": true]]])
        // `kept` is still in the window but its current revision lost the
        // flag: the old claim must survive (the keep branch). The first claim
        // has to come from the insert path, and `left-the-window` must be
        // pruned.
        let kept = try timelineItem(
            "kept", seq: 9, type: "tool", role: "assistant", status: "running",
            content: ["kind": "agent_call", "action": "invoke"])
        let latched = TimelineTurnActions.footerBackgroundLatch(
            existing: ["kept", "left-the-window"],
            rows: [claiming, flagless, doneClaim, kept])
        #expect(latched == ["card", "kept"])
    }

    /// The child-row exemption must not become "nothing blocks": a foreground
    /// Agent card (parent nil) keeps suppressing the finished turn's footer
    /// while it runs, even next to an active child interaction anchor, and it
    /// still parks the live group on a queued send.
    @Test func aForegroundAgentCardStillSuppressesNextToAnActiveChildAnchor() throws {
        let card = try toolRow("task",
                               content: ["kind": "agent_call", "action": "invoke"],
                               status: "running", turnId: "t1")
        var child = try itemObject(id: "question")
        child["type"] = "tool"; child["role"] = "assistant"; child["status"] = "waiting_approval"
        child["content"] = ["kind": "tool_call", "parentItemId": "task",
                            "title": "Approve?"]
        let anchor = ChatTimelineRowModel(try decode(child))
        let rows = try [row("user", role: "user", text: "Question", turnId: "t1"),
                        row("first", text: "First answer", turnId: "t1"),
                        card, anchor]
        let groups = TimelineGrouping.groups(rows, interactionTargets: ["question"])
        let actions = TimelineTurnActions.build(
            groups: groups, suppressLatest: false,
            footerHostEligible: { group in
                !group.rows.contains { $0.structure.type == .tool }
            })
        #expect(actions.isEmpty)
        #expect(TimelineTurnActions.resolveLiveTurnGroupID(
            isLiveUserTurn: true, hasUnEchoedPending: true,
            latestUserRowID: "user", groups: groups) == "user")
    }

    /// The grouping keeps exactly one kind of sub-agent child row on purpose:
    /// an interaction anchor (an approval/question card docks to it). It is
    /// the child's activity, not the main turn's — a pending card on a
    /// background subagent must not withhold the finished main turn's footer
    /// (review of the 2026-11-24 fix: this is the one child row `build` sees).
    @Test func aSubAgentChildInteractionAnchorDoesNotCountAsMainActivity() throws {
        var child = try itemObject(id: "question")
        child["type"] = "tool"; child["role"] = "assistant"; child["status"] = "waiting_approval"
        child["content"] = ["kind": "tool_call", "parentItemId": "task",
                            "title": "Approve?"]
        let anchor = ChatTimelineRowModel(try decode(child))
        let rows = try [row("user", role: "user", text: "Question", turnId: "t1"),
                        row("reply", text: "First answer", turnId: "t1"),
                        anchor]
        let groups = TimelineGrouping.groups(rows, interactionTargets: ["question"])
        #expect(groups.contains { group in group.rows.contains { $0.id == "question" } })
        #expect(TimelineTurnActions.liveActivityRowIDs(
            groups: groups, latestUserRowID: "user").isEmpty)
        #expect(TimelineTurnActions.ignoredActivityRowIDs(
            groups: groups, latestUserRowID: "user") == ["question"])
        // The anchor group is itself an eligible host, so the footer may land
        // on it; what matters is that the child row did not withhold it.
        let actions = TimelineTurnActions.build(groups: groups, suppressLatest: false)
        #expect(actions.count == 1)
        #expect(actions.values.first?.copyText == "First answer")
    }

    /// The diagnostics report names the row that withheld the footer, so a
    /// device log with `suppress=0` and no footer (the 2026-11-24 report had
    /// three such refreshes) is diagnosed in one line instead of guessed from
    /// row counts.
    @Test func theBuildReportNamesTheActiveRowThatWithheldTheFooter() throws {
        let rows = try [row("user", role: "user", text: "Question", turnId: "t1"),
                        row("first", text: "First answer", turnId: "t1"),
                        toolRow("task",
                                content: ["kind": "agent_call", "action": "invoke"],
                                status: "running", turnId: "t1")]
        var captured: TimelineTurnActions.FooterBuildReport?
        _ = TimelineTurnActions.build(
            groups: TimelineGrouping.groups(rows, interactionTargets: []),
            suppressLatest: false,
            footerHostEligible: { group in
                !group.rows.contains { $0.structure.type == .tool }
            },
            report: { captured = $0 })
        #expect(captured?.hasActiveItems == true)
        #expect(captured?.activeItemIDs == ["task"])
        #expect(captured?.endGroupID == "first")
        #expect(captured?.replyCount == 1)
        #expect(captured?.committed == false)
    }

    /// A bare timeline item for the coverage tests: `seq` is the item's
    /// `updatedSeq`, the number the runtime state is compared against.
    private func timelineItem(_ id: String, seq: Int, type: String, role: String,
                              status: String = "running",
                              parent: String? = nil,
                              content: [String: Any]? = nil) throws -> V2TimelineItem {
        var value = try itemObject(id: id, seq: seq, text: "")
        value["type"] = type; value["role"] = role; value["status"] = status
        var payload: [String: Any] = content ?? ["kind": "command", "command": "ls"]
        if let parent { payload["parentItemId"] = parent }
        value["content"] = payload
        return try decode(value)
    }

    /// 后台命令（runInBackground，比如监控）与后台子代理同等对待。
    @Test func aRunningBackgroundCommandDoesNotSuppressTheTurnsFooter() throws {
        let rows = try [row("user", role: "user", text: "Question", turnId: "t1"),
                        row("first", text: "First answer", turnId: "t1"),
                        toolRow("monitor", content: ["kind": "command", "runInBackground": true],
                                status: "running", turnId: "t1")]
        let actions = TimelineTurnActions.build(
            groups: TimelineGrouping.groups(rows, interactionTargets: []),
            suppressLatest: false,
            // The adapter excludes the one-line step groups from hosting.
            footerHostEligible: { group in
                !group.rows.contains { $0.structure.type == .tool }
            })
        #expect(actions["first"]?.copyText == "First answer")
        #expect(actions.count == 1)
    }

    /// 只有后台派发行豁免；同组的前台工具（连续工具行会合成一个步骤组）
    /// 仍在运行 → 回合页脚保持关闭，与 `aRunningToolKeepsTheFooterClosed`
    /// 一致。
    @Test func aRunningForegroundToolStillSuppressesNextToABackgroundCard() throws {
        let rows = try [row("user", role: "user", text: "Question", turnId: "t1"),
                        row("first", text: "First answer", turnId: "t1"),
                        toolRow("task",
                                content: ["kind": "agent_call", "action": "invoke",
                                          "runInBackground": true],
                                status: "done", turnId: "t1"),
                        toolRow("bash", content: ["kind": "command", "command": "ls"],
                                status: "running", turnId: "t1"),
                        row("second", text: "Second answer", turnId: "t1")]
        let actions = TimelineTurnActions.build(
            groups: TimelineGrouping.groups(rows, interactionTargets: []),
            suppressLatest: false)
        #expect(actions["second"] == nil)
    }

    /// 前台 Agent 调用（没有后台标志）就是普通工具步骤：运行中照常抑制回合
    /// 页脚，不按运行时写死判断。
    @Test func aRunningForegroundAgentSuppressesLikeAnyTool() throws {
        let rows = try [row("user", role: "user", text: "Question", turnId: "t1"),
                        row("first", text: "First answer", turnId: "t1"),
                        toolRow("agent", content: ["kind": "agent_call", "action": "invoke"],
                                status: "running", turnId: "t1")]
        let actions = TimelineTurnActions.build(
            groups: TimelineGrouping.groups(rows, interactionTargets: []),
            suppressLatest: false)
        #expect(actions.isEmpty)
    }

    /// 控制调用（send_input / wait / close / unknown）即使带着 runInBackground
    /// 也不是后台接走：它们只是对已有子代理的管理调用，永远按普通工具计活跃。
    @Test func aRunningControlCallCountsAsActivity() throws {
        for action in ["send_input", "wait", "close", "unknown"] {
            let rows = try [row("user", role: "user", text: "Question", turnId: "t1"),
                            row("first", text: "First answer", turnId: "t1"),
                            toolRow("ctl-\(action)",
                                    content: ["kind": "agent_call", "action": action,
                                              "runInBackground": true],
                                    status: "running", turnId: "t1")]
            let actions = TimelineTurnActions.build(
                groups: TimelineGrouping.groups(rows, interactionTargets: []),
                suppressLatest: false)
            #expect(actions.isEmpty)
        }
    }

    /// A foreground tool keeps the turn's single-footer rule: nothing commits
    /// while the turn is still open.
    @Test func aForegroundToolKeepsTheTurnOpen() throws {
        let rows = try [row("user", role: "user", text: "Question", turnId: "t1"),
                        row("first", text: "First answer", turnId: "t1"),
                        toolRow("bash", content: ["kind": "command", "command": "ls"],
                                status: "done", turnId: "t1")]
        let actions = TimelineTurnActions.build(
            groups: TimelineGrouping.groups(rows, interactionTargets: []),
            suppressLatest: true)
        #expect(actions.isEmpty)
    }

    /// An unknown runtime state is not "not running": a session view opens
    /// with cached rows before the live state arrives, and committing the
    /// latest bucket then stamps a streaming reply with a footer (pp
    /// 2026-11-23 22:04, build 1541).
    @Test func anUnknownRuntimeStateSuppressesTheLatestBucket() {
        #expect(TimelineTurnActions.suppressesLatest(
            latestTurnOpen: false, runtimeIsRunning: false,
            hasNewerItems: false, runtimeStateKnown: false))
        #expect(!TimelineTurnActions.suppressesLatest(
            latestTurnOpen: false, runtimeIsRunning: false,
            hasNewerItems: false, runtimeStateKnown: true))
        #expect(TimelineTurnActions.suppressesLatest(
            latestTurnOpen: true, runtimeIsRunning: true,
            hasNewerItems: false, runtimeStateKnown: true))
        #expect(TimelineTurnActions.suppressesLatest(
            latestTurnOpen: false, runtimeIsRunning: false,
            hasNewerItems: true, runtimeStateKnown: true))
    }

    /// Only a state read from the current live facts — or a stale state that
    /// was written after every cached row — may seal the latest turn: a stale
    /// idle can still show the previous turn, while a status newer than the
    /// rows proves nothing arrived behind it. Offline/failed has no live read
    /// to wait for, so the last known layout wins there.
    @Test func onlyFreshOrRowCoveringRuntimeStateCanSealTheLatestTurn() {
        #expect(TimelineTurnActions.footerRuntimeStateIsTrustworthy(
            stateExists: true, isFresh: true, connectorOffline: false,
            stateCoversRows: false))
        // A session switch with no activity after the state: no catch-up wait.
        #expect(TimelineTurnActions.footerRuntimeStateIsTrustworthy(
            stateExists: true, isFresh: false, connectorOffline: false,
            stateCoversRows: true))
        // A row newer than the state: wait for the live read.
        #expect(!TimelineTurnActions.footerRuntimeStateIsTrustworthy(
            stateExists: true, isFresh: false, connectorOffline: false,
            stateCoversRows: false))
        #expect(!TimelineTurnActions.footerRuntimeStateIsTrustworthy(
            stateExists: false, isFresh: true, connectorOffline: false,
            stateCoversRows: true))
        #expect(!TimelineTurnActions.footerRuntimeStateIsTrustworthy(
            stateExists: false, isFresh: false, connectorOffline: false,
            stateCoversRows: false))
        #expect(TimelineTurnActions.footerRuntimeStateIsTrustworthy(
            stateExists: false, isFresh: false, connectorOffline: true,
            stateCoversRows: false))
        #expect(TimelineTurnActions.footerRuntimeStateIsTrustworthy(
            stateExists: true, isFresh: false, connectorOffline: true,
            stateCoversRows: false))
    }

    /// A bubble-less next turn must not stay merged into a live user bucket
    /// when the durable fact proves the user turn ended. The ended turn's
    /// seal would otherwise land on the running turn's reply, and a later
    /// commit would copy both turns' text into one footer.
    @Test func aDurableBoundarySplitsAMergedLiveBucket() throws {
        let rows = try [
            row("u-a", role: "user", turnId: "turn-a", seq: 10),
            row("r-a", text: "A", turnId: "turn-a", seq: 11),
            row("r-b", text: "B", turnId: "turn-b", seq: 20),
        ]
        let groups = TimelineGrouping.groups(rows, interactionTargets: [])
        let liveGroup = groups[0].id

        let running = TimelineTurnActions.build(
            groups: groups, suppressLatest: true,
            liveTurnGroupID: liveGroup,
            latestTurnId: "turn-a", latestTurnEndSeq: 11)
        #expect(running["r-a"]?.copyText == "A")
        #expect(running["r-b"] == nil)

        let bothEnded = TimelineTurnActions.build(
            groups: groups, suppressLatest: true,
            liveTurnGroupID: liveGroup,
            latestTurnId: "turn-b", latestTurnEndSeq: 20)
        #expect(bothEnded["r-a"]?.copyText == "A")
        #expect(bothEnded["r-b"]?.copyText == "B")
    }

    /// An older page's trailing bucket is cut by the window, not by its turn
    /// end; the durable watermark cannot prove it complete. Keep 2.2.0's
    /// `hasNewerItems` suppression instead of sealing it.
    @Test func anOlderWindowDoesNotSealItsTruncatedBucket() throws {
        let rows = try [row("r-old", text: "Old", turnId: "turn-old", seq: 10)]
        let groups = TimelineGrouping.groups(rows, interactionTargets: [])
        let durable = TimelineTurnActions.build(
            groups: groups, suppressLatest: true,
            latestTurnId: "turn-new", latestTurnEndSeq: 100)
        #expect(durable["r-old"]?.copyText == "Old")

        let windowed = TimelineTurnActions.build(
            groups: groups, suppressLatest: true,
            latestTurnId: "turn-new", latestTurnEndSeq: 100,
            hasNewerItems: true)
        #expect(windowed.isEmpty)
    }

    /// The sequence watermark belongs to one bucket. A new user turn resets
    /// it; a high revision from the previous turn must not make the new
    /// bucket look newer than the recorded end.
    @Test func aNewBucketDoesNotInheritThePreviousWatermark() throws {
        let rows = try [
            row("u-a", role: "user", turnId: "turn-a", seq: 10),
            row("r-a", text: "A", turnId: "turn-a", seq: 100),
            row("u-b", role: "user", turnId: "turn-b", seq: 11),
            row("r-b", text: "B", turnId: "turn-b", seq: 20),
        ]
        let actions = TimelineTurnActions.build(
            groups: TimelineGrouping.groups(rows, interactionTargets: []),
            suppressLatest: true,
            latestTurnId: "turn-old", latestTurnEndSeq: 50)
        #expect(actions["r-a"]?.copyText == "A")
        #expect(actions["r-b"]?.copyText == "B")
    }

    /// Sub-agent child rows keep publishing after the main turn; counting
    /// their seq in the bucket watermark made every older bucket look newer
    /// than the recorded end.
    @Test func aSubAgentChildDoesNotRaiseTheBucketWatermark() throws {
        let rows = try [
            row("u-a", role: "user", turnId: "turn-a", seq: 10),
            row("r-a", text: "A", turnId: "turn-a", seq: 11),
            row("child", text: "child", turnId: "turn-a", seq: 100,
                parentItemID: "card"),
        ]
        let actions = TimelineTurnActions.build(
            groups: TimelineGrouping.fallbackGroups(rows, interactionTargets: []),
            suppressLatest: true,
            latestTurnId: "turn-old", latestTurnEndSeq: 50)
        #expect(actions.count == 1)
        #expect(actions.values.first?.copyText == "A")
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

    /// A steer echo can reach the timeline before the live steering row does:
    /// the turn-end history scan publishes it as an ordinary user prompt and
    /// a moment later the same item is corrected to `steeringUserMessage`.
    /// The newest user key then falls back to the previous bubble. That
    /// fallback is not a new turn — it is a userless episode, so the finished
    /// turn's footer is restored from the closed state instead of staying
    /// suppressed until the next turn ends (pp 2026-11-23, session
    /// `sess_RRBf0biiw2g6WQ`: footer hosts 15 → 14 → 16).
    @Test func aUserKeyThatFallsBackDoesNotReopenTheFinishedTurn() {
        var gate = TurnFooterGate()
        _ = gate.update(userKey: "u1", runtimeIsRunning: true,
                        authoritativeTurnEnds: 0, userKeyOrder: 10)
        _ = gate.update(userKey: "u1", runtimeIsRunning: false,
                        authoritativeTurnEnds: 1, userKeyOrder: 10)
        // The steer echo arrives first as a normal user row.
        let transient = gate.update(userKey: "steer", runtimeIsRunning: false,
                                    authoritativeTurnEnds: 1, userKeyOrder: 30)
        #expect(transient)
        // The same item is corrected to a steering row; the next turn runs.
        let corrected = gate.update(userKey: "u1", runtimeIsRunning: true,
                                    authoritativeTurnEnds: 1, userKeyOrder: 10)
        #expect(corrected)
        #expect(gate.isUserlessEpisode)
        // The userless episode ends with the next authoritative end.
        let afterNextEnd = gate.update(userKey: "u1", runtimeIsRunning: false,
                                       authoritativeTurnEnds: 2, userKeyOrder: 10)
        #expect(!afterNextEnd)
        #expect(!gate.isUserlessEpisode)
    }

    /// The same correction while the runtime is idle must not claim a turn is
    /// in flight — the finished footer stays committed.
    @Test func aUserKeyFallbackWhileIdleLeavesTheFinishedTurnClosed() {
        var gate = TurnFooterGate()
        _ = gate.update(userKey: "u1", runtimeIsRunning: false,
                        authoritativeTurnEnds: 1, userKeyOrder: 10)
        _ = gate.update(userKey: "steer", runtimeIsRunning: false,
                        authoritativeTurnEnds: 1, userKeyOrder: 30)
        let corrected = gate.update(userKey: "u1", runtimeIsRunning: false,
                                    authoritativeTurnEnds: 1, userKeyOrder: 10)
        #expect(!corrected)
    }

    /// A corrected steer episode is userless for the footer restore, but it
    /// is still a real user-initiated turn: an automatic compaction inside it
    /// must not close the gate and commit the streaming reply's footer early
    /// (the 30 pt flash `aCompactionLeavesAUserOpenedTurnOpen` rules out).
    @Test func aCorrectionKeepsACompactionFromRevealingTheFooterEarly() {
        var gate = TurnFooterGate()
        _ = gate.update(userKey: "u1", runtimeIsRunning: true,
                        authoritativeTurnEnds: 0, userKeyOrder: 10)
        _ = gate.update(userKey: "u1", runtimeIsRunning: false,
                        authoritativeTurnEnds: 1, userKeyOrder: 10)
        _ = gate.update(userKey: "steer", runtimeIsRunning: false,
                        authoritativeTurnEnds: 1, userKeyOrder: 30)
        let corrected = gate.update(userKey: "u1", runtimeIsRunning: true,
                                    authoritativeTurnEnds: 1, userKeyOrder: 10)
        #expect(corrected)
        let duringCompaction = gate.update(userKey: "u1", runtimeIsRunning: true,
                                           authoritativeTurnEnds: 1,
                                           isCompacting: true, userKeyOrder: 10)
        #expect(duringCompaction)
        let afterCompaction = gate.update(userKey: "u1", runtimeIsRunning: true,
                                          authoritativeTurnEnds: 1, userKeyOrder: 10)
        #expect(afterCompaction)
    }
}

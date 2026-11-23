import Foundation

struct TimelineTurnAction: Equatable {
    let replies: [ChatTimelineRowModel]
    var changes: [ChatTimelineRowModel] = []
    var startsMidTurn = false
    /// Joined on demand (copy/share), never during timeline body evaluation.
    var copyText: String {
        replies.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
    var hasReplyText: Bool { replies.contains { $0.text.contains { !$0.isWhitespace } } }

    /// When the turn finished, for the action row's clock. The reference used
    /// the moment the reply completed; a turn that never reported one falls
    /// back to the moment it started, and an unparseable wire value renders
    /// nothing rather than a wrong hour.
    var replyDate: Date? {
        let last = replies.last?.value
        return ChatTimestamp.replyDate(completedAt: last?.completedAt, createdAt: last?.createdAt)
    }

    /// Empty when the wire carried no usable timestamp, so the row collapses
    /// to icons instead of showing a placeholder.
    var timestampText: String {
        replyDate.map { ChatTimestamp.string($0) } ?? ""
    }
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.startsMidTurn == rhs.startsMidTurn && lhs.replies.elementsEqual(rhs.replies, by: ===)
            && lhs.changes.elementsEqual(rhs.changes, by: ===)
    }
}

/// Stable "the latest turn is still open" gate for the one-footer-per-turn
/// rule.
///
/// The runtime status is not a turn boundary: it flaps running/idle across
/// tool steps. A turn opens when a new user message (pending or echoed)
/// appears and closes only on an authoritative running→idle transition.
/// The footer waits for that close, so it never hops to each newly finished
/// reply segment while the turn is still streaming (pp 2026-11-14). A user
/// row that loses its turn-start role later (the steer echo's `user` →
/// `steeringUserMessage` correction) moves the key backwards and opens
/// nothing; the finished turn keeps its footer.
nonisolated struct TurnFooterGate: Equatable {
    private(set) var isOpen = false
    private var userKey: String?
    /// The timeline position of `userKey` when it is a visible user row.
    /// A key that moves backwards is not a new turn: it is the newest row
    /// losing its turn-start role (a steer echo published first as an
    /// ordinary user prompt and then corrected to `steeringUserMessage`). An
    /// outgoing pending record has no position (nil). A same-position key
    /// change is treated the same way; that relies on the live path never
    /// publishing one user message under two item ids at one position (the
    /// early-publish path fixes the id before the replay).
    private var userKeyOrder: Int?
    /// Whether the current userless episode is a corrected user row rather
    /// than a genuinely bubble-less turn (a compaction or a scheduled wake).
    /// The footer must still stay suppressed through an automatic compaction
    /// inside that turn: closing on the compaction committed a streaming
    /// reply's footer early, the 30 pt flash the compaction rule exists to
    /// prevent (`aCompactionLeavesAUserOpenedTurnOpen`).
    private var correctedFallback = false
    private var endsSeen = 0
    /// Whether the open state is anchored to a user bubble this client saw
    /// arrive, rather than to a runtime status alone. A compaction's command
    /// turn reports a turn in flight with no user bubble, so a gate that only
    /// a status reopened must close again once the compaction is visible;
    /// otherwise the finished turn loses its footer for the whole compaction
    /// (pp 2026-11-15: copy/share disappeared and the page jumped twice by
    /// the 30 pt action bar).
    private var openedByTurn = false
    /// Whether the running episode the gate closed on belongs to a compaction
    /// that no user bubble opened. The compact row settles before the runtime
    /// reports the turn's end, and that tail is still the compaction, not a
    /// resumed turn: a status that reopened the gate there hid the finished
    /// turn's footer until the runtime went idle (pp 2026-11-15 08:09:20.7 →
    /// 08:09:22.1: content 66602 → 66572 → 66602, the 30 pt action bar
    /// blinked for 1.3 s). Cleared when the episode ends or a user bubble
    /// opens the next turn.
    private var compactionEpisode = false

    init() {}

    /// A running turn that no user bubble opened: a compaction command turn,
    /// or the scheduled turn a background-task notification wakes (the
    /// connector logs both as `claude.scheduled.running`). The reply on
    /// screen is a *finished* turn, so its footer must survive the episode —
    /// the adapter keeps the closed state's footers for exactly this window
    /// (pp 2026-11-16: copy/share vanished each time a background CI monitor
    /// completed and woke the agent).
    var isUserlessEpisode: Bool { isOpen && !openedByTurn }

    /// Whether the current or last turn was anchored to a user bubble this
    /// client saw. `false` also covers the closed state, where a declared
    /// turn-id change is a history boundary: a scheduled turn in history
    /// needs a footer of its own exactly like a live one, and no running user
    /// turn exists whose mid-turn flap the boundary could disturb.
    var isAnchoredToUserBubble: Bool { openedByTurn }

    /// Whether the gate stands open on a user bubble this client saw — the
    /// turn on screen is the one still running. Only that trailing bucket
    /// keeps the bubble-only split; everything before it is finished history
    /// and must still split on the wire's turn ids.
    var isLiveUserTurn: Bool { isOpen && openedByTurn }

    /// Feeds one adapter refresh; returns whether the latest turn's footer
    /// must stay suppressed.
    ///
    /// `isCompacting` separates a compaction from the latest turn's work. The
    /// runtime reports a turn in flight while it compacts, but the reply on
    /// screen is finished; treating that as a resumed turn reopened a closed
    /// gate and hid the finished turn's footer — copy/share and the 30 pt
    /// action bar — for the whole compaction (pp 2026-11-15).
    mutating func update(userKey: String?, runtimeIsRunning: Bool,
                         authoritativeTurnEnds: Int, isCompacting: Bool = false,
                         userKeyOrder: Int? = nil) -> Bool {
        let turnIsRunning = runtimeIsRunning && !isCompacting
        if self.userKey == nil {
            // First refresh: a restored in-flight turn stays open; a restored
            // finished turn is already closed. A compaction in flight is
            // neither: the turn it follows is over. Nothing observable ties
            // this state to a user bubble, so only a bubble may later claim
            // it as a turn.
            self.userKey = userKey
            self.userKeyOrder = userKeyOrder
            isOpen = turnIsRunning
            openedByTurn = false
            compactionEpisode = isCompacting
            correctedFallback = false
            endsSeen = authoritativeTurnEnds
            return isOpen
        }
        if userKey != self.userKey {
            // A key that moves backwards is a correction, not a new turn: the
            // newest user row stopped starting a turn (the steer echo's
            // `user` → `steeringUserMessage` revision) and the fallback is
            // the previous bubble. Opening on it suppressed the finished
            // turn's footer until the next turn ended because the fallback
            // still counts as "anchored to a user bubble", keeping the
            // userless restore away (pp 2026-11-23: hosts 15 → 14 → 16).
            var regressed = false
            if let previousOrder = self.userKeyOrder, let nextOrder = userKeyOrder {
                regressed = nextOrder <= previousOrder
            }
            self.userKey = userKey
            self.userKeyOrder = userKeyOrder
            endsSeen = authoritativeTurnEnds
            if regressed {
                isOpen = turnIsRunning
                openedByTurn = false
                compactionEpisode = false
                correctedFallback = true
            } else {
                isOpen = true
                openedByTurn = true
                compactionEpisode = false
                correctedFallback = false
            }
            return isOpen
        }
        if authoritativeTurnEnds != endsSeen {
            endsSeen = authoritativeTurnEnds
            // An end seen while the runtime still reports a turn in flight is
            // a tool-step flap, not the turn's end.
            if !runtimeIsRunning {
                isOpen = false
                openedByTurn = false
                compactionEpisode = false
                correctedFallback = false
            }
        }
        if !runtimeIsRunning {
            // The running episode is over; a compaction's claim on it ends
            // here too. A later running status is a new turn and may reopen.
            compactionEpisode = false
        }
        if turnIsRunning, !compactionEpisode {
            // A cold open can initialize the gate before the live status
            // arrives (the app was launched mid-turn), and a tool step can
            // follow a transient idle. The turn is still in flight, so the
            // footer must stay suppressed on the same user message. The tail
            // of a compaction is the exception: the compact row has settled,
            // but the runtime still reports the compaction's own turn until
            // it ends, and the finished reply's footer must stay on screen.
            isOpen = true
        }
        // A compaction detected on a turn no user bubble opened: the running
        // episode belongs to the compaction, not to the latest turn. Closing
        // here also repairs a gate the compaction's own status reopened in
        // the window before its marker row reached the client.
        if isCompacting, !openedByTurn, !correctedFallback {
            isOpen = false
            compactionEpisode = true
        }
        return isOpen
    }
}

enum TimelineTurnActions {
    /// Whether `build` must withhold the latest turn's footer for one refresh.
    ///
    /// A session view can open with its cached rows before the live runtime
    /// state arrives (`state == nil`). The gate's first refresh cannot tell a
    /// finished turn from one in flight, so committing the latest bucket then
    /// stamps a streaming reply with a footer, and the running state's
    /// userless restore keeps that wrong footer for the whole turn
    /// (pp 2026-11-23 22:04, build 1541: gate started closed on `status=nil`,
    /// the streaming reply's host was committed at 22:04:10.204 — hosts
    /// 103→104 — and the running state restored it until the view reopened).
    /// Suppress until the state is known; a finished turn's footer appears one
    /// refresh later, when the state arrives.
    static func suppressesLatest(latestTurnOpen: Bool, runtimeIsRunning: Bool,
                                 hasNewerItems: Bool, runtimeStateKnown: Bool) -> Bool {
        (latestTurnOpen && runtimeIsRunning) || hasNewerItems || !runtimeStateKnown
    }

    /// Whether a footer refresh may trust the runtime state to seal the
    /// latest turn.
    ///
    /// A state that exists but was read before the current live facts landed
    /// (background, socket loss, recovery) is just as unable to seal a
    /// running turn as a missing one: it can show the previous turn's idle.
    /// `isFresh` is the model's own "current live facts are applied" gate
    /// (`V2SessionModel.update`), so a fresh state follows the same authority
    /// as authoritative turn ends. A stale state is still enough to seal when
    /// its `updatedSeq` covers every **main-agent** row (see
    /// `footerStateCoverage`; sub-agent child rows are excluded): the state was
    /// written after the newest visible row of the turn, so nothing of that
    /// turn arrived behind its back. That is the normal session-switch case
    /// and keeps the finished turn's footer immediate; only main rows newer
    /// than the state (a turn that started or streamed after it) force the
    /// 1–2 s wait for the live read. When the
    /// connector is offline or failed there is no live read to wait for; the
    /// last known layout wins as before, otherwise an offline session would
    /// never regain its newest footer.
    static func footerRuntimeStateIsTrustworthy(stateExists: Bool, isFresh: Bool,
                                                connectorOffline: Bool,
                                                stateCoversRows: Bool) -> Bool {
        connectorOffline || (stateExists && (isFresh || stateCoversRows))
    }

    /// The rows a runtime state's `updatedSeq` must cover before a stale read
    /// may seal the latest turn.
    ///
    /// Only main-agent rows can open, extend or end the turn whose footer is
    /// on screen. Sub-agent child rows (`content.parentItemId`) belong to the
    /// child's own run and keep streaming long after the main turn's idle
    /// state — counting them made every switch into a session with background
    /// subagents look like "a row newer than the state" and pay the live-read
    /// wait again (pp 2026-11-24: ~1.6 s, footer missing until the sync).
    /// `ed12dc9bb` added the coverage test to keep switches instant; this
    /// predicate narrows what it counts.
    /// A main row newer than the state is activity it never saw and still
    /// forces the wait.
    nonisolated struct FooterStateCoverage: Equatable {
        /// Newest `updatedSeq` among main-agent rows (0 when there is none).
        var maxMainSeq = 0
        /// Newest `updatedSeq` in the whole window, child rows included. The
        /// diagnostics pair this with `maxMainSeq` so a veto from a child row
        /// is visible instead of inferred.
        var maxAnySeq = 0
        var coversMainRows = true
    }

    static func footerStateCoverage<S: Sequence>(rows: S,
                                                 stateSeq: Int) -> FooterStateCoverage
    where S.Element == V2TimelineItem {
        var coverage = FooterStateCoverage()
        for item in rows {
            let seq = item.updatedSeq
            if seq > coverage.maxAnySeq { coverage.maxAnySeq = seq }
            guard SubAgentProgress.parentItemID(item) == nil else { continue }
            if seq > coverage.maxMainSeq { coverage.maxMainSeq = seq }
        }
        coverage.coversMainRows = coverage.maxMainSeq <= stateSeq
        return coverage
    }

    /// What the last bucket of one `build` pass saw. Diagnostics only: the
    /// adapter writes it when it changes so a withheld footer names its
    /// blocker (the active row, the host it would have used, the commit
    /// decision) instead of being reconstructed from row counts.
    nonisolated struct FooterBuildReport: Equatable {
        var endGroupID: String?
        var replyCount = 0
        var changeCount = 0
        var hasActiveItems = false
        /// Up to three rows that kept the final bucket from committing.
        var activeItemIDs: [String] = []
        var committed = false
    }

    /// Match Web's one-footer-per-turn rule. Tool results and reasoning can
    /// end a turn but never enter its copied reply.
    ///
    /// A turn commits one footer when the turn is over (`suppressLatest`
    /// false); it must not hop to each newly finished reply segment while the
    /// turn runs (pp 2026-11-14). The adapter's `TurnFooterGate` turns the
    /// volatile runtime status into a stable open/closed boundary, so a
    /// running/idle flap across tool steps cannot flicker the row.
    ///
    /// The footer host is the last group of the turn that actually draws one:
    /// divider groups (marker/system rows, e.g. a compaction boundary) and a
    /// caller-excluded renderer (the Code page's one-line step groups) never
    /// host it. Hosting it on a divider read as a 91 pt jump on device
    /// (2026-10-31 05:40: the compact boundary carried the review + copy
    /// footer, then lost it when the next step group arrived).
    /// - Parameter liveTurnGroupID: the group that opened the turn still in
    ///   flight, when a user bubble opened it. A declared turn-id change at
    ///   or after it is a queued-send flap, not a turn boundary, and must not
    ///   close the bucket mid-turn (pp 2026-11-14). Every bucket before it is
    ///   history and still splits on the declared turn id: a finished user
    ///   turn followed by a scheduled turn keeps its own footer, or it fell
    ///   into the next turn's bucket and six copy/share bars vanished and
    ///   returned with every send and turn end (pp 2026-11-16, b1279).
    ///
    /// One footer per turn, on its last hosting group (pp 2026-11-18). A
    /// background hand-off (subagent / `runInBackground` command) does not
    /// split the turn: the turn still ends when the assistant stops — the
    /// CLI does not hold it open for a background child — so the footer lands
    /// at the turn's real end without waiting for the child. The hand-off row
    /// only stops counting as activity (`isBackgroundHandoffRow`), so a
    /// still-running background card cannot suppress that footer either.
    static func build(groups: [ChatTimelineGroup], suppressLatest: Bool,
                      hasPendingUserMessage: Bool = false,
                      liveTurnGroupID: String? = nil,
                      latchedBackgroundIDs: Set<String> = [],
                      footerHostEligible: (ChatTimelineGroup) -> Bool = { _ in true },
                      report: ((FooterBuildReport) -> Void)? = nil)
        -> [String: TimelineTurnAction] {
        var actions: [String: TimelineTurnAction] = [:]
        var replies: [ChatTimelineRowModel] = []
        var changes: [ChatTimelineRowModel] = []
        var startsMidTurn = true
        var endGroupID: String?
        var turnOpen = false
        var hasActiveItems = false
        var activeItemIDs: [String] = []
        /// The declared turn id of the open bucket (its first naming row).
        /// Ordinary turns are still split by a user bubble; the wire's id
        /// only closes buckets that are no longer live.
        var bucketTurnID: V2TurnID?
        /// The live user turn's bucket keeps the bubble-only split once its
        /// opening group is reached; history before it splits as usual.
        var pastLiveTurnStart = false

        func hostsFooter(_ group: ChatTimelineGroup) -> Bool {
            guard footerHostEligible(group) else { return false }
            // A group with an assistant reply always hosts. Otherwise the
            // group must be real turn content: a turn-opening user bubble and
            // a divider group have no reply a footer can belong to.
            let hasReply = group.rows.contains { row in
                row.structure.type == .message && row.structure.role == .assistant
                    && SubAgentProgress.parentItemID(row.value) == nil
            }
            if hasReply { return true }
            return group.rows.contains { row in
                !row.structure.startsTurn
                    && row.structure.type != .marker
                    && row.structure.type != .system
            }
        }

        func commit() -> Bool {
            var wrote = false
            if let endGroupID, (!replies.isEmpty || !changes.isEmpty), !hasActiveItems {
                actions[endGroupID] = TimelineTurnAction(replies: replies, changes: changes, startsMidTurn: startsMidTurn)
                wrote = true
            }
            replies = []; changes = []; endGroupID = nil
            turnOpen = false; hasActiveItems = false
            bucketTurnID = nil
            activeItemIDs.removeAll()
            return wrote
        }

        for group in groups {
            if group.id == liveTurnGroupID { pastLiveTurnStart = true }
            if group.rows.contains(where: { $0.structure.startsTurn }) {
                _ = commit()
                turnOpen = true
                startsMidTurn = false
            }
            let declaredTurnID = group.rows.lazy.compactMap { $0.value.turnId }.first
            if !pastLiveTurnStart, let declaredTurnID, let currentTurnID = bucketTurnID,
               declaredTurnID != currentTurnID {
                // A turn that begins with no user bubble — a compaction
                // continuation, or the scheduled turn a background-task
                // notification wakes — is otherwise re-absorbed into the
                // previous bucket: the finished turn loses its footer and its
                // reply text joins the next turn's copy. Compaction made the
                // bar blink 30 pt in and out (pp 2026-11-16 09:29); a wake-up
                // turn moved the footer from the previous reply to its own
                // (same day 10:05:54: host msg_577ba3bc → msg_1e1de664, count
                // unchanged at 76). The declared turn-id change is the
                // boundary those turns have instead of a bubble.
                _ = commit()
            }
            // L2: a SubAgent's intermediate text rows belong to its card, not
            // to the main agent's reply — the copied turn text stays the main
            // conversation (they can still place the footer via the group).
            let messages = group.rows.filter {
                $0.structure.type == .message && $0.structure.role == .assistant
                    && SubAgentProgress.parentItemID($0.value) == nil
            }
            let fileChanges = group.rows.filter { $0.structure.isFileChange }
            if !messages.isEmpty || !fileChanges.isEmpty { turnOpen = true }
            guard turnOpen else { continue }
            if bucketTurnID == nil { bucketTurnID = declaredTurnID }
            if hostsFooter(group) { endGroupID = group.id }
            replies.append(contentsOf: messages)
            changes.append(contentsOf: fileChanges)
            // A compaction marker is session maintenance, not turn content:
            // while it runs, the finished turn keeps its footer and the 30 pt
            // action bar with it (pp 2026-11-15: copy/share vanished for the
            // whole compaction and the page jumped twice).
            //
            // A background hand-off row never counts as activity: its card
            // stays `running` for the whole background run, exactly the wait
            // pp ruled out — a reply finished after the hand-off must get its
            // footer while the subagent is still working (pp 2026-11-18 需求
            // 2: 不等子代理). Foreground rows — including a foreground tool
            // that shares the same step group — still suppress
            // (`aRunningToolKeepsTheFooterClosed`). `latchedBackgroundIDs`
            // keeps that exemption once a card proved it was backgrounded:
            // the wire can rewrite the card without the flag, and a flapping
            // exemption withholds the finished turn's footer for as long as
            // the card runs (pp 2026-11-24: four background agents, footer
            // absent until a later rewrite restored the flag).
            var active = false
            for row in group.rows
            where isLiveActivityRow(row.value, latchedBackgroundIDs: latchedBackgroundIDs) {
                active = true
                if activeItemIDs.count < 3, !activeItemIDs.contains(row.id) {
                    activeItemIDs.append(row.id)
                }
            }
            hasActiveItems = hasActiveItems || active
        }
        // The pending user bubble already starts the next turn, even before its
        // echo enters groups. A runtime "waiting" event belongs to that new turn.
        let finalEndGroupID = endGroupID
        let finalReplyCount = replies.count
        let finalChangeCount = changes.count
        let finalHasActiveItems = hasActiveItems
        let finalActiveItemIDs = activeItemIDs
        var committed = false
        if (!suppressLatest || hasPendingUserMessage), !hasActiveItems {
            committed = commit()
        }
        report?(FooterBuildReport(endGroupID: finalEndGroupID,
                                  replyCount: finalReplyCount,
                                  changeCount: finalChangeCount,
                                  hasActiveItems: finalHasActiveItems,
                                  activeItemIDs: finalActiveItemIDs,
                                  committed: committed))
        return actions
    }

    /// Whether the live user turn already owns a group in the timeline.
    ///
    /// An outgoing bubble has no row until its echo lands, so its turn owns no
    /// group yet: parking `liveTurnGroupID` on an older user bubble disables
    /// turn-id splitting for every following turn, merges them into one
    /// bucket and drops their footers until the echo arrives (pp 2026-11-18:
    /// 2.6 s, `timeline.turn.footer` hosts 30 → 29 → 30).
    ///
    /// No runtime status is consulted on purpose: `waiting` is also reported
    /// while a turn waits for the reader to answer a question
    /// (`claude.ask_user_question`, codex `request_user_input`), so a status
    /// cannot tell the previous turn from the new one.
    ///
    /// "Active" here is the build's own predicate (`isLiveActivityRow`), not a
    /// bare `status.isActive`: a background hand-off card stays `running` for
    /// its whole background run and is deliberately not activity for the
    /// footer, so it must not park the live group on the previous bubble
    /// either. Counting it did exactly that when a background fork was still
    /// running at send time, and the parked id merged the bubble-less turns
    /// after the bubble until the echo landed (device 2026-11-23 06:38:
    /// `timeline.footer.gate` liveGroup=set, `timeline.turn.footer` hosts
    /// 9 → 8 → 9, the send's follow 30 pt short and a second +30 follow).
    ///
    /// The window spans every group after the bubble, not only the bubble's
    /// own turn bucket: a foreground running row from a later, bubble-less
    /// wake-up turn parks this group too (pre-existing; unchanged here).
    static func resolveLiveTurnGroupID(isLiveUserTurn: Bool,
                                       hasUnEchoedPending: Bool,
                                       latestUserRowID: String?,
                                       groups: [ChatTimelineGroup],
                                       latchedBackgroundIDs: Set<String> = []) -> String? {
        guard isLiveUserTurn, let latestUserRowID else { return nil }
        guard let bubbleIndex = groups.lastIndex(where: { group in
            group.rows.contains { $0.id == latestUserRowID }
        }) else { return nil }
        guard hasUnEchoedPending else { return groups[bubbleIndex].id }
        // A queued send riding a still-running turn keeps that turn's group:
        // its turn-id flap must not split the bucket mid-turn (pp 2026-11-14).
        // A turn that already settled owns no live group — the running status
        // then belongs to the un-echoed new turn, which has no rows yet, and
        // protecting the old bubble would merge every turn after it.
        let liveRowsAfterBubble = groups[(bubbleIndex + 1)...].contains { group in
            group.rows.contains {
                isLiveActivityRow($0.value, latchedBackgroundIDs: latchedBackgroundIDs)
            }
        }
        return liveRowsAfterBubble ? groups[bubbleIndex].id : nil
    }

    /// The one "this row still marks work in flight" predicate.
    ///
    /// The footer build and the live-group resolution must agree, or a row one
    /// of them deliberately ignores still parks the live group on an older
    /// user bubble and turns turn-id splitting off for the trailing stretch.
    /// A background hand-off card, a sub-agent child row and a running
    /// compaction marker are not activity: the first keeps running after its
    /// turn's reply finished (pp 2026-11-18 需求 2: 不等子代理), the second is
    /// the child's own work (its card is the main row that reports it), the
    /// third is session maintenance (pp 2026-11-15: copy/share vanished for
    /// the whole compaction).
    ///
    /// `latchedBackgroundIDs` is the adapter's memory of cards that were once
    /// seen as background dispatches. The claim is not stable on the wire: a
    /// card rebuilt from the transcript (or one re-minted after a connector
    /// restart lost its in-memory task overlay) carries no
    /// `agents[*].isBackgrounded`, and the transcript's tool input may omit
    /// `runInBackground`; the exemption flipping back made a still-running
    /// card count as activity again (pp 2026-11-24: the finished turn's
    /// footer vanished for ~1 min with four background agents, returned only
    /// when a later publication carried the flag again). Membership is
    /// monotonic for the row's stay in the window.
    static func isLiveActivityRow(_ item: V2TimelineItem,
                                  latchedBackgroundIDs: Set<String> = []) -> Bool {
        // A sub-agent child row is the child's work, never the main turn's:
        // its card (parent nil) is the main row that says whether the turn is
        // still busy. The one child row the grouping keeps is an interaction
        // anchor (an approval/question card docked to it), and a pending card
        // on a background child must not withhold the finished main turn's
        // footer either.
        SubAgentProgress.parentItemID(item) == nil
            && item.status.isActive
            && !TimelineEntryPresentation.isCompactItem(item)
            && !(latchedBackgroundIDs.contains(item.id) || isBackgroundHandoffRow(item))
    }

    /// Fold one refresh into the adapter's background latch.
    ///
    /// Rows that are active and prove a background hand-off join the set;
    /// rows that left the window are pruned; everything else keeps its claim.
    /// Pure and exhaustively unit-tested because the adapter itself is outside
    /// the `ClientCore` target (`Package.swift` excludes `Views`), so the
    /// wiring would otherwise only be guarded by device runs.
    static func footerBackgroundLatch(existing: Set<String>,
                                      rows: some Sequence<V2TimelineItem>) -> Set<String> {
        var latched: Set<String> = []
        var present: Set<String>? = existing.isEmpty ? nil : []
        for item in rows {
            present?.insert(item.id)
            if item.status.isActive, isBackgroundHandoffRow(item) {
                latched.insert(item.id)
            }
        }
        if let present {
            latched.formUnion(existing.intersection(present))
        }
        return latched
    }

    /// The rows after the last visible user bubble that still count as live
    /// activity, in timeline order — the exact input `resolveLiveTurnGroupID`
    /// consults. The adapter's `timeline.footer.gate` probe reads this instead
    /// of scanning `timeline.rows`, which also holds sub-agent child rows the
    /// grouping drops: a probe id the resolution never sees reads as a
    /// contradiction (device 2026-11-23 06:38 window review).
    static func liveActivityRowIDs(groups: [ChatTimelineGroup],
                                   latestUserRowID: String?,
                                   latchedBackgroundIDs: Set<String> = [],
                                   limit: Int = 3) -> [String] {
        rowsAfterLastUserBubble(groups: groups, latestUserRowID: latestUserRowID)
            .filter { isLiveActivityRow($0.value, latchedBackgroundIDs: latchedBackgroundIDs) }
            .prefix(limit)
            .map(\.id)
    }

    /// The same window's rows that are `status.isActive` but deliberately not
    /// activity (a background hand-off card, a sub-agent child row, or a
    /// running compaction marker).
    /// They explain a window that shows running rows while `liveGroup`
    /// stays nil, and they name the card whose background flag a later wire
    /// rewrite can drop — invisible to `liveActivityRowIDs` by design, and
    /// exactly the row the adapter's latch must re-exempt.
    static func ignoredActivityRowIDs(groups: [ChatTimelineGroup],
                                      latestUserRowID: String?,
                                      latchedBackgroundIDs: Set<String> = [],
                                      limit: Int = 3) -> [String] {
        rowsAfterLastUserBubble(groups: groups, latestUserRowID: latestUserRowID)
            .filter {
                $0.value.status.isActive
                    && !isLiveActivityRow($0.value, latchedBackgroundIDs: latchedBackgroundIDs)
            }
            .prefix(limit)
            .map(\.id)
    }

    private static func rowsAfterLastUserBubble(groups: [ChatTimelineGroup],
                                                latestUserRowID: String?) -> [ChatTimelineRowModel] {
        guard let latestUserRowID,
              let bubbleIndex = groups.lastIndex(where: { group in
                  group.rows.contains { $0.id == latestUserRowID }
              })
        else { return [] }
        return groups[(bubbleIndex + 1)...].flatMap { $0.rows }
    }

    /// One row that hands the turn off to the background: a subagent dispatch
    /// that reports itself backgrounded, or a `runInBackground` command.
    ///
    /// The card stays `running` for the whole background run, so counting it
    /// as activity would suppress the turn's footer until the background
    /// returns — the wait pp ruled out (pp 2026-11-18: 回复完成了就带页脚，
    /// 不等子代理). The turn itself still ends when the assistant stops: the
    /// CLI does not hold a turn open for a background child (verified on this
    /// session's transcript: turn = M1 text → tools → background dispatch →
    /// final text → user's next message), so this exclusion is all the footer
    /// needs — a dispatch never splits the turn (pp 2026-11-18 第二版: 一个回合
    /// 只有最后一条正文带页脚，派发前的引导语不封口).
    ///
    /// Only a **background** hand-off counts, never a foreground one:
    /// - an Agent dispatch must report itself backgrounded
    ///   (`runInBackground` from Claude's tool input, or an
    ///   `agents[*].isBackgrounded` task event). A foreground Agent call is an
    ///   ordinary tool step and counts as activity like any other tool;
    /// - a control call on an agent that already exists is never a dispatch:
    ///   the wire's real action words are `send_input` / `wait` / `close`
    ///   (DSH projects `send_message`/`list_agents` this way, `list_agents`
    ///   degrading to `unknown`).
    ///
    /// `runInBackground` is written on Claude's rows. Codex's agent-call writer
    /// never sets it, and DSH's command content has no such field: a runtime
    /// that does not report the flag keeps the ordinary activity rule —
    /// capability-driven, no provider branching.
    /// Also the adapter's latch source: every row this returns true for while
    /// its claim is present is remembered for the rest of its window life, so
    /// a later rebuild that drops the flag cannot turn the running card back
    /// into activity (see `isLiveActivityRow`).
    static func isBackgroundHandoffRow(_ item: V2TimelineItem) -> Bool {
        if SubAgentProgress.isAgentCall(item) {
            return isDispatchAgentCall(item) && reportsBackground(item)
        }
        return item.raw["content"]?["runInBackground"]?.boolValue == true
    }

    /// Whether an Agent card reports that its dispatch runs in the background.
    /// Claude writes `runInBackground` from the tool input when the call is
    /// made and `agents[*].isBackgrounded` from its task events later; the
    /// same reading the card UI uses (`SubAgentProgress.card`). A runtime that
    /// reports neither leaves the card foreground.
    private static func reportsBackground(_ item: V2TimelineItem) -> Bool {
        let content = item.raw["content"]
        if content?["runInBackground"]?.boolValue == true { return true }
        return content?["agents"]?.objectValue?.values.contains {
            $0["isBackgrounded"]?.boolValue == true
        } ?? false
    }

    /// A subagent row that hands work off (dispatch), as opposed to a control
    /// call on an agent that already exists. Shared by the background
    /// hand-off rule and the step summary's present-tense phrase so both agree
    /// on what "an agent running" means.
    static func isDispatchAgentCall(_ item: V2TimelineItem) -> Bool {
        guard SubAgentProgress.isAgentCall(item) else { return false }
        switch item.raw["content"]?["action"]?.stringValue {
        case .some("invoke"), .some("spawn"), .some("resume"):
            return true
        default:
            return false
        }
    }

    /// Keep the footers a finished turn already had while the footer gate
    /// stood closed.
    ///
    /// A userless episode (see `TurnFooterGate.isUserlessEpisode`) reopens the
    /// gate and makes `build` suppress its final commit. The bucket on screen
    /// is the *finished* turn, so those suppressions take away a footer that
    /// was already correct: pp saw copy/share blink out every time a
    /// background task completed and the runtime received its wake-up message
    /// (2026-11-16, session `sess_iHSpxWxWtZWkXQ`: connector
    /// `claude.scheduled.running` 09:51:35 → idle 09:51:41).
    ///
    /// The closed state is the authoritative map of finished turns, so
    /// restoring it cannot reveal the open turn's own footer — `build` still
    /// withholds that until the turn ends. A group that left the window is
    /// dropped rather than restored.
    static func restoringFinishedFooters(
        _ current: [String: TimelineTurnAction],
        from closed: [String: TimelineTurnAction],
        groupIDs: Set<String>
    ) -> [String: TimelineTurnAction] {
        guard !closed.isEmpty else { return current }
        var merged = current
        for (groupID, action) in closed where merged[groupID] == nil && groupIDs.contains(groupID) {
            merged[groupID] = action
        }
        return merged
    }

    /// Whether a pending delivery still opens the new turn for the footer gate.
    ///
    /// `confirmed` records outlive the session model until their echo row is
    /// published (`SessionTimelinePresentation.synchronizePending`). Excluding
    /// them from the turn-opening set made the previous turn's footer vanish
    /// for that one refresh — the group lost its 30 pt action bar, the bottom
    /// clamped -30, and the working-row follow started from the corrected
    /// offset ("jump then scroll", pp 2026-11-15).
    static func opensTurn(_ delivery: V2PendingMessage.Delivery) -> Bool {
        switch delivery {
        case .sending, .accepted, .confirmed: return true
        case .uncertain, .rejected: return false
        }
    }
}

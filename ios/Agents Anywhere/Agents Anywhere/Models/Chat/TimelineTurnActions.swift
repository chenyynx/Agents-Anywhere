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
/// reply segment while the turn is still streaming (pp 2026-11-14).
nonisolated struct TurnFooterGate: Equatable {
    private(set) var isOpen = false
    private var userKey: String?
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
                         authoritativeTurnEnds: Int, isCompacting: Bool = false) -> Bool {
        let turnIsRunning = runtimeIsRunning && !isCompacting
        if self.userKey == nil {
            // First refresh: a restored in-flight turn stays open; a restored
            // finished turn is already closed. A compaction in flight is
            // neither: the turn it follows is over. Nothing observable ties
            // this state to a user bubble, so only a bubble may later claim
            // it as a turn.
            self.userKey = userKey
            isOpen = turnIsRunning
            openedByTurn = false
            compactionEpisode = isCompacting
            endsSeen = authoritativeTurnEnds
            return isOpen
        }
        if userKey != self.userKey {
            self.userKey = userKey
            isOpen = true
            openedByTurn = true
            compactionEpisode = false
            endsSeen = authoritativeTurnEnds
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
        if isCompacting, !openedByTurn {
            isOpen = false
            compactionEpisode = true
        }
        return isOpen
    }
}

enum TimelineTurnActions {
    /// Match Web's one-footer-per-turn rule. Tool results and reasoning can
    /// end a turn but never enter its copied reply.
    ///
    /// A turn with no background hand-off commits one footer when the turn is
    /// over (`suppressLatest` false); it must not hop to each newly finished
    /// reply segment while the turn runs (pp 2026-11-14). The adapter's
    /// `TurnFooterGate` turns the volatile runtime status into a stable
    /// open/closed boundary, so a running/idle flap across tool steps cannot
    /// flicker the row.
    ///
    /// A reply followed by a background hand-off (subagent / background
    /// command, see `isBackgroundStep`) is sealed immediately instead: the
    /// reader is done with that segment even though the turn stays open, so
    /// it gets its own footer at once, later segments get theirs, and a
    /// sealed footer never moves or disappears (pp 2026-11-18).
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
    /// - Parameter isBackgroundStep: whether a group hands the turn off to
    ///   background work (subagent / `runInBackground` command). Every such
    ///   step seals the reply finished just before it: that reply gets its own
    ///   footer immediately, and the following segment starts a new one. A
    ///   sealed footer is never removed or moved (pp 2026-11-18).
    static func build(groups: [ChatTimelineGroup], suppressLatest: Bool,
                      hasPendingUserMessage: Bool = false,
                      liveTurnGroupID: String? = nil,
                      footerHostEligible: (ChatTimelineGroup) -> Bool = { _ in true },
                      isBackgroundStep: (ChatTimelineGroup) -> Bool = { _ in false })
        -> [String: TimelineTurnAction] {
        var actions: [String: TimelineTurnAction] = [:]
        var replies: [ChatTimelineRowModel] = []
        var changes: [ChatTimelineRowModel] = []
        var startsMidTurn = true
        var endGroupID: String?
        /// The segment's last eligible host whose text is final (every
        /// assistant message in it is off its active status). Only this group
        /// may be sealed by a background step — a still-streaming reply never
        /// carries a footer.
        var lastCompletedHostID: String?
        /// Whether the segment holds a reply that is still streaming. Sealing
        /// while it does would put half a sentence into the earlier reply's
        /// copy text and then move the footer once that reply completes — the
        /// connector publishes a tool row before its final message row, so the
        /// state is reachable (pp 2026-11-18 red-team). The seal waits for the
        /// text instead; the background row stays in the list either way.
        var segmentHasStreamingMessage = false
        var turnOpen = false
        var hasActiveItems = false
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

        func commit() {
            if let endGroupID, (!replies.isEmpty || !changes.isEmpty), !hasActiveItems {
                actions[endGroupID] = TimelineTurnAction(replies: replies, changes: changes, startsMidTurn: startsMidTurn)
            }
            replies = []; changes = []; endGroupID = nil; lastCompletedHostID = nil
            segmentHasStreamingMessage = false
            turnOpen = false; hasActiveItems = false
            bucketTurnID = nil
        }

        /// Close the reply segment finished just before a background step.
        ///
        /// The reader is done with that segment even though the turn stays
        /// open: it gets its own footer immediately, and the accumulator
        /// starts over so a later reply gets its own. A turn with no
        /// background steps therefore still produces exactly one footer (the
        /// turn-end commit); only hand-offs multiply them. The seal is
        /// re-derived from the rows on every build, so while those rows stay
        /// in the loaded window the footer cannot move or disappear
        /// (pp 2026-11-18).
        func sealFinishedSegment() {
            // A streaming reply has not finished for the reader yet. Sealing
            // now would copy half a sentence into an earlier host and move the
            // footer when it completes, so the hand-off waits for the text.
            guard let host = lastCompletedHostID, !segmentHasStreamingMessage else { return }
            if !replies.isEmpty || !changes.isEmpty {
                actions[host] = TimelineTurnAction(replies: replies, changes: changes,
                                                   startsMidTurn: startsMidTurn)
            }
            replies = []; changes = []; endGroupID = nil; lastCompletedHostID = nil
            segmentHasStreamingMessage = false
            // `hasActiveItems` is deliberately kept — but the hand-off's own
            // rows never enter it (see `isBackgroundHandoffRow`), so the
            // background card cannot suppress the next segment. A foreground
            // tool still running keeps the residual segment closed
            // (`aRunningToolKeepsTheFooterClosed`).
        }

        for group in groups {
            if group.id == liveTurnGroupID { pastLiveTurnStart = true }
            if group.rows.contains(where: { $0.structure.startsTurn }) {
                commit()
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
                commit()
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
            if hostsFooter(group), !messages.isEmpty,
               messages.allSatisfy({ !$0.structure.status.isActive }) {
                lastCompletedHostID = group.id
            }
            replies.append(contentsOf: messages)
            if messages.contains(where: { $0.structure.status.isActive }) {
                segmentHasStreamingMessage = true
            }
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
            // (`aRunningToolKeepsTheFooterClosed`).
            let active = group.rows.contains {
                $0.structure.status.isActive
                    && !TimelineEntryPresentation.isCompactItem($0.value)
                    && !isBackgroundHandoffRow($0.value)
            }
            hasActiveItems = hasActiveItems || active
            // A hand-off to background work seals the reply finished just
            // before it: the reader is done with that segment even though the
            // turn stays open (pp 2026-11-18).
            if isBackgroundStep(group) { sealFinishedSegment() }
        }
        // The pending user bubble already starts the next turn, even before its
        // echo enters groups. A runtime "waiting" event belongs to that new turn.
        if (!suppressLatest || hasPendingUserMessage), !hasActiveItems {
            commit()
        }
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
    static func resolveLiveTurnGroupID(isLiveUserTurn: Bool,
                                       hasUnEchoedPending: Bool,
                                       latestUserRowID: String?,
                                       groups: [ChatTimelineGroup]) -> String? {
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
            group.rows.contains { $0.structure.status.isActive }
        }
        return liveRowsAfterBubble ? groups[bubbleIndex].id : nil
    }

    /// Whether a group carries work the turn handed off to the background: a
    /// subagent dispatch or a background command (`runInBackground`).
    ///
    /// The reply before such a step is finished for the reader even though the
    /// turn stays open, so it keeps its own footer right away and later
    /// segments get theirs in turn (pp 2026-11-18: 子代理在后台跑，回复已完成
    /// 就必须带页脚；页脚一旦出现不移除不移动).
    ///
    /// Only a **background** hand-off counts, never a foreground one:
    /// - an Agent dispatch must report itself backgrounded
    ///   (`runInBackground` from Claude's tool input, or an
    ///   `agents[*].isBackgrounded` task event). A foreground Agent call is an
    ///   ordinary tool step — the turn's text continues after it and the
    ///   one-footer-at-turn-end rule still applies (pp 2026-11-18 red-team:
    ///   sealing every dispatch split a normal turn into two footers);
    /// - a control call on an agent that already exists is never a dispatch:
    ///   the wire's real action words are `send_input` / `wait` / `close`
    ///   (DSH projects `send_message`/`list_agents` this way, `list_agents`
    ///   degrading to `unknown`).
    ///
    /// `runInBackground` is written on Claude's rows. Codex's agent-call writer
    /// never sets it, and DSH's command content has no such field: a runtime
    /// that does not report the flag degrades to the turn-end footer —
    /// capability-driven, no provider branching.
    static func isBackgroundStep(_ group: ChatTimelineGroup) -> Bool {
        group.rows.contains { isBackgroundHandoffRow($0.value) }
    }

    /// One row that hands the turn off to the background. The row-level
    /// predicate behind `isBackgroundStep`, and the exclusion `build` applies
    /// to the activity tally: the card keeps `running` for the whole
    /// background run, so counting it would hold the next segment's footer
    /// back until the background returns (pp 2026-11-18 需求 2: 不等子代理).
    private static func isBackgroundHandoffRow(_ item: V2TimelineItem) -> Bool {
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
    /// call on an agent that already exists. Shared by the footer seal and the
    /// step summary's present-tense phrase so both agree on what "an agent
    /// running" means.
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

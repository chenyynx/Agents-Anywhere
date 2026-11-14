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

    init() {}

    /// Feeds one adapter refresh; returns whether the latest turn's footer
    /// must stay suppressed.
    mutating func update(userKey: String?, runtimeIsRunning: Bool,
                         authoritativeTurnEnds: Int) -> Bool {
        if self.userKey == nil {
            // First refresh: a restored in-flight turn stays open; a restored
            // finished turn is already closed.
            self.userKey = userKey
            isOpen = runtimeIsRunning
            endsSeen = authoritativeTurnEnds
            return isOpen
        }
        if userKey != self.userKey {
            self.userKey = userKey
            isOpen = true
            endsSeen = authoritativeTurnEnds
            return isOpen
        }
        if authoritativeTurnEnds != endsSeen {
            endsSeen = authoritativeTurnEnds
            isOpen = false
        }
        return isOpen
    }
}

enum TimelineTurnActions {
    /// Match Web's one-footer-per-turn rule. Tool results and reasoning can
    /// end a turn but never enter its copied reply.
    ///
    /// The footer is committed only when the turn is over (`suppressLatest`
    /// false). It must not hop to each newly finished reply segment during a
    /// running turn (pp 2026-11-14); the adapter's `TurnFooterGate` turns the
    /// volatile runtime status into a stable open/closed boundary, so a
    /// running/idle flap across tool steps cannot flicker the row.
    ///
    /// The footer host is the last group of the turn that actually draws one:
    /// divider groups (marker/system rows, e.g. a compaction boundary) and a
    /// caller-excluded renderer (the Code page's one-line step groups) never
    /// host it. Hosting it on a divider read as a 91 pt jump on device
    /// (2026-10-31 05:40: the compact boundary carried the review + copy
    /// footer, then lost it when the next step group arrived).
    static func build(groups: [ChatTimelineGroup], suppressLatest: Bool,
                      hasPendingUserMessage: Bool = false,
                      footerHostEligible: (ChatTimelineGroup) -> Bool = { _ in true })
        -> [String: TimelineTurnAction] {
        var actions: [String: TimelineTurnAction] = [:]
        var replies: [ChatTimelineRowModel] = []
        var changes: [ChatTimelineRowModel] = []
        var startsMidTurn = true
        var endGroupID: String?
        var turnOpen = false
        var hasActiveItems = false

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
            replies = []; changes = []; endGroupID = nil; turnOpen = false; hasActiveItems = false
        }

        for group in groups {
            if group.rows.contains(where: { $0.structure.startsTurn }) {
                commit()
                turnOpen = true
                startsMidTurn = false
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
            if hostsFooter(group) { endGroupID = group.id }
            replies.append(contentsOf: messages)
            changes.append(contentsOf: fileChanges)
            let active = group.rows.contains { $0.structure.status.isActive }
            hasActiveItems = hasActiveItems || active
        }
        // The pending user bubble already starts the next turn, even before its
        // echo enters groups. A runtime "waiting" event belongs to that new turn.
        if (!suppressLatest || hasPendingUserMessage), !hasActiveItems {
            commit()
        }
        return actions
    }
}

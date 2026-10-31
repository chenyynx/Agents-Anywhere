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

enum TimelineTurnActions {
    /// Match Web's one-footer-per-turn rule. Tool results and reasoning can
    /// end a turn but never enter its copied reply.
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
        // A running turn may still keep the footer of its last *finished*
        // segment. A tool call continues the same turn; without this the
        // completed reply lost its footer when the tool segment started and
        // the row shrank 30 pt mid-turn (device 2026-10-31 14:25:
        // g:msg_fbe3af45 164→134 at the step group's arrival, offset -30 in
        // the same apply).
        var settledEndGroupID: String?
        var settledReplies: [ChatTimelineRowModel] = []
        var settledChanges: [ChatTimelineRowModel] = []
        /// The settled host is only sticky while the turn continues past it.
        /// A turn whose last segment is already finished keeps the existing
        /// rule: no footer until the turn itself ends.
        var contentAfterSettled = false

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
            settledEndGroupID = nil; settledReplies = []; settledChanges = []
            contentAfterSettled = false
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
            if settledEndGroupID != nil { contentAfterSettled = true }
            let hosts = hostsFooter(group)
            if hosts { endGroupID = group.id }
            replies.append(contentsOf: messages)
            changes.append(contentsOf: fileChanges)
            let active = group.rows.contains { $0.structure.status.isActive }
            hasActiveItems = hasActiveItems || active
            if hosts, !active {
                settledEndGroupID = group.id
                settledReplies = replies
                settledChanges = changes
                contentAfterSettled = false
            }
        }
        // The pending user bubble already starts the next turn, even before its
        // echo enters groups. A runtime "waiting" event belongs to that new turn.
        if !suppressLatest || hasPendingUserMessage {
            commit()
        } else if let settledEndGroupID, contentAfterSettled,
                  (!settledReplies.isEmpty || !settledChanges.isEmpty) {
            // The turn is still running, but an earlier segment already
            // finished. Keep its footer where it is: removing it here made a
            // 30 pt jump when a tool call continued the same turn. The footer
            // moves to the final segment when the turn ends.
            actions[settledEndGroupID] = TimelineTurnAction(
                replies: settledReplies, changes: settledChanges, startsMidTurn: startsMidTurn)
        }
        return actions
    }
}

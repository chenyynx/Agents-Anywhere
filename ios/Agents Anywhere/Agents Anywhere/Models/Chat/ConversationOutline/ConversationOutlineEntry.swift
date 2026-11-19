import Foundation

/// One row of the conversation outline.
///
/// The official app groups every adjacent message that shares a turn and a
/// sender into one outline row: `text` is the parts joined with a newline while
/// `parts` keeps each message's own id so a search hit can jump to the exact
/// message, not just the row's first one.
nonisolated struct ConversationOutlineEntry: Identifiable, Equatable {
    nonisolated struct Part: Equatable {
        let id: V2TimelineItemID
        let text: String
        let createdAt: Date?
        let isActive: Bool
    }

    /// The first part's id; the row's stable identity in the outline list.
    let id: V2TimelineItemID
    let sender: V2MessageRole
    /// Parts joined with `\n`, empty parts skipped — the row's preview text.
    let text: String
    let parts: [Part]
    let isArriving: Bool
    let sentAt: Date?
    let attachmentCount: Int

    /// The message a tap opens when the user is not jumping from a search hit.
    var firstPartID: V2TimelineItemID? { parts.first?.id }
}

/// Builds outline rows from the timeline window and/or the local row store.
///
/// Ordering is the timeline's own rule (`orderSeq`, id as the tie-break). Only
/// top-level user/assistant message rows enter the outline: subagent rows are
/// excluded, and tool / reasoning / system / compact rows never appear.
nonisolated enum ConversationOutlineEntryBuilder {
    private struct Group {
        var turnID: String?
        var role: V2MessageRole
        var items: [V2TimelineItem]
    }

    static func entries(from items: [V2TimelineItem]) -> [ConversationOutlineEntry] {
        let ordered = items
            .filter(isMainConversationMessage)
            .sorted { lhs, rhs in
                lhs.orderSeq == rhs.orderSeq ? lhs.id < rhs.id : lhs.orderSeq < rhs.orderSeq
            }

        var groups: [Group] = []
        for item in ordered {
            var merged = false
            if let turnID = item.turnId, let lastIndex = groups.indices.last,
               groups[lastIndex].turnID == turnID,
               groups[lastIndex].role == item.role {
                groups[lastIndex].items.append(item)
                merged = true
            }
            if !merged {
                groups.append(Group(turnID: item.turnId, role: item.role ?? .unknown, items: [item]))
            }
        }
        return groups.compactMap { entry(from: $0) }
    }

    static func isMainConversationMessage(_ item: V2TimelineItem) -> Bool {
        guard item.type == .message, let role = item.role, role == .user || role == .assistant else {
            return false
        }
        // Rows attributed to an Agent card fold under that card in the chat;
        // the outline lists the main conversation only.
        return SubAgentProgress.parentItemID(item) == nil
    }

    private static func entry(from group: Group) -> ConversationOutlineEntry? {
        guard let first = group.items.first else { return nil }
        let parts = group.items.map { item in
            ConversationOutlineEntry.Part(
                id: item.id,
                text: item.displayText,
                createdAt: ChatTimestamp.parse(item.createdAt),
                isActive: item.status.isActive
            )
        }
        let joined = parts.map { $0.text }.filter { !$0.isEmpty }.joined(separator: "\n")
        return ConversationOutlineEntry(
            id: first.id,
            sender: group.role,
            text: joined,
            parts: parts,
            isArriving: parts.contains { $0.isActive },
            sentAt: parts.compactMap { $0.createdAt }.first,
            attachmentCount: group.items.reduce(0) { $0 + attachmentCount(of: $1) }
        )
    }

    private static func attachmentCount(of item: V2TimelineItem) -> Int {
        guard case let .message(content) = item.content else { return 0 }
        return content.attachments.count
    }
}

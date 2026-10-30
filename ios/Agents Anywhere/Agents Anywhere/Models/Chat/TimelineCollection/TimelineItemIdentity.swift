import Foundation

/// Stable identity for one top-level item in the collection timeline. Diffable
/// data sources and the height cache key on this, never on array positions: a
/// prepended history page shifts every index but must not re-key a single row.
///
/// The `itemID` prefixes keep the height cache unambiguous when a row, a
/// notice and a pending message happen to share a wire id (`g:` / `n:` / `p:`).
nonisolated enum TimelineListItem: Hashable, Sendable {
    case olderPrompt
    /// The group's first row id (the same identity the SwiftUI list used).
    case group(String)
    /// The turn's working status (`CodeThinkingStatusLine`). It is its own
    /// transcript row, the official `CodeThinkingView` shape, so its
    /// appearance and disappearance never re-key a message group.
    case workingStatus
    case notice(String)
    case pending(String)
    case latestPrompt
    case tail

    var itemID: String {
        switch self {
        case .olderPrompt: return "prompt:older"
        case .group(let id): return "g:\(id)"
        case .workingStatus: return "working:status"
        case .notice(let id): return "n:\(id)"
        case .pending(let id): return "p:\(id)"
        case .latestPrompt: return "prompt:latest"
        case .tail: return "tail"
        }
    }
}

/// The ordered item list plus the duplicate ids that lost the first-wins
/// contest. Duplicates are a data defect, not a crash: the controller logs
/// them (one line, ids only) and renders the first occurrence.
nonisolated struct TimelineItemIdentityList: Equatable {
    let items: [TimelineListItem]
    let duplicateGroupIDs: [String]
    let duplicateNoticeIDs: [String]
    let duplicatePendingIDs: [String]

    var hasDuplicates: Bool {
        !duplicateGroupIDs.isEmpty || !duplicateNoticeIDs.isEmpty || !duplicatePendingIDs.isEmpty
    }
}

/// Which row ids may be used as a history anchor inside one top-level item.
/// The history prompts alias the first timeline row for the prepend's
/// first-row check; that alias must not participate in anchor matching, or
/// the projected anchor lands on the prompt at y=0 and the page scrolls to
/// the newly loaded top.
nonisolated enum TimelineHistoryAnchorRows {
    static func rows(for item: TimelineListItem, physicalRows: [String]) -> [String] {
        switch item {
        case .olderPrompt, .latestPrompt: return []
        default: return physicalRows
        }
    }
}

/// Builds the collection's top-level order. It mirrors the SwiftUI body's
/// order exactly: older prompt, groups, tail notices, pending messages,
/// working status, latest prompt, tail. Each category is deduplicated
/// independently, first wins.
nonisolated enum TimelineItemIdentity {
    static func build(hasOlderPrompt: Bool,
                      groupIDs: [String],
                      hasWorkingStatus: Bool = false,
                      noticeIDs: [String],
                      pendingIDs: [String],
                      hasLatestPrompt: Bool,
                      hasTail: Bool = true) -> TimelineItemIdentityList {
        var items: [TimelineListItem] = []
        items.reserveCapacity(groupIDs.count + noticeIDs.count + pendingIDs.count + 4)
        if hasOlderPrompt { items.append(.olderPrompt) }

        let groups = deduplicate(groupIDs)
        items.append(contentsOf: groups.values.map { .group($0) })
        let notices = deduplicate(noticeIDs)
        items.append(contentsOf: notices.values.map { .notice($0) })
        let pending = deduplicate(pendingIDs)
        items.append(contentsOf: pending.values.map { .pending($0) })
        // The working status row is the turn's last item: it follows the
        // messages and a just-sent pending bubble (the reader must see it
        // below their own message), and sits before the latest/tail rows.
        if hasWorkingStatus { items.append(.workingStatus) }

        if hasLatestPrompt { items.append(.latestPrompt) }
        if hasTail { items.append(.tail) }
        return TimelineItemIdentityList(items: items,
            duplicateGroupIDs: groups.duplicates,
            duplicateNoticeIDs: notices.duplicates,
            duplicatePendingIDs: pending.duplicates)
    }

    private static func deduplicate(_ ids: [String]) -> (values: [String], duplicates: [String]) {
        var seen = Set<String>(minimumCapacity: ids.count)
        var values: [String] = []
        var duplicates: [String] = []
        for id in ids {
            if seen.insert(id).inserted { values.append(id) } else { duplicates.append(id) }
        }
        return (values, duplicates)
    }
}

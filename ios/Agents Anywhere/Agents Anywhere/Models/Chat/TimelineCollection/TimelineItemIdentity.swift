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
    /// One official-shaped block row inside an assistant group: a prose run,
    /// a code block or a table. `row` is the owning message row; segments of
    /// the same row share it and are ordered by `index`.
    case segment(group: String, row: String, index: Int)
    case notice(String)
    case pending(String)
    case latestPrompt
    case tail

    var itemID: String {
        switch self {
        case .olderPrompt: return "prompt:older"
        case .group(let id): return "g:\(id)"
        case .segment(_, let row, let index): return "sg:\(row):\(index)"
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
    /// Duplicates after expanding a group into per-block segment rows.
    var duplicateItemIDs: [String] = []

    var hasDuplicates: Bool {
        !duplicateGroupIDs.isEmpty || !duplicateNoticeIDs.isEmpty
            || !duplicatePendingIDs.isEmpty || !duplicateItemIDs.isEmpty
    }
}

/// Builds the collection's top-level order. It mirrors the SwiftUI body's
/// order exactly: older prompt, groups, tail notices, pending messages, latest
/// prompt, tail. Each category is deduplicated independently, first wins.
nonisolated enum TimelineItemIdentity {
    static func build(hasOlderPrompt: Bool,
                      groupIDs: [String],
                      noticeIDs: [String],
                      pendingIDs: [String],
                      hasLatestPrompt: Bool,
                      hasTail: Bool = true,
                      itemsForGroup: ((String) -> [TimelineListItem])? = nil)
        -> TimelineItemIdentityList {
        var items: [TimelineListItem] = []
        items.reserveCapacity(groupIDs.count + noticeIDs.count + pendingIDs.count + 3)
        if hasOlderPrompt { items.append(.olderPrompt) }

        let groups = deduplicate(groupIDs)
        for groupID in groups.values {
            if let groupItems = itemsForGroup?(groupID), !groupItems.isEmpty {
                items.append(contentsOf: groupItems)
            } else {
                items.append(.group(groupID))
            }
        }
        let notices = deduplicate(noticeIDs)
        items.append(contentsOf: notices.values.map { .notice($0) })
        let pending = deduplicate(pendingIDs)
        items.append(contentsOf: pending.values.map { .pending($0) })

        if hasLatestPrompt { items.append(.latestPrompt) }
        if hasTail { items.append(.tail) }

        // Per-block rows share the group's order but carry their own identity;
        // a repeated itemID is a data defect, not a crash.
        var seen = Set<String>()
        var duplicateItemIDs: [String] = []
        items = items.filter { item in
            if seen.insert(item.itemID).inserted { return true }
            duplicateItemIDs.append(item.itemID)
            return false
        }
        return TimelineItemIdentityList(items: items,
            duplicateGroupIDs: groups.duplicates,
            duplicateNoticeIDs: notices.duplicates,
            duplicatePendingIDs: pending.duplicates,
            duplicateItemIDs: duplicateItemIDs)
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

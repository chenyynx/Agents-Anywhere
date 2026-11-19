import Foundation

/// Where the outline's rows come from: the loaded timeline window plus the
/// rows the local store still holds outside that window.
///
/// The opening read is bounded (`V2SessionCachePolicy.openingWindow`), so a
/// long session's older messages exist only on disk. The outline reads them
/// as well, otherwise scrolling the chat would silently grow the outline.
nonisolated enum ConversationOutlineSource {
    /// The row store trims a session above 5000 rows, so this reads everything
    /// it can hold. The budgets match the opening read's.
    static let cacheRowLimit = 5000
    static let cacheByteBudget = 64 * 1024 * 1024

    /// One item per id. A row in the loaded window wins over its cache copy:
    /// the window may carry a newer status or streaming text than the last
    /// persisted save. Ordering is the builder's job, not this merge's.
    static func merged(live: [V2TimelineItem], cached: [V2TimelineItem]) -> [V2TimelineItem] {
        guard !cached.isEmpty else { return live }
        var byID: [V2TimelineItemID: V2TimelineItem] = [:]
        byID.reserveCapacity(live.count + cached.count)
        for item in cached { byID[item.id] = item }
        for item in live { byID[item.id] = item }
        return Array(byID.values)
    }
}

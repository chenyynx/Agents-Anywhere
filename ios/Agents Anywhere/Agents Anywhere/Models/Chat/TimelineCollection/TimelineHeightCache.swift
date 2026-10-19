import Foundation

nonisolated enum TimelineHeightTier: Equatable {
    /// Verified against the real rendered row (hosting measurement).
    case measured
    /// Plain-text precalc (TextKit 2); never Markdown/tables/code/attachments.
    case precalc
    /// Cheap heuristic for a row that has not been measured yet.
    case estimate
}

/// Estimates are per kind, not one global constant: a 44pt prompt rendered at
/// 200pt would blank the top of the list, and a 12/32pt tail rendered at 200pt
/// would park the bottom hundreds of points short.
nonisolated enum TimelineHeightEstimateKind: Equatable {
    case olderPrompt
    case latestPrompt
    case tail(statusLine: Bool)
    case row

    var height: CGFloat {
        switch self {
        case .olderPrompt, .latestPrompt: return 44
        case .tail(let statusLine): return statusLine ? 32 : 12
        case .row: return 200
        }
    }
}

/// Three-tier height cache keyed by `TimelineHeightKey`.
///
/// One item holds one current key plus its last displayed height. A content or
/// typography revision replaces the key; the new key starts empty, and the
/// resolver falls back to the *displayed* height rather than the previous
/// key's measured value, so a streaming row never restarts from a stale
/// height. Items removed from the snapshot lose every tier.
nonisolated final class TimelineHeightCache {
    private struct Entry: Equatable {
        var measured: CGFloat?
        var precalc: CGFloat?
        var estimate: CGFloat?
    }

    private var entries: [TimelineHeightKey: Entry] = [:]
    private var currentKeys: [String: TimelineHeightKey] = [:]
    private var displayedHeights: [String: CGFloat] = [:]
    private var pendingItemIDs: Set<String> = []

    /// Installing a new revision drops the previous key's tiers: the item is
    /// bounded to one key per moment, and a streaming revision must not leave
    /// a retired measurement behind for `resolvedHeight` to find. Until the
    /// new key is measured, `displayedHeight` is the fallback (v7 §3.4.1
    /// allows either retention or this bounded form).
    func setCurrentKey(_ key: TimelineHeightKey) {
        if let previous = currentKeys[key.itemID], previous != key {
            entries[previous] = nil
        }
        currentKeys[key.itemID] = key
    }

    func currentKey(for itemID: String) -> TimelineHeightKey? { currentKeys[itemID] }

    func set(_ height: CGFloat, for key: TimelineHeightKey, tier: TimelineHeightTier) {
        var entry = entries[key] ?? Entry()
        switch tier {
        case .measured: entry.measured = height
        case .precalc: entry.precalc = height
        case .estimate: entry.estimate = height
        }
        entries[key] = entry
    }

    /// measured > precalc > estimate for one key.
    func tieredHeight(for key: TimelineHeightKey) -> CGFloat? {
        guard let entry = entries[key] else { return nil }
        return entry.measured ?? entry.precalc ?? entry.estimate
    }

    /// Whether the key carries a real measurement (hosting or plain-text
    /// precalc). An estimate is a fallback, not a cache hit: the row still
    /// needs its first measurement, and defer must let that first measurement
    /// through.
    func hasMeasuredOrPrecalcHeight(for key: TimelineHeightKey) -> Bool {
        guard let entry = entries[key] else { return false }
        return entry.measured != nil || entry.precalc != nil
    }

    /// The height the layout should use for this key. A missing entry (new
    /// content revision) falls back to the item's last displayed height and
    /// only then to the kind estimate.
    func resolvedHeight(for key: TimelineHeightKey, itemID: String,
                        fallback: TimelineHeightEstimateKind) -> CGFloat {
        if let height = tieredHeight(for: key) { return height }
        if let displayed = displayedHeights[itemID] { return displayed }
        return fallback.height
    }

    func noteDisplayedHeight(_ height: CGFloat, for itemID: String) {
        displayedHeights[itemID] = height
    }

    func displayedHeight(for itemID: String) -> CGFloat? { displayedHeights[itemID] }

    func markPending(_ itemID: String) { pendingItemIDs.insert(itemID) }
    func resolvePending(_ itemID: String) { pendingItemIDs.remove(itemID) }
    func isPending(_ itemID: String) -> Bool { pendingItemIDs.contains(itemID) }
    var pendingItems: Set<String> { pendingItemIDs }

    func remove(itemID: String) {
        currentKeys[itemID] = nil
        displayedHeights[itemID] = nil
        pendingItemIDs.remove(itemID)
        entries = entries.filter { $0.key.itemID != itemID }
    }

    func prune(keeping itemIDs: Set<String>) {
        for itemID in Array(currentKeys.keys) where !itemIDs.contains(itemID) {
            remove(itemID: itemID)
        }
        for key in Array(entries.keys) where !itemIDs.contains(key.itemID) {
            entries[key] = nil
        }
    }

    /// DEBUG invariant for the layout: every cached item still carries the key
    /// the controller expects. A mismatch means a reconfigure forgot to set
    /// the new key and the layout is silently reusing another revision's
    /// height.
    func staleItemIDs(expectedKeys: [String: TimelineHeightKey]) -> [String] {
        expectedKeys.compactMap { itemID, key in currentKeys[itemID] == key ? nil : itemID }.sorted()
    }

    var trackedItemIDs: Set<String> { Set(currentKeys.keys) }
}

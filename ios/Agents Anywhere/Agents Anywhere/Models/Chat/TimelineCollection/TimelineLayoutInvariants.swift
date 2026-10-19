import Foundation

/// DEBUG-only checks the collection layout calls at `finalizeCollectionViewUpdates`.
///
/// Pure model tests cannot prove that the layout actually delegates to these
/// types. These checks exist so the integration gate has a cheap way to fail
/// loudly when a reconfigure forgot to install the new height key, or when a
/// one-shot offset survived finalize without being applied or cleared.
nonisolated enum TimelineLayoutInvariants {
    static func heightKeyViolations(cache: TimelineHeightCache,
                                    expectedKeys: [String: TimelineHeightKey]) -> [String] {
        cache.staleItemIDs(expectedKeys: expectedKeys).map { "stale-height-key:\($0)" }
    }

    static func owedViolations(owed: TimelineInsertionOwed?) -> [String] {
        guard let owed, owed.hasOwed else { return [] }
        return ["owed-outstanding-after-finalize"]
    }

    static func violations(cache: TimelineHeightCache,
                           expectedKeys: [String: TimelineHeightKey],
                           owed: TimelineInsertionOwed?) -> [String] {
        heightKeyViolations(cache: cache, expectedKeys: expectedKeys) + owedViolations(owed: owed)
    }
}

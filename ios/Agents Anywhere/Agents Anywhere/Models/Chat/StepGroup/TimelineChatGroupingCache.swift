import Foundation

/// Incremental front end for `TimelineChatGrouping.units`.
///
/// A stream tick replaces only the tail of the wire rows, yet the chat profile
/// re-grouped the whole timeline on every refresh — `adapter.group` was
/// 3.8 ms of the 7.1 ms `adapter.refresh` on the 2026-11-08 device probe. The
/// cache keeps the previous input, one cheap fingerprint per row and the units
/// they produced. When the input differs only in a suffix it reuses the
/// prefix's units and re-groups from the unit that contains the first changed
/// row; anything it cannot prove safe falls back to a full rebuild.
///
/// The contract is equivalence: for every input the returned units must equal
/// `TimelineChatGrouping.units` field for field. `TimelineChatGroupingCacheTests`
/// compares the two over random sequences and mutations; that test is the
/// guard against a fingerprint that misses a grouping input.
nonisolated struct TimelineChatGroupingCache {
    /// Every `V2TimelineItem` field the grouping and a step unit's payload
    /// read. `raw` is deliberately not compared: the wire tree is large and
    /// `contentHash`/`revision`/`updatedSeq` already move whenever the payload
    /// does.
    private nonisolated struct RowFingerprint: Hashable {
        let id: String
        let orderSeq: Int
        let type: V2TimelineItemType
        let role: V2MessageRole?
        let turnID: V2TurnID?
        let status: V2TimelineItemStatus
        let revision: Int
        let updatedSeq: Int
        let contentHash: String
        let displayText: String
        let contentKind: String?
        let parentItemID: String?
        let nativeMessageID: String?
        let sourceItemID: String?

        init(_ item: V2TimelineItem) {
            id = item.id
            orderSeq = item.orderSeq
            type = item.type
            role = item.role
            turnID = item.turnId
            status = item.status
            revision = item.revision
            updatedSeq = item.updatedSeq
            contentHash = item.contentHash
            displayText = item.displayText
            contentKind = item.raw["content"]?["kind"]?.stringValue
            parentItemID = TimelineText.first(item.raw["content"]?["parentItemId"])
            nativeMessageID = TimelineText.first(item.source["nativeMessageId"])
            sourceItemID = TimelineText.first(item.source["itemId"])
        }
    }

    private var profile: CodeRuntimeProfile?
    private var cwd: String?
    private var interactionTargets: Set<String> = []
    private var rows: [V2TimelineItem] = []
    private var fingerprints: [RowFingerprint] = []
    private var units: [TimelineChatUnit] = []
    /// row id → index of the unit that renders it. Sub-agent children and the
    /// loser of a duplicate id are absent, exactly as in the grouping pass.
    private var rowUnitIndex: [String: Int] = [:]
    private var hasInput = false

    mutating func units(items: [V2TimelineItem],
                        profile: CodeRuntimeProfile,
                        interactionTargets: Set<String>,
                        cwd: String? = nil) -> [TimelineChatUnit] {
        let sorted = items.sorted(by: TimelineChatGrouping.wireOrder)
        var fingerprints: [RowFingerprint] = []
        fingerprints.reserveCapacity(sorted.count)
        var seen = Set<String>()
        var hasDuplicates = false
        for item in sorted {
            fingerprints.append(RowFingerprint(item))
            if !seen.insert(item.id).inserted { hasDuplicates = true }
        }
        // Duplicate ids keep the first occurrence. Reusing a prefix would hide
        // whether the prefix already consumed the id, so duplicates rebuild.
        guard hasInput,
              self.profile == profile,
              self.cwd == cwd,
              self.interactionTargets == interactionTargets,
              !hasDuplicates else {
            return rebuild(sorted, fingerprints: fingerprints,
                           profile: profile, interactionTargets: interactionTargets, cwd: cwd)
        }
        let old = self.fingerprints
        let common = min(old.count, fingerprints.count)
        var firstDiff = 0
        while firstDiff < common, old[firstDiff] == fingerprints[firstDiff] {
            firstDiff += 1
        }
        if firstDiff == old.count, firstDiff == fingerprints.count {
            // Same input, new array: keep the units, refresh the stored copy.
            self.rows = sorted
            return self.units
        }
        // The changed row can merge into the unit before it (a new tool row
        // extends a step group, a new body row extends a message), so rebuild
        // from the unit that renders the first unchanged predecessor. Without
        // a predecessor (change at the head) or a boundary row that still
        // exists in the new input, rebuild everything.
        guard firstDiff > 0,
              let unitIndex = unitIndex(beforeOldRow: firstDiff),
              let boundaryID = units[unitIndex].rowIDs.first,
              let start = sorted.firstIndex(where: { $0.id == boundaryID }) else {
            return rebuild(sorted, fingerprints: fingerprints,
                           profile: profile, interactionTargets: interactionTargets, cwd: cwd)
        }
        // The grouping pass carries the declared turn across rows and flushes
        // on a change; a suffix pass cannot rediscover the turns that were
        // declared before `start`, so seed the cursor. Without it the first
        // turn declaration inside the tail looks like the initial one and the
        // step/message it should close stays merged (the differential test
        // caught exactly that: `msg(m4)` gained the next turn's rows).
        let tailUnits = TimelineChatGrouping.units(
            items: Array(sorted[start...]),
            profile: profile,
            interactionTargets: interactionTargets,
            cwd: cwd,
            startingTurnID: TimelineChatGrouping.turnContext(
                before: start, in: sorted, interactionTargets: interactionTargets))
        let merged = Array(units[0..<unitIndex]) + tailUnits
        self.rows = sorted
        self.fingerprints = fingerprints
        self.units = merged
        rebuildRowUnitIndex()
        return merged
    }

    /// The unit that renders the row just before `rowIndex` in the previous
    /// input. Rows the grouping dropped (sub-agent children, duplicate losers)
    /// are skipped so the boundary still names a real unit.
    private func unitIndex(beforeOldRow rowIndex: Int) -> Int? {
        var probe = rowIndex - 1
        while probe >= 0 {
            if let unit = rowUnitIndex[rows[probe].id] { return unit }
            probe -= 1
        }
        return nil
    }

    private mutating func rebuild(_ sorted: [V2TimelineItem],
                                  fingerprints: [RowFingerprint],
                                  profile: CodeRuntimeProfile,
                                  interactionTargets: Set<String>,
                                  cwd: String?) -> [TimelineChatUnit] {
        let rebuilt = TimelineChatGrouping.units(
            items: sorted, profile: profile,
            interactionTargets: interactionTargets, cwd: cwd)
        self.profile = profile
        self.cwd = cwd
        self.interactionTargets = interactionTargets
        self.rows = sorted
        self.fingerprints = fingerprints
        self.units = rebuilt
        self.hasInput = true
        rebuildRowUnitIndex()
        return rebuilt
    }

    private mutating func rebuildRowUnitIndex() {
        var index: [String: Int] = [:]
        index.reserveCapacity(rows.count)
        for (unitIndex, unit) in units.enumerated() {
            for rowID in unit.rowIDs where index[rowID] == nil {
                index[rowID] = unitIndex
            }
        }
        rowUnitIndex = index
    }
}

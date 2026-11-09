import Foundation

/// The step groups that belong to the turn still in flight (pp 2026-11-10).
///
/// A group belongs to the running turn when its first row was emitted after
/// the last user prompt. The detail sheet opens these at their newest step
/// even when the group is not the timeline's trailing unit (body text between
/// two tool runs) and even in the gap between two steps, where nothing is
/// running and the live-tail mark has no running step to seat on. A group
/// from a settled turn keeps opening at the top (pp 2026-10-30).
///
/// `orderSeq` is injected because the grouping pass reads only item ids; the
/// adapter resolves them against the wire rows it already holds.
nonisolated enum TimelineRunningTurnStepGroups {
    static func ids(units: [TimelineChatUnit],
                    orderSeq: (String) -> Int?,
                    lastUserOrder: Int) -> Set<String> {
        var ids: Set<String> = []
        for case let .stepGroup(group, rowIDs) in units {
            guard let firstID = rowIDs.first,
                  let order = orderSeq(firstID),
                  order > lastUserOrder else { continue }
            ids.insert(group.id)
        }
        return ids
    }
}

import Foundation

/// Who owns the chat profile's live working mark (pp 2026-11-17).
///
/// The mark seats on the turn's strict trailing unit. A step group keeps it
/// through the gaps between steps while nothing follows it; a message unit
/// (body text or a steering row) takes it away, and the group settles into
/// its summary.
///
/// A steering row must take it too. The SDK reads a steer at a tool
/// boundary, so the group above the steer bubble is already done; the mark
/// belongs under the solid steer bubble, where the standalone 「正在处理中」
/// row draws it. Skipping the steering row and keeping the group live put
/// the group's dots and that row on screen at the same time — two working
/// rows (device 2026-11-17 23:50:39, `timeline.working.row has=1` in the same
/// apply the steer row landed).
nonisolated enum TimelineChatLiveTail {
    /// Whether the last unit is a step group, i.e. the group that may carry
    /// the mark. Deliberately strict: the caller must not walk past any
    /// message unit to reach an older group.
    static func stepGroupOwnsMark(_ units: [TimelineChatUnit]) -> Bool {
        guard let last = units.last else { return false }
        if case .stepGroup = last { return true }
        return false
    }
}

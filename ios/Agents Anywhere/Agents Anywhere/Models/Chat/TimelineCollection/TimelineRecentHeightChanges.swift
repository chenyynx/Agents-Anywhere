import Foundation

/// A release-safe ring of the layout's recent row height changes.
///
/// Exists for one symptom (pp 2026-11-15): after a send the page follow
/// starts ~30 pt away from where the reader was, because a UIKit layout
/// correction moves the offset just before the working row appears. The
/// `timeline.mover` `scroll` entry records the correction but not which row
/// changed, so the next handless-correction entry carries this text and names
/// the row.
///
/// Kept out of `#if DEBUG` on purpose: the build that reproduces the jump on
/// the device is a release build. The buffer is tiny, and its text is only
/// read when a handless correction is logged.
nonisolated struct TimelineRecentHeightChanges {
    struct Change: Equatable {
        let itemID: String
        let oldHeight: CGFloat
        let newHeight: CGFloat
        let source: String
        let at: Double

        var delta: CGFloat { newHeight - oldHeight }
    }

    /// Newest last; only the last few can cause the correction in flight.
    private(set) var changes: [Change] = []
    static let capacity = 8

    mutating func note(itemID: String, oldHeight: CGFloat, newHeight: CGFloat,
                       source: String, at: Double) {
        guard abs(newHeight - oldHeight) > 0.5 else { return }
        if changes.count >= Self.capacity {
            changes.removeFirst(changes.count - Self.capacity + 1)
        }
        changes.append(Change(itemID: itemID, oldHeight: oldHeight,
                              newHeight: newHeight, source: source, at: at))
    }

    /// `id|old->new|delta|source` for changes younger than `window`, newest
    /// four only; nil when nothing recent. A whole-session dump would hide the
    /// one layout pass that actually moved the offset.
    func text(within window: Double, now: Double) -> String? {
        let recent = changes
            .filter { now - $0.at <= window && now >= $0.at }
            .suffix(4)
        guard !recent.isEmpty else { return nil }
        return recent.map { change in
            let old = String(format: "%.1f", change.oldHeight)
            let new = String(format: "%.1f", change.newHeight)
            let delta = String(format: "%+.1f", change.delta)
            return "\(change.itemID)|\(old)->\(new)|\(delta)|\(change.source)"
        }.joined(separator: ";")
    }
}

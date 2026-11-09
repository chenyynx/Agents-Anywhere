import Foundation

/// The step sheet's tail-follow latch (pp 2026-11-10).
///
/// While the turn streams the sheet keeps landing on the newest step — but
/// only for a reader who is at the bottom. The page's own growth moves the
/// bottom edge away, and that must not count as the reader leaving; otherwise
/// the first appended step would release the follow. Only the reader's own
/// drag (`readerTookOver()`) releases the latch, and resting back at the
/// bottom re-arms it.
///
/// Kept free of SwiftUI so the append gate and the unit tests share one rule;
/// `TimelineViewport.measuredAtBottom` carries the app's one-physical-pixel
/// bottom test.
nonisolated struct StepSheetTailFollow: Equatable {
    private(set) var followsTail: Bool

    init(followsTail: Bool = false) {
        self.followsTail = followsTail
    }

    /// A finger landed on the list: stop following until the reader settles
    /// back at the bottom.
    mutating func readerTookOver() {
        followsTail = false
    }

    /// Consumes one scroll-geometry sample. A sample away from the bottom
    /// proves nothing about the reader — the content may have just grown —
    /// so only the bottom edge changes the latch. Already-latched samples are
    /// no-ops: this runs on every scroll frame.
    mutating func consume(_ viewport: TimelineViewport) {
        guard !followsTail, viewport.measuredAtBottom else { return }
        followsTail = true
    }
}

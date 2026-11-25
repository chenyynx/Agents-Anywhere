import CoreGraphics

/// Whether a first measurement may land while the reader is scrolling.
///
/// A row that has never been on screen changes height for the first time when
/// its cell materializes near the viewport. Applying that change during a
/// drag/coast shifts every row below it and forces UIKit to re-lay the visible
/// band; the 2026-11-25 probe recorded 77 such corrections in 33 s of coasting
/// (88/89 for offscreen, never-displayed rows, one by 2054 pt).
///
/// A row entirely above the viewport is not visible now, and a row below the
/// viewport grows downward without moving what the reader sees. Only the
/// above case needs parking. The layout promotes a parked row back as soon as
/// it approaches the viewport, and flushes the rest when the gesture ends, so
/// the reader never sees a parked height.
///
/// Pure so the policy can be tested without a collection view.
nonisolated enum TimelineOffscreenMeasureDeferral {
    static func shouldPark(isBrowsing: Bool,
                           isInsideUpdate: Bool,
                           hasEverBeenDisplayed: Bool,
                           cellMaxY: CGFloat,
                           viewportTop: CGFloat) -> Bool {
        guard isBrowsing, !isInsideUpdate, !hasEverBeenDisplayed else { return false }
        return cellMaxY < viewportTop
    }
}

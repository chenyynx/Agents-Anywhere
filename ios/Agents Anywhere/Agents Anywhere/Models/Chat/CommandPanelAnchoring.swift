import Foundation

/// Placement of the slash-command card above the composer.
///
/// The card is a page-level overlay whose base ignores the keyboard's safe
/// area, while the page's geometry proxy reports the keyboard in
/// `safeAreaInsets` and may also shrink `size` around it. Subtracting both
/// collapsed the card to a few points when the keyboard was up, so opening it
/// from the composer drew nothing (pp 2026-11-15). Resolve from the measured
/// composer dock instead: the card's bottom clears that dock's top, and its
/// free height runs from the overlay base's top to the same dock. The inset
/// formula stays only as the pre-measurement fallback.
nonisolated struct CommandPanelAnchoring: Equatable {
    var bottomPadding: CGFloat
    var availableHeight: CGFloat

    /// - Parameters:
    ///   - baseTop/baseBottom: global frame of the overlay's base, after it
    ///     ignores the keyboard safe area. Nil before the first measurement.
    ///   - dockTop: global top of the composer dock. Nil before the first
    ///     measurement.
    static func resolve(baseTop: CGFloat?, baseBottom: CGFloat?, dockTop: CGFloat?,
                        insetTop: CGFloat, insetBottom: CGFloat, height: CGFloat) -> Self {
        let insetAvailable = max(0, height - insetTop - insetBottom - 8)
        guard let dockTop, dockTop > 0 else {
            return Self(bottomPadding: insetBottom, availableHeight: insetAvailable)
        }
        // Before the base reports its bottom, the inset is the dock's height
        // below the card.
        let baseBottom = baseBottom ?? (dockTop + insetBottom)
        let baseTop = baseTop ?? 0
        // Never sit lower than the inset places the card: whatever the inset
        // means on this build, the keyboard must not cover it.
        let padding = max(insetBottom, max(0, baseBottom - dockTop))
        // 8 pt keeps the card off the navigation bar.
        let available = max(0, dockTop - baseTop - insetTop - 8)
        return Self(bottomPadding: padding, availableHeight: available)
    }
}

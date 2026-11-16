import Foundation

/// Placement of the slash-command card above the composer.
///
/// Device diagnostic `composer.panel.geometry` (b1253, session
/// `sess_TZOh5OCVj3KD8w`, 2026-11-15 19:22–19:53) settled the geometry:
///
/// - the timeline view's frame is the transcript area between the navigation
///   bar and the composer bar (`baseTop 113 → baseBottom 414` with the
///   keyboard up, `113 → 758` down), so `baseBottom - baseTop` is exactly the
///   room the card may use;
/// - the composer dock reports the same `minY` as the timeline's bottom, so a
///   separate dock measurement adds nothing;
/// - `safeAreaInsets.bottom` is the distance from the timeline's bottom edge
///   to the screen bottom (composer bar + home indicator + keyboard; 438 up,
///   94 down), and the card's overlay base ends at the screen bottom — the
///   card must be lifted by that inset and by nothing else.
///
/// The previous attempt subtracted the navigation chrome twice and then mixed
/// measured frames from two coordinate spaces, which put the card under the
/// composer (keyboard down) or behind the keyboard (keyboard up).
nonisolated struct CommandPanelAnchoring: Equatable {
    var bottomPadding: CGFloat
    var availableHeight: CGFloat

    /// - Parameters:
    ///   - baseTop/baseBottom: global frame of the timeline view. Nil before
    ///     its first geometry action.
    ///   - insetBottom: the page's bottom safe area, measured from the same
    ///     view that hosts the card's overlay.
    ///   - height: the geometry proxy's height, the fallback before the
    ///     timeline reports its frame.
    static func resolve(baseTop: CGFloat?, baseBottom: CGFloat?,
                        insetBottom: CGFloat, height: CGFloat) -> Self {
        let visibleHeight: CGFloat
        if let baseTop, let baseBottom, baseBottom > baseTop {
            visibleHeight = baseBottom - baseTop
        } else {
            visibleHeight = height
        }
        // The card's base is the screen bottom, so the inset is the whole
        // lift; 8 pt keeps the card off the navigation bar.
        return Self(bottomPadding: insetBottom,
                    availableHeight: max(0, visibleHeight - 8))
    }
}

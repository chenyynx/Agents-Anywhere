import Foundation

/// Relative geometry for detecting layout changes and retaining history. It
/// deliberately does not infer arrival or a target offset from native insets.
nonisolated struct TimelineViewport: Equatable {
    let contentHeight: CGFloat
    let visibleHeight: CGFloat
    let visibleBottom: CGFloat
    let offsetY: CGFloat
    let topInset: CGFloat

    init(contentHeight: CGFloat = 0, containerHeight: CGFloat = 0,
         topInset: CGFloat = 0, bottomInset: CGFloat = 0, offsetY: CGFloat = 0) {
        self.contentHeight = max(0, contentHeight)
        visibleHeight = max(0, containerHeight - topInset - bottomInset)
        visibleBottom = offsetY + containerHeight - bottomInset
        self.offsetY = offsetY
        self.topInset = topInset
    }
    var isMeasured: Bool { visibleHeight > 0 }

    /// True when the measured scroll rests at its maximum offset — the
    /// content's bottom edge sits at the viewport's. `visibleBottom` reaches
    /// `contentHeight` exactly there by construction (maxOffset =
    /// contentHeight - containerHeight + bottomInset), so the gap is the real
    /// remaining travel; the tolerance absorbs float jitter and the
    /// half-visible tail marker. The marker probes are not consulted: the
    /// device probe read "at bottom" while this gap sat 213pt short.
    var measuredAtBottom: Bool { isMeasured && contentHeight - visibleBottom <= 8 }
}

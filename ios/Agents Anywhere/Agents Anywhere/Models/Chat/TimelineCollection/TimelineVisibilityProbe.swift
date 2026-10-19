import Foundation

/// One visibility probe in the timeline's content coordinate space.
///
/// The SwiftUI list expressed these as two tail overlays and two prompt rows
/// with `onScrollVisibilityChange` thresholds. The collection layout keeps the
/// same geometry as pure arithmetic so the probes can be unit-tested without a
/// render pass:
///
/// - older prompt: 90% of its 44pt row must be visible (`:610-616`);
/// - latest prompt: 50% (the modifier's default, `:646-655`);
/// - tail near marker: a 96pt overlay with a 1% threshold (`:695-705`);
/// - tail end marker: a 2pt overlay with a 50% threshold (`:695-705`).
///
/// "Visible fraction" is the probe's intersection with the viewport divided by
/// its own height. A probe pinned to the tail's bottom edge therefore reports
/// `1` exactly when the content's true end is on screen.
nonisolated struct TimelineVisibilityProbe: Equatable {
    let minY: CGFloat
    let height: CGFloat

    init(minY: CGFloat, height: CGFloat) {
        self.minY = minY
        self.height = max(0, height)
    }

    /// An overlay anchored to the bottom edge of the tail block.
    init(tailBottom: CGFloat, height: CGFloat) {
        self.init(minY: tailBottom - height, height: height)
    }

    var maxY: CGFloat { minY + height }

    func visibleFraction(in viewport: TimelineViewport) -> CGFloat {
        guard viewport.isMeasured, height > 0 else { return 0 }
        let viewportTop = viewport.visibleBottom - viewport.visibleHeight
        let overlap = min(viewport.visibleBottom, maxY) - max(viewportTop, minY)
        guard overlap > 0 else { return 0 }
        return min(1, overlap / height)
    }

    /// SwiftUI's `onScrollVisibilityChange(threshold:)` reports visible when at
    /// least `threshold` of the view is on screen. The epsilon absorbs the
    /// float division at an exact threshold.
    func isVisible(in viewport: TimelineViewport, threshold: CGFloat) -> Bool {
        visibleFraction(in: viewport) + 1e-6 >= threshold
    }
}

nonisolated enum TimelineVisibilityProbeRule {
    static let olderPromptThreshold: CGFloat = 0.9
    static let latestPromptThreshold: CGFloat = 0.5
    static let tailNearHeight: CGFloat = 96
    static let tailNearThreshold: CGFloat = 0.01
    static let tailEndHeight: CGFloat = 2
    static let tailEndThreshold: CGFloat = 0.5

    static func olderPrompt(minY: CGFloat) -> TimelineVisibilityProbe {
        TimelineVisibilityProbe(minY: minY, height: 44)
    }

    static func latestPrompt(minY: CGFloat) -> TimelineVisibilityProbe {
        TimelineVisibilityProbe(minY: minY, height: 44)
    }

    static func tailNear(tailBottom: CGFloat) -> TimelineVisibilityProbe {
        TimelineVisibilityProbe(tailBottom: tailBottom, height: tailNearHeight)
    }

    static func tailEnd(tailBottom: CGFloat) -> TimelineVisibilityProbe {
        TimelineVisibilityProbe(tailBottom: tailBottom, height: tailEndHeight)
    }

    static func olderPromptVisible(_ probe: TimelineVisibilityProbe, in viewport: TimelineViewport) -> Bool {
        probe.isVisible(in: viewport, threshold: olderPromptThreshold)
    }

    static func latestPromptVisible(_ probe: TimelineVisibilityProbe, in viewport: TimelineViewport) -> Bool {
        probe.isVisible(in: viewport, threshold: latestPromptThreshold)
    }

    static func tailNearVisible(_ probe: TimelineVisibilityProbe, in viewport: TimelineViewport) -> Bool {
        probe.isVisible(in: viewport, threshold: tailNearThreshold)
    }

    static func tailEndVisible(_ probe: TimelineVisibilityProbe, in viewport: TimelineViewport) -> Bool {
        probe.isVisible(in: viewport, threshold: tailEndThreshold)
    }
}

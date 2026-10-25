import SwiftUI

/// One scale for the header circles and the collapsed composer. The visible
/// send circle is inset inside a full-size touch target, never the other way round.
///
/// The values come from `ComposerMetricsProfile`: Chat keeps the current AA
/// bar, Code follows the official screenshot measurements.
struct ChatControlMetrics {
    /// Chat defaults, still used by Chat-only surfaces (new-session workspace
    /// button, error toasts, command panel) before a profile is chosen.
    static let collapsedHorizontalInset: CGFloat = 32
    static let expandedHorizontalInset: CGFloat = 12
    static let maximumContentWidth: CGFloat = 780
    /// Visible diameter of the context-usage ring, matched to the 18 pt command
    /// and send glyph scale; it is drawn inside a full-size touch target.
    static let contextRingDiameter: CGFloat = 18

    let profile: ComposerMetricsProfile
    let touchTarget: CGFloat
    let sendDiameter: CGFloat
    let textInset: CGFloat
    let textToActions: CGFloat
    let expandedContentInset: CGFloat
    let expandedBottomInset: CGFloat
    let collapsedTextGap: CGFloat
    let collapsedLeadingInset: CGFloat
    let collapsedTrailingInset: CGFloat
    let topMargin: CGFloat
    let collapsedBottomMargin: CGFloat
    let expandedBottomMargin: CGFloat
    let collapsedHeight: CGFloat
    let collapsedCornerRadius: CGFloat
    let expandedCornerRadius: CGFloat

    /// Kept for callers that still read the collapsed diameter.
    var diameter: CGFloat { collapsedHeight }
    var expandAnimation: ComposerMetricsProfile.ExpandAnimation { profile.expandAnimation }

    func horizontalInset(expanded: Bool) -> CGFloat {
        expanded ? profile.expandedHorizontalInset : profile.collapsedHorizontalInset
    }

    func bottomMargin(expanded: Bool) -> CGFloat {
        expanded ? expandedBottomMargin : collapsedBottomMargin
    }

    init(bodyLineHeight: CGFloat, profile: ComposerMetricsProfile? = nil) {
        let profile = profile ?? .chat(bodyLineHeight: bodyLineHeight)
        self.profile = profile
        self.touchTarget = profile.touchTarget
        self.sendDiameter = profile.sendDiameter
        self.textInset = profile.textInset
        self.textToActions = profile.textToActions
        self.expandedContentInset = profile.expandedContentInset
        self.expandedBottomInset = profile.expandedBottomInset
        self.collapsedTextGap = profile.collapsedTextGap
        self.collapsedLeadingInset = profile.collapsedLeadingInset
        self.collapsedTrailingInset = profile.collapsedTrailingInset
        self.topMargin = profile.topMargin
        self.collapsedBottomMargin = profile.collapsedBottomMargin
        self.expandedBottomMargin = profile.expandedBottomMargin
        self.collapsedHeight = profile.collapsedHeight
        self.collapsedCornerRadius = profile.collapsedCornerRadius
        self.expandedCornerRadius = profile.expandedCornerRadius
    }
}

import Foundation

/// The composer's geometry tokens. `chat` keeps the current AA Chat bar;
/// `code` follows the measurements taken from pp's official screenshots
/// (2026-10-26): collapsed 16 pt side inset / 52 pt tall, expanded 9 pt / 95 pt.
///
/// The profile is pure data so the insets, heights and radii can be pinned by
/// `ClientCoreTests` without a simulator.
nonisolated struct ComposerMetricsProfile: Equatable, Sendable {
    /// How the collapsed ↔ expanded transition is animated.
    enum ExpandAnimation: Equatable, Sendable {
        case smooth(duration: Double)
        case spring(response: Double, dampingFraction: Double)
    }

    /// The leading attachment button's chrome.
    enum PlusStyle: Equatable, Sendable {
        case bare
        /// A 44 pt gray circle behind the glyph, as captured in the official
        /// Chat screenshots.
        case circle
    }

    let collapsedHorizontalInset: CGFloat
    let expandedHorizontalInset: CGFloat
    let collapsedHeight: CGFloat
    let touchTarget: CGFloat
    let sendDiameter: CGFloat
    let textInset: CGFloat
    let textToActions: CGFloat
    /// Horizontal inset of the expanded control row inside the card.
    let expandedContentInset: CGFloat
    /// Vertical gap below the expanded control row.
    let expandedBottomInset: CGFloat
    let collapsedTextGap: CGFloat
    /// Horizontal inset of the collapsed row inside the card. The row is
    /// vertically centered by the layout, so this is horizontal only.
    let collapsedContentInset: CGFloat
    let topMargin: CGFloat
    let collapsedBottomMargin: CGFloat
    let expandedBottomMargin: CGFloat
    let collapsedCornerRadius: CGFloat
    let expandedCornerRadius: CGFloat
    let plusStyle: PlusStyle
    let plusSymbolSize: CGFloat
    let expandAnimation: ExpandAnimation

    var collapsedInset: CGFloat { collapsedContentInset }

    /// Expanded card height for a measured editor height.
    func expandedHeight(editorHeight: CGFloat) -> CGFloat {
        textInset + editorHeight + textToActions + touchTarget + expandedBottomInset
    }

    /// Chat keeps the current AA bar: a capsule scaled from the body line
    /// height, 32 pt collapsed / 12 pt expanded, 10 pt above the safe area.
    static func chat(bodyLineHeight: CGFloat) -> Self {
        let height = max(48, bodyLineHeight.rounded(.up) + 12)
        let touch = max(44, height - 4)
        return Self(
            collapsedHorizontalInset: 32,
            expandedHorizontalInset: 12,
            collapsedHeight: height,
            touchTarget: touch,
            sendDiameter: touch - 8,
            textInset: 16,
            textToActions: 10,
            expandedContentInset: 8,
            expandedBottomInset: 8,
            collapsedTextGap: 4,
            collapsedContentInset: 2,
            topMargin: 8,
            collapsedBottomMargin: 10,
            expandedBottomMargin: 10,
            collapsedCornerRadius: height / 2,
            expandedCornerRadius: height / 2 + 2,
            plusStyle: .bare,
            plusSymbolSize: 24,
            expandAnimation: .smooth(duration: 0.24)
        )
    }

    /// Code follows the official composer captured in pp's screenshots:
    /// 16 / 52 collapsed, 9 / 95 expanded, 24 pt expanded corner radius and
    /// the official 0.22 / 0.77 expand spring.
    static let code = Self(
        collapsedHorizontalInset: 16,
        expandedHorizontalInset: 9,
        collapsedHeight: 52,
        touchTarget: 44,
        sendDiameter: 36,
        textInset: 11,
        textToActions: 10,
        expandedContentInset: 3,
        expandedBottomInset: 8,
        collapsedTextGap: 12,
        collapsedContentInset: 2,
        topMargin: 8,
        collapsedBottomMargin: 0,
        expandedBottomMargin: 8,
        collapsedCornerRadius: 26,
        expandedCornerRadius: 24,
        plusStyle: .circle,
        plusSymbolSize: 20,
        expandAnimation: .spring(response: 0.22, dampingFraction: 0.77)
    )
}

import Foundation

/// The composer's geometry tokens. `chat` keeps the current AA Chat bar;
/// `code` follows the official composer: collapsed 18 pt side inset / 52 pt
/// tall, expanded 9 pt / 95 pt, controls 36 pt of chrome in a 44 pt hit slot.
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
        /// A gray circle behind the glyph, drawn inside the touch slot.
        case circle
    }

    let collapsedHorizontalInset: CGFloat
    let expandedHorizontalInset: CGFloat
    let collapsedHeight: CGFloat
    let touchTarget: CGFloat
    let sendDiameter: CGFloat
    /// Visible context-ring diameter inside its touch slot.
    let contextRingDiameter: CGFloat
    let textInset: CGFloat
    let textToActions: CGFloat
    /// Horizontal inset of the expanded control row inside the card.
    let expandedContentInset: CGFloat
    /// Vertical gap below the expanded control row.
    let expandedBottomInset: CGFloat
    let collapsedTextGap: CGFloat
    /// Horizontal insets of the collapsed row inside the card. The row is
    /// vertically centered by the layout, so these are horizontal only.
    let collapsedLeadingInset: CGFloat
    let collapsedTrailingInset: CGFloat
    let topMargin: CGFloat
    let collapsedBottomMargin: CGFloat
    let expandedBottomMargin: CGFloat
    let collapsedCornerRadius: CGFloat
    let expandedCornerRadius: CGFloat
    let plusStyle: PlusStyle
    /// Visible diameter of the attachment circle, centered in `touchTarget`.
    /// The official control is 36 pt of chrome inside a 44 pt hit area.
    let plusCircleDiameter: CGFloat
    let plusSymbolSize: CGFloat
    let expandAnimation: ExpandAnimation

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
            contextRingDiameter: 18,
            textInset: 16,
            textToActions: 10,
            expandedContentInset: 8,
            expandedBottomInset: 8,
            collapsedTextGap: 4,
            collapsedLeadingInset: 2,
            collapsedTrailingInset: 2,
            topMargin: 8,
            collapsedBottomMargin: 10,
            expandedBottomMargin: 10,
            collapsedCornerRadius: height / 2,
            expandedCornerRadius: height / 2 + 2,
            plusStyle: .bare,
            plusCircleDiameter: touch,
            plusSymbolSize: 24,
            expandAnimation: .smooth(duration: 0.24)
        )
    }

    /// Code follows the official composer: 18 / 52 collapsed, 9 / 95 expanded,
    /// 24 pt expanded corner radius and the official 0.22 / 0.77 spring.
    ///
    /// The control row comes from the official binary, not from a screenshot
    /// guess: `ChatInputControlButtonStyle` wraps every control in
    /// `ChatInputControlChrome`, whose body pins the chrome to 36 pt
    /// (`0x100b8d134`: 32 pt for `.small`, 36 pt for `.regular`), and
    /// `ChatInputControlTriggerStyle` gives it a 44 pt `MinimumTapTarget`
    /// (`0x100b8e8f0`). `SessionAddContextButton` builds that chrome with
    /// `.circle` + `.regular` (`0x100b8eaa4`: kind tag 1, size 0).
    static let code = Self(
        collapsedHorizontalInset: 18,
        expandedHorizontalInset: 9,
        collapsedHeight: 52,
        touchTarget: 44,
        sendDiameter: 36,
        contextRingDiameter: 16,
        textInset: 11,
        textToActions: 10,
        expandedContentInset: 3,
        expandedBottomInset: 8,
        collapsedTextGap: 11,
        collapsedLeadingInset: 2,
        collapsedTrailingInset: 2,
        topMargin: 8,
        collapsedBottomMargin: 0,
        expandedBottomMargin: 8,
        collapsedCornerRadius: 26,
        expandedCornerRadius: 24,
        plusStyle: .circle,
        plusCircleDiameter: 36,
        plusSymbolSize: 23,
        expandAnimation: .spring(response: 0.22, dampingFraction: 0.77)
    )
}

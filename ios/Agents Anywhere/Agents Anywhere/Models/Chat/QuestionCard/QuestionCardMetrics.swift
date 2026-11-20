import CoreGraphics
import Foundation

/// Official QuestionCard / QuestionAnsweredCard tokens.
///
/// Source: `aa-test/claude-ios-re/CANONICAL/25-question-card.md` (R32 closing
/// table, Claude iOS 1.261109.19), **re-calibrated 2026-11-20 against pp's
/// installed official app screenshot**: that build renders the card smaller
/// than the 1.261109.19 table (question ≈17 pt vs 20, option title ≈13 pt vs
/// 15, 44 pt buttons). Where the two disagree, the device screenshot wins —
/// the visible reference is pp's own app, not the R32 binary.
///
/// Kept value-only and view-free so `ClientCoreTests` can assert the official
/// numbers without building the app target (`ios/Package.swift` excludes
/// `Views`).
nonisolated enum QuestionCardMetrics {

    // MARK: - Geometry (E)

    static let cornerRadius: CGFloat = 24
    /// The 16.0 padding constant the binary carries (an inner padding).
    static let contentPadding: CGFloat = 16
    /// Card edge → question/divider row, measured on the 2026-11-19 device
    /// screenshots (R6 §1.4: 24.0); the 16.0 constant is NOT the card margin.
    static let contentPaddingHorizontal: CGFloat = 24
    /// The host's horizontal margin (device: 16.7 pt running / 16.3 pt
    /// answered; the component itself carries none).
    static let screenMargin: CGFloat = 16

    static let pagingSpacing: CGFloat = 8
    static let pagingLeading: CGFloat = 4
    static let arrowGlyphSize: CGFloat = 24
    static let arrowTapTarget: CGFloat = 44
    static let arrowPressedOpacity: Double = 0.5
    static let arrowDisabledOpacity: Double = 0.3

    static let optionRowBadgePadding: CGFloat = 16
    /// Row top/bottom padding; the device read of pp's official app shows
    /// a 67 pt row pitch (R6) — 12 pt vertical pad, not the 16 pt all-sides
    /// figure.
    static let optionRowVerticalPadding: CGFloat = 14
    static let optionRowPlainPadding: CGFloat = 4
    static let selectionBadgeMinSize: CGFloat = 30
    static let selectionBadgeStrokeWidth: CGFloat = 1
    /// Where the divider starts inside the card: the option text's leading
    /// edge (device read: 24 pt from the card edge).
    static let optionDividerInset: CGFloat = 24
    static let dividerThicknessPixels: CGFloat = 1

    static let submitSpacing: CGFloat = 8
    /// Two ~110 pt capsules centred in the card (device: 115 / 106 pt).
    static let submitRowMaxWidth: CGFloat = 232
    static let buttonPressedScale: CGFloat = 0.98
    static let buttonDisabledOpacity: Double = 0.75
    /// `ClaudeInlineButtonStyle` stroke = 2 × pixelLength (0.667 pt at 3x).
    static let buttonStrokePixels: CGFloat = 2

    static let inputCornerRadius: CGFloat = 24
    static let inputPadding: CGFloat = 12

    static let closeButtonSize: CGFloat = 44
    static let closeButtonShadowOpacity: Double = 0.08
    static let closeButtonShadowRadius: CGFloat = 4
    static let closeButtonShadowY: CGFloat = 2

    static let pageTransitionBlurRadius: CGFloat = 8
    static let pageTransitionScale: CGFloat = 0.9

    // MARK: - Typography (E: size / lineHeight / variable weight)

    static let titleSize: CGFloat = 13
    static let titleLineHeight: CGFloat = 18.2
    static let titleWeight: CGFloat = 550

    static let requesterSize: CGFloat = 15
    static let requesterLineHeight: CGFloat = 21
    static let requesterWeight: CGFloat = 500

    static let questionSize: CGFloat = 16.5
    static let questionLineHeight: CGFloat = 23.8
    static let questionWeight: CGFloat = 500

    static let optionSize: CGFloat = 12.5
    static let optionLineHeight: CGFloat = 20
    static let optionWeight: CGFloat = 500

    /// Option description: 13 / 18 / 400, secondary ink.
    static let optionDetailSize: CGFloat = 11
    static let optionDetailLineHeight: CGFloat = 17

    static let pagingSize: CGFloat = 12
    static let pagingLineHeight: CGFloat = 17
    static let pagingWeight: CGFloat = 400

    // MARK: - Answered card (E)

    static let answeredCornerRadius: CGFloat = 24
    static let answeredHorizontalPadding: CGFloat = 16
    static let answeredVerticalPadding: CGFloat = 12
    static let answeredSpacing: CGFloat = 12
    static let answeredHeaderSize: CGFloat = 15
    static let answeredHeaderLineHeight: CGFloat = 21
    static let answeredHeaderWeight: CGFloat = 500
    static let answeredRowSize: CGFloat = 17
    static let answeredRowLineHeight: CGFloat = 23.8
    static let answeredRowWeight: CGFloat = 550

    // MARK: - Colours (E: light / dark sRGB)

    /// A scheme-resolved sRGB colour. Alpha is separate from the RGB triple
    /// because the official tokens mix both styles (`black@0.6`,
    /// `ink@0.3`).
    nonisolated struct RGB: Equatable, Sendable {
        let red: Double
        let green: Double
        let blue: Double
        let alpha: Double

        init(_ red: Double, _ green: Double, _ blue: Double, _ alpha: Double = 1) {
            self.red = red
            self.green = green
            self.blue = blue
            self.alpha = alpha
        }
    }

    nonisolated struct Pair: Equatable, Sendable {
        let light: RGB
        let dark: RGB
    }

    /// text10 — primary text and the filled button's background.
    static let text10 = Pair(light: RGB(0.075, 0.075, 0.075),
                             dark: RGB(0.976, 0.976, 0.969))
    /// bg10 — the filled button's foreground.
    static let bg10 = Pair(light: RGB(0.976, 0.976, 0.969),
                           dark: RGB(0.082, 0.082, 0.082))
    /// The card's secondary ink (answers-card header/question, paging row).
    static let secondary = Pair(light: RGB(0, 0, 0, 0.6),
                                dark: RGB(0.765, 0.761, 0.718))
    /// The selected option's badge fill.
    static let selectedBadge = Pair(light: RGB(0.165, 0.471, 0.839),
                                    dark: RGB(0.145, 0.490, 0.878))
    /// The unselected option's ring.
    static let unselectedRing = Pair(light: RGB(0.537, 0.529, 0.506, 0.465),
                                     dark: RGB(1, 1, 1, 0.4))
    /// Option dividers and the input's hairline (`border20 = ink@0.3`).
    static let divider = Pair(light: RGB(0.118, 0.118, 0.114, 0.3),
                              dark: RGB(0.882, 0.878, 0.851, 0.3))
    /// `border30` — the secondary button's stroke.
    static let buttonBorder = Pair(light: RGB(0.118, 0.118, 0.114, 0.15),
                                   dark: RGB(0.882, 0.878, 0.851, 0.15))
    /// text30 — the custom-answer field's foreground.
    static let inputForeground = Pair(light: RGB(0.22, 0.22, 0.208),
                                      dark: RGB(0.765, 0.761, 0.718))
    /// The placeholder has no dark half in the token (U-placeholder-dark).
    static let placeholder = Pair(light: RGB(0.322, 0.318, 0.306),
                                  dark: RGB(0.322, 0.318, 0.306))
    /// The solid card surface (`#FFFFFF` / `#20201F`) — the answered card's
    /// shell and the iOS < 26 fallback (AA ships iOS 26.2, so the glass body
    /// is the only live branch; the pair stays for the answered card).
    static let cardSurface = Pair(light: RGB(1, 1, 1),
                                  dark: RGB(0.125, 0.125, 0.122))
    /// The answered value's ink.
    static let answerInk = Pair(light: RGB(0, 0, 0, 0.9),
                                dark: RGB(1, 1, 1, 0.93))
    /// The floating close button's foreground (`#0B0B0B` / `#F0EFEC`).
    static let closeButtonInk = Pair(light: RGB(0.043, 0.043, 0.043),
                                     dark: RGB(0.941, 0.937, 0.925))
}

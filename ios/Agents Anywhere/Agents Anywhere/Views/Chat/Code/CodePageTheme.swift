import SwiftUI
import UIKit

/// The shared visual-token outlet for the Code page.
///
/// Every visual constant that more than one Code view must agree on lives
/// here, so the official reference (Claude iOS 1.261005.20) has exactly one
/// place to compare against and one place to correct. Geometry private to a
/// single component (for example `WorkingMarkRenderer`'s frame slicing) stays
/// with that component instead.
///
/// Evidence tags follow `docs/perf-6b-c5-code-profile-task.md` §0:
/// - `[E]` read from the official binary / CANONICAL reports.
/// - `[I]` inferred from a screenshot; the source file is cited on each token.
/// - `[U]` not closed statically; the sampled stand-in is labelled as such.
///
/// Font sizes and corner radii are base values under Dynamic Type: views
/// scale them where the official app does. Layout constants (margins,
/// spacing, padding) are fixed points and do not scale.
nonisolated enum CodePageTheme {

    // MARK: - Colour pair

    /// A colour the official UI defines separately per appearance.
    nonisolated struct SchemeColor: Sendable {
        let light: Color
        let dark: Color

        /// Call with the view's `@Environment(\.colorScheme)` value.
        func resolved(for scheme: ColorScheme) -> Color {
            scheme == .dark ? dark : light
        }
    }

    /// UIKit twin of `SchemeColor` for TextKit attribute strings.
    static func uiColor(_ color: SchemeColor) -> UIColor {
        UIColor { traits in
            UIColor(color.resolved(for: traits.userInterfaceStyle == .dark
                                   ? .dark : .light))
        }
    }

    // MARK: - Collapsed tool row

    /// [E] CANONICAL/04-tool-calls.md §6.2 and `DATA/tokens.json`
    /// `typography.mono.size` — `Typography.monospaced` 15 pt.
    static let toolRowFontSize: CGFloat = 15

    /// [E] CANONICAL/04-tool-calls.md §6.2 and `DATA/tokens.json`
    /// `typography.mono.lineHeight` — lineHeight 24.
    static let toolRowLineHeight: CGFloat = 24

    /// [E] CANONICAL/04-tool-calls.md §6.2 and `DATA/tokens.json`
    /// `typography.mono` — weight 400.
    static let toolRowFontWeight: Font.Weight = .regular

    /// [E] `DATA/tokens.json` `typography.mono.textStyle`, also
    /// CANONICAL/04-tool-calls.md §6.2 — the official 15 pt monospaced preset
    /// is built on the footnote text style.
    static let toolRowTextStyle: Font.TextStyle = .footnote

    /// The official fonts, bundled from the official IPA's
    /// `ClaudeFonts_ClaudeFonts.bundle` (registered by `AppFontRegistry`).
    static let sansFontName = "AnthropicSansMobileVariable-TextRegular"
    static let monoFontName = "JetBrainsMono-Regular"

    /// [E] R19 `tool-row-status.md` — the Code page's collapsed row is the
    /// `CollapsedRowButton`: `.padding(.vertical, 6)`, no horizontal padding.
    /// The 8 pt all-sides value belongs to `ToolCallRowContent` (welcome /
    /// expanded card), a different component.
    static let toolRowButtonPadding: CGFloat = 6

    /// [E] R19 `tool-row-status.md` — the verb (proportional run) is
    /// secondary: light `(0.482, 0.475, 0.455)`, dark
    /// `(0.592, 0.584, 0.553)`. The target (monospaced run) is the body ink.
    static let toolRowSecondaryColor: SchemeColor = SchemeColor(
        light: Color(.sRGB, red: 0.482, green: 0.475, blue: 0.455),
        dark: Color(.sRGB, red: 0.592, green: 0.584, blue: 0.553))

    /// Spacing inside a status/tool row. Kept separate from the button
    /// padding: the official evidence fixes the 8 pt padding, not the gap
    /// between the row's glyph and its label.
    static let toolRowSpacing: CGFloat = 6

    // MARK: - Diff indicator (+N / −N)

    /// [E] CANONICAL/04-tool-calls.md §6.2 — 4.5 pt; a `ScaledMetric` in the
    /// official app, so views should scale it with Dynamic Type.
    static let diffIndicatorCornerRadius: CGFloat = 4.5

    /// [E] R19 `tool-row-status.md` — 11 pt / weight 550 / lineHeight 16.
    static let diffIndicatorFontSize: CGFloat = 11
    static let diffIndicatorFontWeight: CGFloat = 550

    /// [E] R19 `tool-row-status.md` — horizontal padding 6 (ScaledMetric).
    static let diffIndicatorHorizontalPadding: CGFloat = 6

    /// [E] R19 `tool-row-status.md` — each half is 18 pt tall (ScaledMetric).
    static let diffIndicatorHeight: CGFloat = 18

    /// [E] R19 `tool-row-status.md` — add ink light
    /// `(0.118, 0.620, 0.235)` / dark `(0.196, 0.843, 0.294)`; the fill is the
    /// same colour at alpha 0.2.
    static let diffIndicatorAddText: SchemeColor = SchemeColor(
        light: Color(.sRGB, red: 0.118, green: 0.620, blue: 0.235),
        dark: Color(.sRGB, red: 0.196, green: 0.843, blue: 0.294))

    static let diffIndicatorAddFill: SchemeColor = SchemeColor(
        light: Color(.sRGB, red: 0.118, green: 0.620, blue: 0.235, opacity: 0.2),
        dark: Color(.sRGB, red: 0.196, green: 0.843, blue: 0.294, opacity: 0.2))

    /// [E] R19 `tool-row-status.md` — remove ink light
    /// `(0.804, 0.125, 0.329)` / dark `(1.000, 0.173, 0.337)`; the fill is the
    /// same colour at alpha 0.2.
    static let diffIndicatorRemoveText: SchemeColor = SchemeColor(
        light: Color(.sRGB, red: 0.804, green: 0.125, blue: 0.329),
        dark: Color(.sRGB, red: 1.000, green: 0.173, blue: 0.337))

    static let diffIndicatorRemoveFill: SchemeColor = SchemeColor(
        light: Color(.sRGB, red: 0.804, green: 0.125, blue: 0.329, opacity: 0.2),
        dark: Color(.sRGB, red: 1.000, green: 0.173, blue: 0.337, opacity: 0.2))

    // MARK: - Diff lines

    /// [E] CANONICAL/04-tool-calls.md §5.2 `DiffView` — added line: light
    /// (0, 0.576, 0), dark (0.047, 0.639, 0.047). The colour paints the 2 pt
    /// leading bar of a diff row, not the row background.
    static let diffLineAdd: SchemeColor = SchemeColor(
        light: Color(.sRGB, red: 0, green: 0.576, blue: 0),
        dark: Color(.sRGB, red: 0.047, green: 0.639, blue: 0.047))

    /// [E] CANONICAL/04-tool-calls.md §5.2 `DiffView` — removed line: light
    /// (0.816, 0.231, 0.231), dark (0.89, 0.286, 0.282). The colour paints the
    /// 2 pt leading bar of a diff row, not the row background.
    static let diffLineRemove: SchemeColor = SchemeColor(
        light: Color(.sRGB, red: 0.816, green: 0.231, blue: 0.231),
        dark: Color(.sRGB, red: 0.89, green: 0.286, blue: 0.282))

    // MARK: - Timeline layout

    /// [E] CANONICAL/05-layout-scroll.md §3.3 — `SessionMessageStyle` default.
    static let interMessageSpacing: CGFloat = 10

    /// [E] CANONICAL/05-layout-scroll.md §3.1 — `rowMargins` is
    /// `(V/2, 16, V/2, 16)` with `V = groupedMessageSpacing ?? interMessageSpacing`,
    /// so the default top side is `interMessageSpacing / 2`.
    static var rowMarginTop: CGFloat { interMessageSpacing / 2 }

    /// [E] CANONICAL/05-layout-scroll.md §3.1 — horizontal margin 16 pt, a
    /// constant-pool value rather than a message-spacing ratio.
    static let rowMarginLeading: CGFloat = 16

    /// [E] CANONICAL/05-layout-scroll.md §3.1 — `V/2`, see `rowMarginTop`.
    static var rowMarginBottom: CGFloat { interMessageSpacing / 2 }

    /// [E] CANONICAL/05-layout-scroll.md §3.1 — horizontal margin 16 pt.
    static let rowMarginTrailing: CGFloat = 16

    /// [E] CANONICAL/05-layout-scroll.md §3.1 — the four sides above, bundled
    /// for the row modifier.
    static var rowMargins: EdgeInsets {
        EdgeInsets(top: rowMarginTop,
                   leading: rowMarginLeading,
                   bottom: rowMarginBottom,
                   trailing: rowMarginTrailing)
    }

    /// [E] CANONICAL/05-layout-scroll.md §3.3 — per-segment vertical padding
    /// (`SessionMessageStyle.segmentVerticalPadding`). Official consumes it
    /// only for a few tool segment kinds (writingDraft / threadSessionCard /
    /// artifactCard / brief / workflow; EVIDENCE/round19/bubble-layout.md:89),
    /// never around a message's text or collapsed-tool blocks.
    static let segmentVerticalPadding: CGFloat = 4

    /// [E] CANONICAL/05-layout-scroll.md §3.4 — Markdown block spacing inside
    /// one rich document (paragraphs / code blocks / tables). It is not the
    /// gap between a message's blocks (EVIDENCE/round19/bubble-layout.md:85).
    static let blockSpacing: CGFloat = 16

    /// The gap between one message's blocks. Official's `TranscriptBlockStack`
    /// passes `style.interBlockSpacing`, which is nil, so SwiftUI picks its
    /// default (`VStack(alignment:.leading, spacing: nil)`, `0x10295b230`;
    /// EVIDENCE/round19/bubble-layout.md:84). The numeric default is blocked
    /// in the ledger, and CANONICAL/05-layout-scroll.md §3.3 asks the client
    /// for an explicit design value instead of relying on it, so this is the
    /// 8 pt SwiftUI default stack spacing.
    static let blockGap: CGFloat = 8

    // MARK: - Markdown text (official Code page)

    /// [E] CANONICAL/06-visuals-assets.md §1.3 — `Typography.regular`:
    /// 17.0 pt, weight 400, unscaled line height 27.2 (`0x1009f5054`,
    /// `0x1009f5168`).
    static let markdownBodySize: CGFloat = 17
    static let markdownLineHeight: CGFloat = 27.2

    /// The bundled faces; the metrics below come from the real face, not from
    /// the system fallback. Anthropic Sans at 17 pt has a 21.25 pt line
    /// height (the system face is 20.29), so the official line spacing is
    /// 27.2 − 21.25 = 5.95.
    static var markdownBodyFont: UIFont {
        MarkdownFontFactory.font(name: sansFontName,
                                 size: markdownBodySize, weight: 400)
    }
    static var markdownMonoFont: UIFont {
        MarkdownFontFactory.font(name: monoFontName,
                                 size: markdownCodeBlockSize, weight: 400)
    }

    /// [E] `ApplyTypography` sets line spacing to
    /// `unscaledLineHeight − the font's natural line height`
    /// (`CANONICAL/06-visuals-assets.md §1.4`), not the line height itself.
    static var markdownLineSpacing: CGFloat {
        max(0, markdownLineHeight - markdownBodyFont.lineHeight)
    }

    /// [E] CANONICAL/06-visuals-assets.md §1.5 — paragraph spacing =
    /// `fontSize × 1.0`.
    static var markdownParagraphSpacing: CGFloat { markdownBodySize }

    /// [E] R19 `typography-inline.md` §3 (correcting the old 13 pt
    /// INFERENCE) — inline code is `Typography.monospaced`: 15.0 / 24.0 /
    /// 400 / `.footnote` (`0x1009f6504`, `0x1009f661c`). 13 pt is the code
    /// card *title* (monoAux), a different role.
    static let markdownInlineCodeSize: CGFloat = 15
    /// [E] R19 `typography-inline.md` §7 — the monospaced preset's unscaled
    /// line height, scaled with `.footnote`.
    static let markdownInlineCodeLineHeight: CGFloat = 24

    /// [E] §1.3 — `monospaced` 15.0 / 24.0 (`0x1009f6504`, `0x1009f661c`);
    /// the Code card and tool rows share this preset.
    static let markdownCodeBlockSize: CGFloat = 15
    static let markdownCodeBlockLineHeight: CGFloat = 24
    /// JetBrains Mono at 15 pt has a 19.8 pt line height (the system mono is
    /// 17.9), so the official 24 pt code line height gives 4.2 pt of leading.
    static var markdownCodeBlockLineSpacing: CGFloat {
        max(0, markdownCodeBlockLineHeight - markdownMonoFont.lineHeight)
    }

    /// [E] R19 `typography-inline.md` §1 — H1 24 / H2 20 / H3–H6 17, all
    /// `.relative`. The heading presets are `HeadingStyles.level1/level2/
    /// default` (`level1` `0x1009f4460`, `level2` `0x1009f4968`, default =
    /// bold `0x1009f53a4`).
    static let markdownHeadings: [CGFloat] = [24, 20, 17]
    /// [E] R19 `typography-inline.md` §1.2 — unscaled line heights 31.2 /
    /// 26.0 / 27.2, each scaled with its own text style.
    static let markdownHeadingLineHeights: [CGFloat] = [31.2, 26, 27.2]
    /// [E] R19 `typography-inline.md` §1.2 — heading weight 550 for every
    /// level (`0x4081300000000000`).
    static let markdownHeadingWeight: CGFloat = 550
    /// [E] R19 `typography-inline.md` §1.2 — paragraph spacing multipliers:
    /// before = 0.4 (default theme), after = 0.6 (Code theme override).
    static let markdownHeadingTopSpacingMultiplier: CGFloat = 0.4
    static let markdownHeadingBottomSpacingMultiplier: CGFloat = 0.6
    /// [E] R19 `typography-inline.md` §6 — Code theme `indentSize = 24.0`.
    static let markdownListIndent: CGFloat = 24

    /// The Code page's Markdown scale: the official regular/mono presets and
    /// spacing multipliers. The reader's compact Chat scheme does not apply
    /// to the Code page.
    static var markdownScale: ChatTypeScale { ChatTypeScale(
        body: markdownBodySize,
        lineSpacing: markdownLineSpacing,
        paragraphSpacing: markdownParagraphSpacing,
        headings: markdownHeadings,
        inlineCodeRatio: markdownInlineCodeSize / markdownBodySize,
        codeBlockRatio: markdownCodeBlockSize / markdownBodySize,
        codeBlockLineSpacingRatio: markdownCodeBlockLineSpacing / markdownCodeBlockSize,
        inlineCodePin: markdownInlineCodeSize,
        codeBlockPin: markdownCodeBlockSize)
    }

    // MARK: - Code card (official Code page)

    /// [E] R19 `chrome-composer.md` §4 — the Code session page background is
    /// `#F9F9F7` light / `#151515` dark (`CodeSessionContent.body
    /// 0x102a68610`, `.background(Color, ignoresSafeAreaEdges: .all)`).
    static let pageBackgroundColor: SchemeColor = SchemeColor(
        light: Color(.sRGB, red: 0.976, green: 0.976, blue: 0.969),
        dark: Color(.sRGB, red: 0.082, green: 0.082, blue: 0.082))

    static let pageBackgroundUIColor = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.082, green: 0.082, blue: 0.082, alpha: 1)
            : UIColor(red: 0.976, green: 0.976, blue: 0.969, alpha: 1)
    }

    /// [E] CANONICAL/06-visuals-assets.md §2.2 — Markdown text
    /// `#131313` / `#F9F9F7` (`0.075` / `0.976,0.976,0.969`).
    static let markdownTextUIColor = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.976, green: 0.976, blue: 0.969, alpha: 1)
            : UIColor(red: 0.075, green: 0.075, blue: 0.075, alpha: 1)
    }

    /// [E] CANONICAL/06-visuals-assets.md §2.2 — inline-code text
    /// `#184F95` light / `#6DA7EC` dark (`0.094,0.31,0.584` /
    /// `0.427,0.655,0.925`). Links use the body text colour.
    static let inlineCodeTextUIColor = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.427, green: 0.655, blue: 0.925, alpha: 1)
            : UIColor(red: 0.094, green: 0.31, blue: 0.584, alpha: 1)
    }

    /// [E] R19 `typography-inline.md` §3 — inline-code chip fill: grey
    /// 0.043 @5% light, white @7.5% dark.
    static let inlineCodeChipFillUIColor = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 1, green: 1, blue: 1, alpha: 0.075)
            : UIColor(red: 0.043, green: 0.043, blue: 0.043, alpha: 0.05)
    }

    /// [E] R19 `typography-inline.md` §3 — chip stroke:
    /// `(0.118,0.118,0.114)@15%` light / `(0.882,0.878,0.851)@15%` dark.
    static let inlineCodeChipStrokeUIColor = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.882, green: 0.878, blue: 0.851, alpha: 0.15)
            : UIColor(red: 0.118, green: 0.118, blue: 0.114, alpha: 0.15)
    }

    /// [E] R19 `typography-inline.md` §3 — 6.4 pt radius, 4 pt horizontal
    /// padding per side, 1/displayScale stroke.
    static let inlineCodeChipCornerRadius: CGFloat = 6.4
    static let inlineCodeChipHorizontalPadding: CGFloat = 4
    /// UNKNOWN: the official vertical padding has no constant; the chip is
    /// drawn from the font's typographic bounds (`§3`, `§10` #4). 0 is the
    /// minimal symmetric value.
    static let inlineCodeChipVerticalPadding: CGFloat = 0

    /// [E] R19 `typography-inline.md` §5 — table header fill: pure white
    /// light, `(0.102,0.102,0.098)` dark.
    static let tableHeaderFillUIColor = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.102, green: 0.102, blue: 0.098, alpha: 1)
            : UIColor(red: 1, green: 1, blue: 1, alpha: 1)
    }

    /// [E] R19 `typography-inline.md` §5 — table border and row lines:
    /// grey 0.043 @10% light, white @10% dark; 1/displayScale wide.
    static let tableBorderUIColor = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 1, green: 1, blue: 1, alpha: 0.10)
            : UIColor(red: 0.043, green: 0.043, blue: 0.043, alpha: 0.10)
    }

    /// [E] R19 `typography-inline.md` §5 — 12 pt horizontal / 8 pt vertical
    /// cell padding (`0x1042cba20` / `0x1042cba18`).
    static let tableCellPaddingHorizontal: CGFloat = 12
    static let tableCellPaddingVertical: CGFloat = 8

    /// [E] part-ac M2.1 — `blockquoteBarWidth = 2.0`; §2.2 — the bar shares
    /// the text base RGB at 0.15 alpha.
    static let quoteBarWidth: CGFloat = 2
    static let quoteBarUIColor = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.882, green: 0.878, blue: 0.851, alpha: 0.15)
            : UIColor(red: 0.118, green: 0.118, blue: 0.114, alpha: 0.15)
    }

    /// [E] §2.3 — card fill `#FFFFFF` light / `#20201F` dark.
    static let codeCardFillUIColor = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.125, green: 0.125, blue: 0.122, alpha: 1)
            : UIColor(red: 1, green: 1, blue: 1, alpha: 1)
    }

    /// [E] §2.3 — border/divider `0.118,0.118,0.114` / `0.882,0.878,0.851`
    /// at 0.3 alpha.
    static let codeCardBorderUIColor = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.882, green: 0.878, blue: 0.851, alpha: 0.3)
            : UIColor(red: 0.118, green: 0.118, blue: 0.114, alpha: 0.3)
    }

    /// [E] R19 `code-card-highlighting.md` — the title ink is the secondary
    /// grey `#7B7974` light / `#97958D` dark, not the body ink.
    static let codeCardTitleUIColor = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.592, green: 0.584, blue: 0.553, alpha: 1)
            : UIColor(red: 0.482, green: 0.475, blue: 0.455, alpha: 1)
    }

    /// [E] R19 `code-card-highlighting.md` — the code body's default ink is
    /// syntax-theme index 0: `#383A42` light / `#ABB2BF` dark.
    static let codeCardTextUIColor = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.667, green: 0.698, blue: 0.749, alpha: 1)
            : UIColor(red: 0.220, green: 0.227, blue: 0.259, alpha: 1)
    }

    /// The official highlight.js 11.11.2 theme: nine sRGB colours, one table
    /// for the whole app (`0x104230194` light / `0x1042301b8` dark,
    /// R19 code-card-highlighting.md).
    static let syntaxDefault: SchemeColor = SchemeColor(
        light: Color(.sRGB, red: 0.220, green: 0.227, blue: 0.259),
        dark: Color(.sRGB, red: 0.667, green: 0.698, blue: 0.749))
    static let syntaxComment: SchemeColor = SchemeColor(
        light: Color(.sRGB, red: 0.627, green: 0.631, blue: 0.655),
        dark: Color(.sRGB, red: 0.361, green: 0.388, blue: 0.439))
    static let syntaxKeyword: SchemeColor = SchemeColor(
        light: Color(.sRGB, red: 0.651, green: 0.149, blue: 0.643),
        dark: Color(.sRGB, red: 0.776, green: 0.471, blue: 0.867))
    static let syntaxRed: SchemeColor = SchemeColor(
        light: Color(.sRGB, red: 0.894, green: 0.337, blue: 0.286),
        dark: Color(.sRGB, red: 0.878, green: 0.424, blue: 0.459))
    static let syntaxCyan: SchemeColor = SchemeColor(
        light: Color(.sRGB, red: 0.004, green: 0.518, blue: 0.733),
        dark: Color(.sRGB, red: 0.337, green: 0.714, blue: 0.761))
    static let syntaxGreen: SchemeColor = SchemeColor(
        light: Color(.sRGB, red: 0.314, green: 0.631, blue: 0.310),
        dark: Color(.sRGB, red: 0.596, green: 0.765, blue: 0.475))
    static let syntaxOrange: SchemeColor = SchemeColor(
        light: Color(.sRGB, red: 0.596, green: 0.408, blue: 0.004),
        dark: Color(.sRGB, red: 0.820, green: 0.604, blue: 0.400))
    static let syntaxBlue: SchemeColor = SchemeColor(
        light: Color(.sRGB, red: 0.251, green: 0.471, blue: 0.949),
        dark: Color(.sRGB, red: 0.380, green: 0.682, blue: 0.933))
    static let syntaxYellow: SchemeColor = SchemeColor(
        light: Color(.sRGB, red: 0.757, green: 0.518, blue: 0.004),
        dark: Color(.sRGB, red: 0.902, green: 0.753, blue: 0.482))

    /// [E] §1.3-1.6 and part-ac M4 — 44 pt header (a ScaledMetric in the
    /// official app), 24 pt continuous radius, 13 pt monoAux title at weight
    /// 400.
    static var codeCardStyle: AssistantCodeCardStyle {
        AssistantCodeCardStyle(
            headerHeight: 44,
            // [E] DATA/tokens.json `codeCard.body.textContainerInset` 16.0
            // (`0x100a501a4` → setTextContainerInset); the header HStack's
            // `.padding(16)` is the same value (`0x100a500d4`).
            contentPadding: 16,
            cornerRadius: 24,
            fillColor: codeCardFillUIColor,
            borderColor: codeCardBorderUIColor,
            titleColor: codeCardTitleUIColor,
            titleFontSize: 13,
            titleWeight: .regular,
            textColor: codeCardTextUIColor,
            // [E] R19 `typography-inline.md` §1.2 / §12 — the target build's
            // heading family is Anthropic Sans (the 2026-03 Serif screenshots
            // predate the family switch), weight 550; headings are not the
            // Serif face any more.
            fonts: MarkdownFontStyle(
                bodyName: sansFontName,
                bodyItalicName: "AnthropicSansMobileVariable-TextRegularItalic",
                headingName: sansFontName,
                headingItalicName: "AnthropicSansMobileVariable-TextRegularItalic",
                monoName: monoFontName,
                bodyWeight: 400,
                boldWeight: 550,
                headingWeight: markdownHeadingWeight),
            quoteBarWidth: quoteBarWidth,
            quoteBarColor: quoteBarUIColor,
            // [E] CANONICAL/05-layout-scroll.md §3.4 — the official Markdown
            // renderer uses one 16 pt block gap (`0x10170a9c8`).
            markdownBlockSpacing: blockSpacing,
            // [E] R19 `typography-inline.md` §3 — the chip painted behind an
            // inline-code run.
            inlineCodeChip: AssistantInlineCodeChipStyle(
                cornerRadius: inlineCodeChipCornerRadius,
                horizontalPadding: inlineCodeChipHorizontalPadding,
                verticalPadding: inlineCodeChipVerticalPadding,
                fillColor: inlineCodeChipFillUIColor,
                strokeColor: inlineCodeChipStrokeUIColor),
            // [E] R19 `typography-inline.md` §5 — 12 / 8 padding, white /
            // #1A1A19 header fill, grey 0.043 @10% / white @10% border.
            tableCellPaddingHorizontal: tableCellPaddingHorizontal,
            tableCellPaddingVertical: tableCellPaddingVertical,
            tableHeaderFillColor: tableHeaderFillUIColor,
            tableBorderColor: tableBorderUIColor)
    }

    /// [E] CANONICAL/05-layout-scroll.md §3.2 — default row bottom padding is
    /// `interMessageSpacing - (groupedMessageSpacing ?? interMessageSpacing)`.
    static let rowBottomPadding: CGFloat = 0

    // MARK: - Working mark

    /// [E] CANONICAL/20-working-mark.md §5 — the mark's fixed 20 x 20 box.
    static let workingMarkSize: CGFloat = 20

    /// [E] CANONICAL/20-working-mark.md §1 — the flipbook runs at 30 fps.
    static let workingMarkFrameRate: Double = 30

    /// [E] CANONICAL/20-working-mark.md §1 — think body, `_in` 16 frames.
    static let workingMarkThinkOpeningFrames: Int = 16

    /// [E] CANONICAL/20-working-mark.md §1 — think body, `_loop` 110 frames.
    static let workingMarkThinkLoopFrames: Int = 110

    /// [E] CANONICAL/20-working-mark.md §1 — think body, `_out` 15 frames.
    static let workingMarkThinkClosingFrames: Int = 15

    /// [E] CANONICAL/20-working-mark.md §1 — 16 / 30 s, about 0.53 s.
    static var workingMarkThinkOpeningDuration: Double {
        Double(workingMarkThinkOpeningFrames) / workingMarkFrameRate
    }

    /// [E] CANONICAL/20-working-mark.md §1 — 110 / 30 s, about 3.67 s.
    static var workingMarkThinkLoopDuration: Double {
        Double(workingMarkThinkLoopFrames) / workingMarkFrameRate
    }

    /// [E] CANONICAL/20-working-mark.md §1 — 15 / 30 s, 0.50 s.
    static var workingMarkThinkClosingDuration: Double {
        Double(workingMarkThinkClosingFrames) / workingMarkFrameRate
    }

    /// [E] CANONICAL/20-working-mark.md §2 — `Spring(duration: 0.5, bounce: 0)`.
    static let workingMarkSpringResponse: Double = 0.5

    /// [E] CANONICAL/20-working-mark.md §2 — bounce 0 (damping 1.0).
    static let workingMarkSpringBounce: Double = 0

    /// [E] CANONICAL/20-working-mark.md §2 — the spring above as a SwiftUI
    /// animation, for glide and the seat's transform-to-identity.
    static var workingMarkSpring: Animation {
        .spring(duration: workingMarkSpringResponse, bounce: workingMarkSpringBounce)
    }

    /// [E] CANONICAL/20-working-mark.md §6 — the exit animation group lasts
    /// 0.4 s.
    static let workingMarkExitDuration: Double = 0.4

    /// [E] CANONICAL/20-working-mark.md §6 — exit shrinks scale to 0.01.
    static let workingMarkExitScale: CGFloat = 0.01

    /// [I] CANONICAL/20-working-mark.md §6 — the exit keyframe values end at
    /// opacity 0 (decoded as `[s8, s8, 0]`; the report marks the values
    /// inference).
    static let workingMarkExitOpacity: Double = 0

    /// [I] `/home/ubuntu/aa-test/working_mark_crop.png` — the three dots'
    /// interiors sample to `#CF7D5D` / `#D2785E` / `#CE775B` after the photo's
    /// JPEG shift. The dark reference
    /// `/home/ubuntu/aa-test/claude-ios-re/REFERENCES/round2/device/code_session_dark_de_1170x2532.png`
    /// carries the exact brand orange `#D97757` in the mark's dot (30 identical
    /// pixels), so both schemes use that value. The official flipbook may bake
    /// colour per frame; this is the tint AA draws with until frame art exists.
    static let workingMarkTint: SchemeColor = SchemeColor(
        light: Color(.sRGB, red: 0.851, green: 0.467, blue: 0.341),
        dark: Color(.sRGB, red: 0.851, green: 0.467, blue: 0.341))

    // MARK: - Running status line (`... Computing...`)

    /// [I] `/home/ubuntu/.agents-anywhere-moonveil/attachments/sess_W6JkIc1Jh6PwbQ/file_Daj1ZqByuk14ZB0x-Photo-9F31958B.jpeg`
    /// (2026-10-22) — the ink box is 44 px = 14.67 pt from cap top to the
    /// 'p'/'g' descender. The 17 pt body in the same capture measures a
    /// 0.745 em ascender, so 14.67 / (0.745 + ~0.21) = 15.3 pt; stored as
    /// 15 pt. Official size is [U].
    static let runningStatusFontSize: CGFloat = 15

    /// [E] R19 `tool-row-status.md` — working status text: light
    /// `(0.322, 0.318, 0.306)`, dark `(0.765, 0.761, 0.718)`.
    static let runningStatusColor: SchemeColor = SchemeColor(
        light: Color(.sRGB, red: 0.322, green: 0.318, blue: 0.306),
        dark: Color(.sRGB, red: 0.765, green: 0.761, blue: 0.718))

    /// [E] R19 `tool-row-status.md` — the working row is
    /// `HStack(spacing: 4)` with the 20×20 mark and the text.
    static let workingStatusSpacing: CGFloat = 4

    /// [E] CANONICAL/20-working-mark.md §4 — the connecting verb list rotates
    /// once a second (`PeriodicTimelineSchedule(by: 1.0)`).
    static let runningStatusVerbRotationInterval: Double = 1.0

    // MARK: - User message bubble

    // [E] EVIDENCE/round18/user-row-and-action-bar.md §1.3–§1.5.

    /// [E] round18 §1.3 — light `#F0EFEC` (0.941, 0.937, 0.925), dark
    /// `#2C2C2A` (0.173, 0.173, 0.165), sRGB dynamic colour.
    static let userBubbleFill: SchemeColor = SchemeColor(
        light: Color(.sRGB, red: 0.941, green: 0.937, blue: 0.925),
        dark: Color(.sRGB, red: 0.173, green: 0.173, blue: 0.165))

    /// [E] round18 §1.3 — the Markdown theme's body ink, `#131313` light /
    /// `#F9F9F7` dark. The bubble does not reuse the app accent.
    static let userBubbleText: SchemeColor = SchemeColor(
        light: Color(.sRGB, red: 0.0745, green: 0.0745, blue: 0.0745),
        dark: Color(.sRGB, red: 0.9765, green: 0.9765, blue: 0.9686))

    /// [E] round18 §1.2 — 24 pt `RoundedRectangle` with the `.continuous`
    /// style; the content shape is a separate height-capped shape and does not
    /// affect the fill.
    static let userBubbleCornerRadius: CGFloat = 24

    /// [E] round18 §1.2 — `.padding(.horizontal, 16)`.
    static let userBubbleHorizontalPadding: CGFloat = 16

    /// [E] round18 §1.2 — `.padding(.vertical, 12)`.
    static let userBubbleVerticalPadding: CGFloat = 12

    /// [E] round18 §1.4 — the opposite-side gutter is 36 pt; a short bubble
    /// right-aligns against the row's trailing margin.
    static let userBubbleLeadingGutter: CGFloat = 36

    /// [E] round18 §1.4 — row inner max width = column − 36 pt gutter.
    /// Kept as a spacing token for stacked pieces.
    static let userBubbleSpacing: CGFloat = 8

    /// [E] round18 §0.7 + R19 `bubble-layout.md` — body copy is 17 pt at a
    /// 27.2 pt line height (`.body`). Line spacing is the delta over the real
    /// face's natural line box: Anthropic Sans at 17 pt is 21.25 pt, so
    /// 27.2 − 21.25 = 5.95 (the system face's 20.29 would give 6.91).
    static var userBubbleLineSpacing: CGFloat { markdownLineSpacing }

    // MARK: - Dynamic Type (shared by renderer and measurer)

    /// Resolves the official Code-page type scale for one trait collection.
    ///
    /// Every preset is `.relative` in the official app
    /// (`EVIDENCE/round19/typography-inline.md` §7): body 17 → `.body`,
    /// mono 15 → `.footnote`, aux 13 → `.caption`, H1 24 → `.title3`,
    /// H2 20 → `.headline`, H3+ 17 → `.body`. Line heights use the same
    /// metrics for 27.2 / 24 / 31.2 / 26 and the paragraph leading is the
    /// delta over the resolved face's natural line box — never the unscaled
    /// 27.2 (CANONICAL/06-visuals-assets.md §1.4).
    ///
    /// The renderer (`CodeMarkdownTextLeaf`, from SwiftUI's `dynamicTypeSize`)
    /// and the measurer (`CodeMessageHeightMeasurer`, from the cell's
    /// `UITraitCollection`) both call this one function, so a row cannot
    /// resize itself after the first fit.
    /// Main-actor isolated because it builds `UIFont`/`UIFontMetrics`; every
    /// caller (the SwiftUI leaf, the user bubble and the height measurer) is
    /// already on the main actor.
    @MainActor
    static func codePageTypography(base: TimelineTypographySnapshot,
                                   traits: UITraitCollection?) -> TimelineTypographySnapshot {
        let bodyMetrics = UIFontMetrics(forTextStyle: .body)
        let bodySize = bodyMetrics.scaledValue(
            for: markdownBodySize, compatibleWith: traits)
        let bodyLineHeight = bodyMetrics.scaledValue(
            for: markdownLineHeight, compatibleWith: traits)
        let bodyFont = MarkdownFontFactory.font(
            name: sansFontName, size: bodySize, weight: 400)
        let bodyLineSpacing = max(0, bodyLineHeight - bodyFont.lineHeight)

        let title3 = UIFontMetrics(forTextStyle: .title3)
        let headline = UIFontMetrics(forTextStyle: .headline)
        let headingSizes = [
            title3.scaledValue(for: markdownHeadings[0], compatibleWith: traits),
            headline.scaledValue(for: markdownHeadings[1], compatibleWith: traits),
            bodyMetrics.scaledValue(for: markdownHeadings[2], compatibleWith: traits),
        ]
        let headingLineHeights = [
            title3.scaledValue(for: markdownHeadingLineHeights[0], compatibleWith: traits),
            headline.scaledValue(for: markdownHeadingLineHeights[1], compatibleWith: traits),
            bodyMetrics.scaledValue(for: markdownHeadingLineHeights[2], compatibleWith: traits),
        ]

        let monoMetrics = UIFontMetrics(forTextStyle: .footnote)
        let monoSize = monoMetrics.scaledValue(
            for: markdownInlineCodeSize, compatibleWith: traits)
        let monoLineHeight = monoMetrics.scaledValue(
            for: markdownInlineCodeLineHeight, compatibleWith: traits)
        let monoFont = MarkdownFontFactory.font(
            name: monoFontName, size: monoSize, weight: 400)
        let monoLineSpacing = max(0, monoLineHeight - monoFont.lineHeight)

        var resolved = base
        resolved.body = bodySize
        resolved.lineSpacing = bodyLineSpacing
        // paragraphSpacingMultiplier = 1.0, resolved against the scaled size.
        resolved.paragraphSpacing = bodySize
        resolved.headings = headingSizes
        resolved.inlineCodeRatio = bodySize > 0 ? monoSize / bodySize : base.inlineCodeRatio
        resolved.codeBlockRatio = bodySize > 0 ? monoSize / bodySize : base.codeBlockRatio
        resolved.codeBlockLineSpacingRatio = monoSize > 0
            ? monoLineSpacing / monoSize
            : base.codeBlockLineSpacingRatio
        resolved.inlineCodePin = monoSize
        resolved.codeBlockPin = monoSize
        if let category = traits?.preferredContentSizeCategory {
            resolved.dynamicType = category.rawValue
        }
        resolved.codeMarkdownRoles = CodePageMarkdownRoles(
            headingSizes: headingSizes,
            headingLineHeights: headingLineHeights,
            headingTopSpacingMultiplier: markdownHeadingTopSpacingMultiplier,
            headingBottomSpacingMultiplier: markdownHeadingBottomSpacingMultiplier,
            bodyLineSpacing: bodyLineSpacing,
            inlineCodeSize: monoSize,
            inlineCodeLineSpacing: monoLineSpacing,
            listIndent: markdownListIndent,
            // Item pitch = paragraph-after = body size × 1.0.
            listSpacing: bodySize)
        return resolved
    }
}

extension TimelineTypographySnapshot {
    /// The Code page's resolved type scale for a UIKit trait collection (the
    /// measurement side). Main-actor isolated with the font factory.
    @MainActor
    func resolvedForCodePage(traits: UITraitCollection?) -> TimelineTypographySnapshot {
        CodePageTheme.codePageTypography(base: self, traits: traits)
    }

    /// The same scale from a `UIContentSizeCategory` (the SwiftUI render side,
    /// which maps its `dynamicTypeSize` onto this category).
    @MainActor
    func resolvedForCodePage(category: UIContentSizeCategory) -> TimelineTypographySnapshot {
        resolvedForCodePage(
            traits: UITraitCollection(preferredContentSizeCategory: category))
    }
}

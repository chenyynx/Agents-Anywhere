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

    /// [E] `EVIDENCE/typography-r8.md` §3.2 — `ToolCallRowButton` label
    /// padding is 8 pt on all four sides (`EdgeInsets._all(8.0)`). The older
    /// CANONICAL/04 §6.2 note of 6 pt describes `CollapsedRowButton`, a
    /// different component; the Code page's collapsed tool row uses the 8 pt
    /// button.
    static let toolRowButtonPadding: CGFloat = 8

    /// Spacing inside a status/tool row. Kept separate from the button
    /// padding: the official evidence fixes the 8 pt padding, not the gap
    /// between the row's glyph and its label.
    static let toolRowSpacing: CGFloat = 6

    // MARK: - Diff indicator (+N / −N)

    /// [E] CANONICAL/04-tool-calls.md §6.2 — 4.5 pt; a `ScaledMetric` in the
    /// official app, so views should scale it with Dynamic Type.
    static let diffIndicatorCornerRadius: CGFloat = 4.5

    /// [I] `/home/ubuntu/.agents-anywhere-moonveil/attachments/sess_W6JkIc1Jh6PwbQ/file_Daj1ZqByuk14ZB0x-Photo-9F31958B.jpeg`
    /// (2026-10-22) — glyph cap height is 22-23 px at 3x (7.3-7.7 pt); the
    /// mono face's 0.70 cap ratio puts the type at 11 pt, the caption2 preset.
    /// Official size is [U].
    static let diffIndicatorFontSize: CGFloat = 11

    /// [I] `/home/ubuntu/.agents-anywhere-moonveil/attachments/sess_W6JkIc1Jh6PwbQ/file_Daj1ZqByuk14ZB0x-Photo-9F31958B.jpeg`
    /// (2026-10-22) — the pill measures 75.2 px = 25.1 pt wide (50% edge on
    /// the fill colour; +1 and -1 agree within 0.1 pt). The padding wraps the
    /// Text line box, not the glyph ink: at 11 pt the mono advance is
    /// 2 x 0.6 em = 13.2 pt, so (25.1 - 13.2) / 2 = 6.0 pt per side.
    static let diffIndicatorHorizontalPadding: CGFloat = 6

    /// [I] `/home/ubuntu/.agents-anywhere-moonveil/attachments/sess_W6JkIc1Jh6PwbQ/file_Daj1ZqByuk14ZB0x-Photo-9F31958B.jpeg`
    /// (2026-10-22) — the pill measures 52.8 px = 17.6 pt tall (same 50% edge;
    /// +1 52.79 px, -1 52.71 px). The padding wraps the Text line box, not the
    /// glyph ink: an 11 pt mono line box is 13.1 pt, so
    /// (17.6 - 13.1) / 2 = 2.2 pt per side.
    static let diffIndicatorVerticalPadding: CGFloat = 2.2

    /// [I] `/home/ubuntu/.agents-anywhere-moonveil/attachments/sess_W6JkIc1Jh6PwbQ/file_Daj1ZqByuk14ZB0x-Photo-9F31958B.jpeg`
    /// (2026-10-22) — light fill `#D1E6D3`. No dark capture, so the sampled
    /// value is reused until one lands.
    static let diffIndicatorAddFill: SchemeColor = SchemeColor(
        light: Color(.sRGB, red: 0.820, green: 0.902, blue: 0.827),
        dark: Color(.sRGB, red: 0.820, green: 0.902, blue: 0.827))

    /// [I] `/home/ubuntu/.agents-anywhere-moonveil/attachments/sess_W6JkIc1Jh6PwbQ/file_Daj1ZqByuk14ZB0x-Photo-9F31958B.jpeg`
    /// (2026-10-22) — light glyph `#487F4E` (darkest ink core).
    static let diffIndicatorAddText: SchemeColor = SchemeColor(
        light: Color(.sRGB, red: 0.282, green: 0.498, blue: 0.306),
        dark: Color(.sRGB, red: 0.282, green: 0.498, blue: 0.306))

    /// [I] `/home/ubuntu/.agents-anywhere-moonveil/attachments/sess_W6JkIc1Jh6PwbQ/file_Daj1ZqByuk14ZB0x-Photo-9F31958B.jpeg`
    /// (2026-10-22) — light fill `#E9CED5`. No dark capture, so the sampled
    /// value is reused until one lands.
    static let diffIndicatorRemoveFill: SchemeColor = SchemeColor(
        light: Color(.sRGB, red: 0.914, green: 0.808, blue: 0.835),
        dark: Color(.sRGB, red: 0.914, green: 0.808, blue: 0.835))

    /// [I] `/home/ubuntu/.agents-anywhere-moonveil/attachments/sess_W6JkIc1Jh6PwbQ/file_Daj1ZqByuk14ZB0x-Photo-9F31958B.jpeg`
    /// (2026-10-22) — light glyph `#882941` (darkest ink core).
    static let diffIndicatorRemoveText: SchemeColor = SchemeColor(
        light: Color(.sRGB, red: 0.533, green: 0.161, blue: 0.255),
        dark: Color(.sRGB, red: 0.533, green: 0.161, blue: 0.255))

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
    /// (`SessionMessageStyle.segmentVerticalPadding`).
    static let segmentVerticalPadding: CGFloat = 4

    /// [E] CANONICAL/05-layout-scroll.md §3.4 — Markdown block spacing.
    static let blockSpacing: CGFloat = 16

    // MARK: - Markdown text (official Code page)

    /// [E] CANONICAL/06-visuals-assets.md §1.3 — `Typography.regular`:
    /// 17.0 pt, weight 400, unscaled line height 27.2 (`0x1009f5054`,
    /// `0x1009f5168`).
    static let markdownBodySize: CGFloat = 17
    static let markdownLineHeight: CGFloat = 27.2

    /// [E] `ApplyTypography` sets line spacing to
    /// `unscaledLineHeight − the font's natural line height`
    /// (`CANONICAL/06-visuals-assets.md §1.4`), not the line height itself.
    static var markdownLineSpacing: CGFloat {
        max(0, markdownLineHeight
            - UIFont.systemFont(ofSize: markdownBodySize).lineHeight)
    }

    /// [E] CANONICAL/06-visuals-assets.md §1.5 — paragraph spacing =
    /// `fontSize × 1.0`.
    static var markdownParagraphSpacing: CGFloat { markdownBodySize }

    /// [E] §1.3 — `monoAux` 13.0 / 20.8, the inline-code preset
    /// (`0x1009f69e8`).
    static let markdownInlineCodeSize: CGFloat = 13

    /// [E] §1.3 — `monospaced` 15.0 / 24.0 (`0x1009f6504`, `0x1009f661c`);
    /// the Code card and tool rows share this preset.
    static let markdownCodeBlockSize: CGFloat = 15
    static let markdownCodeBlockLineHeight: CGFloat = 24
    static var markdownCodeBlockLineSpacing: CGFloat {
        max(0, markdownCodeBlockLineHeight
            - UIFont.monospacedSystemFont(ofSize: markdownCodeBlockSize,
                                          weight: .regular).lineHeight)
    }

    /// [U] The official heading point sizes were not extracted: the Typography
    /// table in `CANONICAL/06-visuals-assets.md §1.3` lists regular/bold/
    /// italic/mono/monoAux only. These keep AA's heading proportions above the
    /// official body until the presets are read.
    static let markdownHeadings: [CGFloat] = [23, 21, 18]

    /// The Code page's Markdown scale: the official regular/mono presets and
    /// spacing multipliers. The reader's compact Chat scheme does not apply
    /// to the Code page.
    static let markdownScale = ChatTypeScale(
        body: markdownBodySize,
        lineSpacing: markdownLineSpacing,
        paragraphSpacing: markdownParagraphSpacing,
        headings: markdownHeadings,
        inlineCodeRatio: markdownInlineCodeSize / markdownBodySize,
        codeBlockRatio: markdownCodeBlockSize / markdownBodySize,
        codeBlockLineSpacingRatio: markdownCodeBlockLineSpacing / markdownCodeBlockSize,
        inlineCodePin: markdownInlineCodeSize,
        codeBlockPin: markdownCodeBlockSize)

    // MARK: - Code card (official Code page)

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

    /// [E] §1.3-1.6 and part-ac M4 — 44 pt header (a ScaledMetric in the
    /// official app), 24 pt continuous radius, 13 pt monoAux title at weight
    /// 400.
    static var codeCardStyle: AssistantCodeCardStyle {
        AssistantCodeCardStyle(
            headerHeight: 44,
            contentPadding: 14,
            cornerRadius: 24,
            fillColor: codeCardFillUIColor,
            borderColor: codeCardBorderUIColor,
            titleColor: markdownTextUIColor,
            titleFontSize: 13,
            titleWeight: .regular,
            textColor: markdownTextUIColor)
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

    /// Light: [I] `/home/ubuntu/.agents-anywhere-moonveil/attachments/sess_W6JkIc1Jh6PwbQ/file_Daj1ZqByuk14ZB0x-Photo-9F31958B.jpeg`
    /// (2026-10-22) — the darkest ink core averages `#9D6E5D` (darkest 2% of
    /// glyph pixels, warm brown; JPEG noise about +/-2 per channel), stored as
    /// `#9D6E5C`.
    /// Dark: [U] `/home/ubuntu/aa-test/claude-ios-re/REFERENCES/round2/device/code_session_dark_de_1170x2532.png`
    /// — the status line is neutral grey there, not warm brown; its core
    /// cluster samples to `#6D6C67` (temporary neutral-grey sample; the capture
    /// carries a ghost overlay, so the exact official value stays [U]).
    static let runningStatusColor: SchemeColor = SchemeColor(
        light: Color(.sRGB, red: 0.616, green: 0.431, blue: 0.361),
        dark: Color(.sRGB, red: 0.427, green: 0.424, blue: 0.404))

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

    /// [E] round18 §0.7 — body copy is 17 pt at a 27.2 pt line height
    /// (`.body`). SwiftUI line spacing is the delta over the system line
    /// box (~20.3 pt at 17 pt).
    static let userBubbleLineSpacing: CGFloat = 6.9
}

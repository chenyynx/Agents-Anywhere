import CoreGraphics

/// Visual metrics for the chat surface, matched against the Claude iOS app
/// reference screenshots (2026-10-17). Values were read per-pixel from 3x
/// captures (1179×2556 = 393pt wide).
///
/// Every value here is a *design constant*, not a computed ratio. Textual
/// expresses spacing as a multiple of the font size (`FontScaled`), so the
/// helpers at the bottom convert a point value into the ratio that produces it
/// at the base font size. When Dynamic Type grows the font, those measurements
/// grow with it — the reference is a snapshot of one size, not a demand to
/// freeze the layout at 14pt.
nonisolated enum ChatMetrics {
    /// The reference was captured at this body size. Ratios are derived from
    /// it, so a future change here rescales every spacing constant at once.
    static let referenceBodySize: CGFloat = 14

    // MARK: Body text

    /// Running text. `[measured]` 26 CJK glyphs per 360pt column, verified at
    /// 42px glyph pitch in the 393pt reference capture.
    static let bodySize: CGFloat = 14
    /// Line box height. `[measured]` 66px baseline pitch.
    static let bodyLineHeight: CGFloat = 22
    /// Textual adds space *between* line fragments, so the extra is the line
    /// height minus the font's own leading.
    static var bodyLineSpacing: CGFloat { bodyLineHeight - bodySize }

    /// Inline code. `[calibrated]` back-derived from the character advance
    /// width; the reference set it slightly *larger* than running text.
    static let inlineCodeSize: CGFloat = 14.8

    // MARK: Blocks

    /// `[measured]` paragraph-to-paragraph pitch is 42pt = 22 line + 20 gap.
    static let paragraphSpacing: CGFloat = 20
    /// `[measured]` space around a fenced code block.
    static let codeBlockMargin: CGFloat = 15.5
    /// `[measured]` extra space after a list's last item.
    static let listBottomSpacing: CGFloat = 20
    /// `[measured]` 24pt between items minus the 22pt line box.
    static let listItemSpacing: CGFloat = 2
    /// `[measured]` text offset inside a list item.
    static let listTextIndent: CGFloat = 24.4
    /// `[measured]` bullet diameter and centre offset from the item edge.
    static let bulletSize: CGFloat = 5
    static let bulletCenterX: CGFloat = 9.9
    /// Gap between the bullet's trailing edge and the item text.
    static var listMarkerGap: CGFloat {
        listTextIndent - (bulletCenterX + bulletSize / 2)
    }
    static var listMarkerGapRatio: CGFloat { scaled(listMarkerGap) }

    // MARK: Code block

    static let blockCodeSize: CGFloat = 12.3
    /// `[measured]` 43px baseline pitch.
    static let blockCodeLineHeight: CGFloat = 14.33
    static var blockCodeLineSpacing: CGFloat { blockCodeLineHeight - blockCodeSize }
    static let codeRadius: CGFloat = 23
    static let codeBorder: CGFloat = 1
    static let codePadTop: CGFloat = 10
    static let codePadHorizontal: CGFloat = 16
    static let codePadBottom: CGFloat = 16
    static let codeHeaderHeight: CGFloat = 22
    static let codeHeaderToBody: CGFloat = 10.8
    static let codeLabelSize: CGFloat = 13

    // MARK: Table

    /// `[derived]` no table appeared in the reference captures; these follow
    /// the same greyscale and border rules as the code block.
    static let tableRadius: CGFloat = 12
    static let tableCellPadHorizontal: CGFloat = 12
    static let tableCellPadVertical: CGFloat = 8
    static let tableCellSize: CGFloat = 13
    static let tableCellLineHeight: CGFloat = 18
    /// Ceiling for one content-sized column. Without it a single long cell
    /// would push every other column off screen with no way to reach it; the
    /// cell wraps instead and the table still scrolls sideways.
    static let tableContentWidthCap: CGFloat = 260

    // MARK: User bubble

    /// Horizontal inset from the bubble edge to the text. `[measured]`.
    static let bubblePadHorizontal: CGFloat = 15.5
    /// `[measured]` — the bubble is a single-line capsule whose radius is half
    /// its 41pt height, so the radius follows the height rather than a token.
    static let bubblePadVertical: CGFloat = 9.35
    static let bubbleRadius: CGFloat = 20.35
    /// `[measured]` space below a bubble before the next message.
    static let bubbleBottomGap: CGFloat = 23

    // MARK: Action row

    /// `[measured]` the row's own box height (icons are 12–14pt inside it).
    static let actionRowHeight: CGFloat = 24
    /// `[measured]` from the reply's line box to the action row.
    static let actionRowTopGap: CGFloat = 6
    /// `[measured]` from the action row to the next message.
    static let actionRowBottomGap: CGFloat = 15.5
    static let timestampSize: CGFloat = 12

    // MARK: Layout

    /// `[measured]` text starts 16pt from the screen edge at 393pt wide.
    static let horizontalMargin: CGFloat = 16

    // MARK: - FontScaled bridges

    /// Textual's spacing modifiers take a multiple of the *current* font size.
    /// A design constant in points therefore becomes `points / reference`.
    /// Every helper keeps the reference snapshot at its measured size while
    /// still tracking Dynamic Type.
    static func scaled(_ points: CGFloat) -> CGFloat { points / referenceBodySize }

    static var bodyLineSpacingRatio: CGFloat { scaled(bodyLineSpacing) }
    static var paragraphSpacingRatio: CGFloat { scaled(paragraphSpacing) }
    static var codeBlockMarginRatio: CGFloat { scaled(codeBlockMargin) }
    static var listBottomRatio: CGFloat { scaled(listBottomSpacing) }
    static var codeBlockLineSpacingRatio: CGFloat { scaled(blockCodeLineSpacing) }
    static var codePadLeadingRatio: CGFloat { scaled(12) }
}

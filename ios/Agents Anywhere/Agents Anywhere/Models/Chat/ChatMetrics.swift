import CoreGraphics
import Foundation

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

    /// Running text. `[pp 2026-10-17]` the measured 14pt read a step large on
    /// device, so the body sits under the reference; `[pp 2026-10-18]` the
    /// reader can tune it from Settings.
    ///
    /// Read live rather than cached: the settings sheet changes the value
    /// while the chat is open, and a `static let` would freeze the old size
    /// until relaunch. Ratios keep deriving from `referenceBodySize`, so
    /// tuning the size scales the type without rescaling every spacing
    /// constant out from under the layout.
    static var bodySize: CGFloat { ChatTypeSettings.current.body }
    /// Line box height. `[measured]` 66px baseline pitch at the 14pt reference;
    /// kept in step with `bodySize` so the 8pt of leading scales with the text.
    static var bodyLineHeight: CGFloat { bodySize + bodyLineSpacing }
    /// Textual adds space *between* line fragments, so the extra is the line
    /// height minus the font's own leading. Comes from the active scheme:
    /// AA's preset holds 8pt, moonveil's holds 0.5em.
    static var bodyLineSpacing: CGFloat { ChatTypeSettings.current.lineSpacing }

    /// Inline code. `[calibrated]` back-derived from the character advance
    /// width; the reference set it slightly *larger* than running text. A
    /// scheme may pin its own value; otherwise it keeps that ratio.
    static var inlineCodeSize: CGFloat {
        ChatTypeSettings.current.inlineCode ?? bodySize * 14.8 / referenceBodySize
    }

    // MARK: Blocks

    /// Space between paragraphs. A fixed design constant in both schemes —
    /// AA holds 20, moonveil 12 — so it does not scale with the body.
    static var paragraphSpacing: CGFloat { ChatTypeSettings.current.paragraphSpacing }
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

    /// Fenced code. A scheme may pin its own value (moonveil uses 0.85 of the
    /// body); otherwise it keeps AA's ratio against the 14pt reference.
    static var blockCodeSize: CGFloat {
        ChatTypeSettings.current.codeBlock ?? bodySize * 12.3 / referenceBodySize
    }
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
    static let tableRadius: CGFloat = 12  // `[pp 2026-10-18]` card corner: smaller than the code card so a table reads as lighter than a code block
    static let tableCellPadHorizontal: CGFloat = 12
    /// moonveil's table cell vertical padding; one point roomier than the
    /// first pass so wrapped cells breathe.
    static let tableCellPadVertical: CGFloat = 10
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

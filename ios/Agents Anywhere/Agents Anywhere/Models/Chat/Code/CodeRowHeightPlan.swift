import Foundation

/// The exact vertical arithmetic of one Code message row.
///
/// `CodeMessageRowView` stacks rendered rows with `interMessageSpacing`
/// between them (10 pt, the pair of 5 pt row margins). Each row stacks its
/// blocks with `blockGap` (8 pt, the explicit stand-in for the official
/// `interBlockSpacing = nil`) and adds no padding around a block. The 1023
/// collapsed tool/thinking row has no `minHeight`: its line box is the tallest
/// child — max(24 pt icon/caret slot, the 21 pt row text line box scaled with
/// `.body`) — plus 6 pt button padding on each side (R28 §1.2/§2.1). The
/// status line is the 20 pt mark plus its own vertical padding.
///
/// The adapter supplies the text blocks' measured heights; everything else is
/// fixed. Keeping the sums here, rather than in the adapter, lets the estimate,
/// the pre-apply measurement and the unit tests share one formula — the device
/// report (2026-10-23) showed a 2 pt drift on every tool-only row because the
/// estimate used the unscaled 24 pt line box while the view scaled it to 22 pt.
nonisolated enum CodeRowHeightPlan {
    enum Block: Equatable {
        /// A text block whose content height was measured by its renderer.
        case text(height: CGFloat)
        /// One user-attachment block whose height `CodeAttachmentLayout`
        /// computed: an image grid, a failed `ArtifactPreviewCard`, or the
        /// successful file grid. They are siblings of the same 8 pt stack,
        /// so each one is a block in this plan.
        case attachments(height: CGFloat)
        /// One `Block.toolCalls` with `segments` collapsed rows.
        case tools(segments: Int)
        /// One settled `thinkingContent` row (`CodeThinkingRow`): the same
        /// one-line `CollapsedRowButton` geometry as a tool row.
        case thinking
        /// The generic one-line row (`otherRow`).
        case other
    }

    struct Row: Equatable {
        var blocks: [Block] = []
    }

    struct Metrics: Equatable {
        /// Between two blocks inside one rendered row (`blockGap`, 8 pt).
        var blockSpacing: CGFloat
        /// Between two rendered rows (`interMessageSpacing`, 10 pt).
        var rowSpacing: CGFloat
        /// The tool row's line box, already scaled by Dynamic Type.
        var toolLineHeight: CGFloat
        /// One side of a collapsed tool row's button padding (6 pt).
        var toolButtonPadding: CGFloat
        /// The generic row's line box (unscaled).
        var otherLineHeight: CGFloat
        /// `rowMarginTop + rowMarginBottom`.
        var rowMargins: CGFloat
    }

    /// The turn action bar's one-line height: the official 20 pt glyph slot.
    /// The bar is an extra child of the row's `VStack`, so it adds one
    /// `rowSpacing` gap when at least one row rendered.
    static let actionBarHeight: CGFloat = 20

    /// Empty rows contribute nothing, exactly as `CodeMessageRowView` drops
    /// them before its stack. The status line is a sibling of the rows, so it
    /// adds `rowSpacing` only when at least one row rendered.
    static func height(rows: [Row], metrics: Metrics,
                       hasActionBar: Bool = false) -> CGFloat {
        var total: CGFloat = 0
        var renderedRows = 0
        for row in rows where !row.blocks.isEmpty {
            renderedRows += 1
            for (index, block) in row.blocks.enumerated() {
                if index > 0 { total += metrics.blockSpacing }
                switch block {
                case .text(let height):
                    total += max(0, height)
                case .attachments(let height):
                    total += max(0, height)
                case .tools(let segments):
                    total += CGFloat(max(0, segments))
                        * (metrics.toolLineHeight + 2 * metrics.toolButtonPadding)
                case .thinking:
                    total += metrics.toolLineHeight + 2 * metrics.toolButtonPadding
                case .other:
                    total += metrics.otherLineHeight
                }
            }
        }
        if renderedRows > 1 {
            total += CGFloat(renderedRows - 1) * metrics.rowSpacing
        }
        if hasActionBar {
            if renderedRows > 0 { total += metrics.rowSpacing }
            total += actionBarHeight
        }
        total += metrics.rowMargins
        return ceil(max(0, total))
    }
}

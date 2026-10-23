import Foundation

/// The exact vertical arithmetic of one Code message row.
///
/// `CodeMessageRowView` stacks rendered rows with `blockSpacing` between them.
/// Each row stacks blocks with `segmentVerticalPadding` between them, and each
/// block adds `segmentVerticalPadding` on both sides. A collapsed tool row is
/// a 24 pt line box (scaled by Dynamic Type at render time) plus 6 pt button
/// padding on each side; the status line is the 20 pt mark plus the same
/// vertical padding.
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
        /// One `Block.toolCalls` with `segments` collapsed rows.
        case tools(segments: Int)
        /// The generic one-line row (`otherRow`).
        case other
    }

    struct Row: Equatable {
        var blocks: [Block] = []
    }

    struct Metrics: Equatable {
        /// Both sides of one block (`2 x segmentVerticalPadding`).
        var blockPadding: CGFloat
        /// Between two blocks inside one rendered row.
        var blockSpacing: CGFloat
        /// Between two rendered rows (`blockSpacing`, 16 pt).
        var rowSpacing: CGFloat
        /// The tool row's line box, already scaled by Dynamic Type.
        var toolLineHeight: CGFloat
        /// One side of a collapsed tool row's button padding (6 pt).
        var toolButtonPadding: CGFloat
        /// The generic row's line box (unscaled).
        var otherLineHeight: CGFloat
        /// The working status line: 20 pt mark plus both vertical paddings.
        var statusLineHeight: CGFloat
        /// `rowMarginTop + rowMarginBottom`.
        var rowMargins: CGFloat
    }

    /// Empty rows contribute nothing, exactly as `CodeMessageRowView` drops
    /// them before its stack. The status line is a sibling of the rows, so it
    /// adds `rowSpacing` only when at least one row rendered.
    static func height(rows: [Row], showsWorkingStatus: Bool,
                       metrics: Metrics) -> CGFloat {
        var total: CGFloat = 0
        var renderedRows = 0
        for row in rows where !row.blocks.isEmpty {
            renderedRows += 1
            for (index, block) in row.blocks.enumerated() {
                if index > 0 { total += metrics.blockSpacing }
                total += metrics.blockPadding
                switch block {
                case .text(let height):
                    total += max(0, height)
                case .tools(let segments):
                    total += CGFloat(max(0, segments))
                        * (metrics.toolLineHeight + 2 * metrics.toolButtonPadding)
                case .other:
                    total += metrics.otherLineHeight
                }
            }
        }
        if renderedRows > 1 {
            total += CGFloat(renderedRows - 1) * metrics.rowSpacing
        }
        if showsWorkingStatus {
            total += metrics.statusLineHeight
            if renderedRows > 0 { total += metrics.rowSpacing }
        }
        total += metrics.rowMargins
        return ceil(max(0, total))
    }
}

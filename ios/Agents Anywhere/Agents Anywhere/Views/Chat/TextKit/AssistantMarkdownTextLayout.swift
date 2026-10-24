#if canImport(UIKit)
import Textual
import UIKit

/// TextKit 2 measurement for the assistant body. The same attributed strings
/// are handed to the block text views, so measurement and rendering are one
/// engine (the shape the Claude app uses: `NSTextLayoutManager` with a
/// detached `NSTextContainer`).
@MainActor
enum AssistantMarkdownTextLayout {
    /// Textual's CSS-style margin collapsing: the gap between two blocks is
    /// the larger of the previous block's bottom margin and the next block's
    /// top margin. The values come from AA's existing typography scheme, not
    /// from a redesign.
    struct BlockMargins {
        let top: CGFloat?
        let bottom: CGFloat?
    }

    static func margins(for block: AssistantMarkdownBlock) -> BlockMargins {
        // Textual's `.fontScaled` multiplies the reference ratio by the current
        // body size; keep the same conversion here.
        let scale = ChatMetrics.bodySize / ChatMetrics.referenceBodySize
        func scaled(_ points: CGFloat) -> CGFloat { points * scale }
        switch block {
        case .text(let text):
            return BlockMargins(
                top: scaled(ChatMetrics.paragraphSpacing),
                bottom: text.headingLevel == nil ? nil : scaled(8))
        case .code, .table:
            return BlockMargins(
                top: scaled(ChatMetrics.codeBlockMargin),
                bottom: scaled(ChatMetrics.codeBlockMargin))
        case .list, .quote, .image, .math:
            // The legacy renderer treats an image or a display formula as a
            // paragraph block, so it takes the paragraph's top margin.
            return BlockMargins(top: scaled(ChatMetrics.paragraphSpacing), bottom: nil)
        case .divider:
            // Textual's themed break spacing is `.fontScaled(top: 1.6,
            // bottom: 1.6)`; both sides carry it so the collapsed margin with
            // a neighbouring paragraph is the same 1.6em.
            let spacing = 1.6 * ChatMetrics.bodySize
            return BlockMargins(top: spacing, bottom: spacing)
        }
    }

    static func spacing(after block: AssistantMarkdownBlock,
                        before next: AssistantMarkdownBlock) -> CGFloat {
        max(margins(for: block).bottom ?? 0,
            margins(for: next).top ?? 0)
    }

    /// Height of one text block, wrapped to `width`. Pixel-rounded the same way
    /// `MarkdownBlockSizing` rounds a Textual block.
    static func height(of attributed: NSAttributedString,
                       width: CGFloat,
                       displayScale: CGFloat) -> CGFloat {
        guard width > 0, width.isFinite, attributed.length > 0 else { return 0 }
        let storage = NSTextContentStorage()
        storage.attributedString = attributed
        let manager = NSTextLayoutManager()
        storage.addTextLayoutManager(manager)
        let container = NSTextContainer(
            size: CGSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        manager.textContainer = container
        manager.ensureLayout(for: manager.documentRange)
        let used = manager.usageBoundsForTextContainer.maxY
        guard used.isFinite, used > 0 else { return 0 }
        return roundUp(used, scale: displayScale)
    }

    /// TextKit's used size for an attributed string laid out without wrapping.
    /// Code blocks scroll horizontally, so their intrinsic width is what sets
    /// the scroll content and their height must not depend on the column.
    static func intrinsicSize(of attributed: NSAttributedString,
                              displayScale: CGFloat) -> CGSize {
        guard attributed.length > 0 else { return .zero }
        let storage = NSTextContentStorage()
        storage.attributedString = attributed
        let manager = NSTextLayoutManager()
        storage.addTextLayoutManager(manager)
        let container = NSTextContainer(
            size: CGSize(width: 1_000_000, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        manager.textContainer = container
        manager.ensureLayout(for: manager.documentRange)
        let used = manager.usageBoundsForTextContainer
        guard used.width.isFinite, used.height.isFinite, used.height > 0 else { return .zero }
        return CGSize(width: roundUp(used.width, scale: displayScale),
                      height: roundUp(used.height, scale: displayScale))
    }

    /// Height of any block, from the same measurements its view installs as
    /// explicit constraints.
    static func height(of block: AssistantMarkdownBlock,
                       width: CGFloat,
                       displayScale: CGFloat) -> CGFloat {
        guard width > 0, width.isFinite else { return 0 }
        switch block {
        case .text(let text):
            return height(of: text.attributed, width: width, displayScale: displayScale)
        case .list(let list):
            var total: CGFloat = 0
            for (index, item) in list.items.enumerated() {
                if index > 0 { total += list.itemSpacing }
                let contentWidth = max(0, width - list.contentIndent(for: item.marker))
                total += stackHeight(of: item.blocks,
                                     width: contentWidth,
                                     uniformSpacing: list.itemSpacing,
                                     displayScale: displayScale)
            }
            return roundUp(total, scale: displayScale)
        case .quote(let quote):
            let contentWidth = max(0, width - quote.inset)
            let total = stackHeight(of: quote.blocks,
                                    width: contentWidth,
                                    displayScale: displayScale)
            return roundUp(total, scale: displayScale)
        case .code(let code):
            let divider = displayScale > 0 && displayScale.isFinite
                ? 1 / displayScale : 1
            let textHeight = intrinsicSize(of: code.code,
                                           displayScale: displayScale).height
            return roundUp(code.headerHeight + divider
                           + code.contentPadding * 2 + textHeight,
                           scale: displayScale)
        case .table(let table):
            // Column widths are capped and fixed at parse time, so the grid
            // scrolls sideways instead of reflowing against the row width.
            return roundUp(table.totalHeight, scale: displayScale)
        case .image(let image):
            // The reserved box is the legacy attachment's footprint; the
            // loaded image only ever draws inside it.
            return roundUp(image.reservedSize(columnWidth: width).height,
                           scale: displayScale)
        case .math(let math):
            return roundUp(math.metrics(columnWidth: width).size.height,
                           scale: displayScale)
        case .divider:
            // `Divider().frame(minHeight: 1)`.
            return roundUp(1, scale: displayScale)
        }
    }

    /// Column widths and row heights for a table, from the same TextKit engine
    /// the cell text views use. The table's own width is the sum of the columns
    /// and does not depend on the timeline column.
    static func tableMetrics(rows: [[NSAttributedString]],
                             paddingHorizontal: CGFloat,
                             paddingVertical: CGFloat) -> (widths: [CGFloat], heights: [CGFloat]) {
        let columnCount = max(1, rows.map { $0.count }.max() ?? 0)
        var widths = Array(repeating: paddingHorizontal * 2, count: columnCount)
        // Metrics are baked into the document, before a cell knows the
        // display scale; rounding to whole points keeps the two consumers
        // identical and costs at most one point against the product.
        let metricScale: CGFloat = 1
        for row in rows {
            for (column, cell) in row.enumerated() where column < columnCount {
                let ideal = intrinsicSize(of: cell, displayScale: metricScale).width
                widths[column] = min(
                    max(widths[column], ideal + paddingHorizontal * 2),
                    ChatMetrics.tableContentWidthCap)
            }
        }
        let heights = rows.map { row -> CGFloat in
            var tallest: CGFloat = 0
            for (column, cell) in row.enumerated() where column < columnCount {
                let textWidth = max(0, widths[column] - paddingHorizontal * 2)
                tallest = max(tallest,
                    height(of: cell, width: textWidth, displayScale: metricScale)
                        + paddingVertical * 2)
            }
            return tallest
        }
        return (widths, heights)
    }

    /// Height of a vertical block stack. Individual blocks are already
    /// pixel-rounded; the caller decides whether the sum needs its own round.
    static func stackHeight(of blocks: [AssistantMarkdownBlock],
                            width: CGFloat,
                            uniformSpacing: CGFloat? = nil,
                            displayScale: CGFloat) -> CGFloat {
        var total: CGFloat = 0
        for (index, block) in blocks.enumerated() {
            if index > 0 {
                total += uniformSpacing
                    ?? spacing(after: blocks[index - 1], before: block)
            }
            total += height(of: block, width: width, displayScale: displayScale)
        }
        return total
    }

    /// The legacy renderer places each `MarkdownBlockSnapshot` in a VStack with
    /// this spacing; blocks inside one snapshot use Textual's collapsed
    /// margins instead.
    static let snapshotSpacing: CGFloat = 12

    static func topLevelSpacing(after index: Int,
                                in document: AssistantMarkdownDocument) -> CGFloat {
        guard document.blocks.indices.contains(index + 1),
              document.blockGroups.indices.contains(index),
              document.blockGroups.indices.contains(index + 1) else { return 0 }
        // [E] The Code page's official Markdown renderer uses one block gap
        // (`blockSpacing = 16`, 0x10170a9c8). AA's Chat path keeps its
        // snapshot boundary and collapsed margins.
        if let blockSpacing = document.blockSpacing {
            if let roles = document.codeRoles,
               let headingGap = headingGap(
                    after: document.blocks[index],
                    before: document.blocks[index + 1],
                    roles: roles) {
                return headingGap
            }
            return blockSpacing
        }
        if document.blockGroups[index] != document.blockGroups[index + 1] {
            return snapshotSpacing
        }
        return spacing(after: document.blocks[index],
                       before: document.blocks[index + 1])
    }

    /// Heading spacing for the Code page, expressed as the gap between two
    /// top-level blocks so the renderer's stack and this measurement share one
    /// number (a paragraph-style `paragraphSpacingBefore/After` inside a
    /// single-block text view would be outside the stack's control).
    ///
    /// Evidence: `EVIDENCE/round19/typography-inline.md` §1.2 — before =
    /// size × 0.4 (9.6 / 8.0 / 6.8), after = size × 0.6 (14.4 / 12.0 / 10.2).
    /// TextKit's paragraph spacing applies the previous paragraph's after and
    /// the next paragraph's before, so a heading adjacent to another heading
    /// adds both.
    private static func headingGap(after block: AssistantMarkdownBlock,
                                   before next: AssistantMarkdownBlock,
                                   roles: CodePageMarkdownRoles) -> CGFloat? {
        let bottom = headingLevel(of: block).map {
            roles.headingSize(for: $0) * roles.headingBottomSpacingMultiplier
        }
        let top = headingLevel(of: next).map {
            roles.headingSize(for: $0) * roles.headingTopSpacingMultiplier
        }
        guard bottom != nil || top != nil else { return nil }
        return (bottom ?? 0) + (top ?? 0)
    }

    private static func headingLevel(of block: AssistantMarkdownBlock) -> Int? {
        guard case .text(let text) = block else { return nil }
        return text.headingLevel
    }

    /// Sum of the block heights plus the same spacing the cell stack uses.
    static func measure(_ document: AssistantMarkdownDocument,
                        width: CGFloat,
                        displayScale: CGFloat) -> CGFloat {
        var total: CGFloat = 0
        for (index, block) in document.blocks.enumerated() {
            if index > 0 { total += topLevelSpacing(after: index - 1, in: document) }
            total += height(of: block, width: width, displayScale: displayScale)
        }
        return total
    }

    private static func roundUp(_ value: CGFloat, scale: CGFloat) -> CGFloat {
        guard value.isFinite, value > 0 else { return 0 }
        let s = scale > 0 && scale.isFinite ? scale : 1
        return ceil(value * s) / s
    }
}

/// One TextKit 2 block. `UITextView` is the official renderer's base too
/// (`MarkdownUITextView` holds a custom `NSTextLayoutManager`); the M2 cell
/// only needs the default TextKit 2 stack and an intrinsic height that matches
/// `AssistantMarkdownTextLayout.height(of:)`.
final class AssistantMarkdownBlockTextView: UITextView {
    private var lastMeasuredWidth: CGFloat = -1

    init() {
        super.init(frame: .zero, textContainer: nil)
        isEditable = false
        isScrollEnabled = false
        isSelectable = false
        isUserInteractionEnabled = false
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw
        textContainerInset = .zero
        textContainer.lineFragmentPadding = 0
        textContainer.widthTracksTextView = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Paints the official inline-code chips *under* the glyphs. The chip is a
    /// pure decoration of the attributed run
    /// (`EVIDENCE/round19/typography-inline.md` §3): it adds no attribute that
    /// TextKit lays out, so this drawing pass cannot change the height that
    /// `AssistantMarkdownTextLayout.height(of:)` reports.
    override func draw(_ rect: CGRect) {
        // The same view class draws fenced-code bodies (no chip marker); the
        // marker scan keeps that path from paying for a chip layout pass.
        if let attributedText, let manager = textLayoutManager,
           AssistantInlineCodeChipRenderer.containsChip(attributedText) {
            AssistantInlineCodeChipRenderer.drawChips(
                in: attributedText,
                layoutManager: manager,
                origin: CGPoint(x: textContainerInset.left,
                                y: textContainerInset.top),
                traitCollection: traitCollection)
        }
        super.draw(rect)
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        if traitCollection.hasDifferentColorAppearance(comparedTo: previous) {
            setNeedsDisplay()
        }
    }

    override var intrinsicContentSize: CGSize {
        guard bounds.width > 0, let attributedText, attributedText.length > 0 else {
            return CGSize(width: UIView.noIntrinsicMetric, height: 0)
        }
        let height = AssistantMarkdownTextLayout.height(
            of: attributedText,
            width: bounds.width,
            displayScale: traitCollection.displayScale)
        return CGSize(width: UIView.noIntrinsicMetric, height: height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if abs(bounds.width - lastMeasuredWidth) > 0.5 {
            lastMeasuredWidth = bounds.width
            invalidateIntrinsicContentSize()
        }
    }
}
#endif

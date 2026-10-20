#if canImport(UIKit)
import UIKit

/// TextKit 2 measurement for the assistant body. The same attributed strings
/// are handed to the block text views, so measurement and rendering are one
/// engine (the shape the Claude app uses: `NSTextLayoutManager` with a
/// detached `NSTextContainer`).
@MainActor
enum AssistantMarkdownTextLayout {
    /// `ChatMarkdownView` lays blocks out in a VStack with this spacing.
    static let blockSpacing: CGFloat = 12

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

    /// Height of any block, from the same measurements its view installs as
    /// explicit constraints.
    static func height(of block: AssistantMarkdownBlock,
                       width: CGFloat,
                       displayScale: CGFloat) -> CGFloat {
        guard width > 0, width.isFinite else { return 0 }
        switch block {
        case .text(let attributed):
            return height(of: attributed, width: width, displayScale: displayScale)
        case .list(let list):
            var total: CGFloat = 0
            for (index, item) in list.items.enumerated() {
                if index > 0 { total += list.itemSpacing }
                let contentWidth = max(0, width - list.contentIndent(for: item.marker))
                total += stackHeight(of: item.blocks,
                                     width: contentWidth,
                                     spacing: list.innerSpacing,
                                     displayScale: displayScale)
            }
            return roundUp(total, scale: displayScale)
        case .quote(let quote):
            let contentWidth = max(0, width - quote.inset)
            let total = stackHeight(of: quote.blocks,
                                    width: contentWidth,
                                    spacing: quote.innerSpacing,
                                    displayScale: displayScale)
            return roundUp(total, scale: displayScale)
        }
    }

    /// Height of a vertical block stack. Individual blocks are already
    /// pixel-rounded; the caller decides whether the sum needs its own round.
    static func stackHeight(of blocks: [AssistantMarkdownBlock],
                            width: CGFloat,
                            spacing: CGFloat,
                            displayScale: CGFloat) -> CGFloat {
        var total: CGFloat = 0
        for (index, block) in blocks.enumerated() {
            if index > 0 { total += spacing }
            total += height(of: block, width: width, displayScale: displayScale)
        }
        return total
    }

    /// Sum of the block heights plus the product's inter-block spacing.
    static func measure(_ document: AssistantMarkdownDocument,
                        width: CGFloat,
                        displayScale: CGFloat) -> CGFloat {
        var total: CGFloat = 0
        for (index, block) in document.blocks.enumerated() {
            if index > 0 { total += blockSpacing }
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
        textContainerInset = .zero
        textContainer.lineFragmentPadding = 0
        textContainer.widthTracksTextView = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

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

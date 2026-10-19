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

    /// Height of one block, wrapped to `width`. Pixel-rounded the same way
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
        let scale = displayScale > 0 && displayScale.isFinite ? displayScale : 1
        return ceil(used * scale) / scale
    }

    /// Sum of the block heights plus the product's inter-block spacing.
    static func measure(_ document: AssistantMarkdownDocument,
                        width: CGFloat,
                        displayScale: CGFloat) -> CGFloat {
        var total: CGFloat = 0
        for (index, block) in document.blocks.enumerated() {
            if index > 0 { total += blockSpacing }
            switch block {
            case .text(let attributed):
                total += height(of: attributed, width: width, displayScale: displayScale)
            }
        }
        return total
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

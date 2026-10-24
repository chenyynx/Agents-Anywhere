#if canImport(UIKit)
import SwiftUI
import UIKit

/// The Code page user bubble's text: plain selectable text rendered and
/// measured by the same TextKit engine.
///
/// The bubble's height is measured by `CodeMessageHeightMeasurer`
/// (`userBubbleTextHeight`), which uses `AssistantMarkdownTextLayout.height`
/// and subtracts the trailing line gap. The view used to draw through
/// Textual's `InlineText`; the two engines disagreed by 3.67 pt on the
/// code-profile fixture, so the row corrected itself after display. Drawing
/// with the same TextKit call makes the first fit carry the measured height
/// exactly.
struct CodeUserBubbleText: UIViewRepresentable {
    let text: String
    let color: Color

    @Environment(\.displayScale) private var displayScale

    func makeUIView(context: Context) -> CodeUserBubbleTextView {
        let view = CodeUserBubbleTextView()
        view.backgroundColor = .clear
        view.isOpaque = false
        view.isEditable = false
        view.isScrollEnabled = false
        view.isSelectable = true
        view.isUserInteractionEnabled = true
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.textContainer.widthTracksTextView = true
        return view
    }

    func updateUIView(_ uiView: CodeUserBubbleTextView, context: Context) {
        let attributed = CodeUserBubbleTextMetrics.attributed(
            text, color: UIColor(color))
        uiView.attributedText = attributed
        uiView.userBubbleLineSpacing = CodeUserBubbleTextMetrics.lineSpacing()
        uiView.invalidateIntrinsicContentSize()
    }

    func sizeThatFits(_ proposal: ProposedViewSize,
                      uiView: CodeUserBubbleTextView,
                      context: Context) -> CGSize? {
        let width = proposal.width ?? uiView.bounds.width
        guard width > 0, width.isFinite else { return nil }
        let height = CodeUserBubbleTextMetrics.height(
            text: text, width: width, displayScale: max(displayScale, 1))
        return CGSize(width: width, height: height)
    }
}

/// The exact attributed text `CodeMessageHeightMeasurer.userBubbleTextHeight`
/// measures. Shared so the renderer and the measurer can never drift.
enum CodeUserBubbleTextMetrics {
    static func attributed(_ text: String,
                           traits: UITraitCollection? = nil,
                           color: UIColor? = nil) -> NSAttributedString {
        let size = UIFontMetrics(forTextStyle: .body)
            .scaledValue(for: CodePageTheme.markdownBodySize, compatibleWith: traits)
        let font = MarkdownFontFactory.font(
            name: CodePageTheme.sansFontName, size: size, weight: 400)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing(traits: traits)
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .paragraphStyle: paragraph,
        ]
        if let color { attributes[.foregroundColor] = color }
        return NSAttributedString(string: text, attributes: attributes)
    }

    static func lineSpacing(traits: UITraitCollection? = nil) -> CGFloat {
        UIFontMetrics(forTextStyle: .body)
            .scaledValue(for: CodePageTheme.userBubbleLineSpacing, compatibleWith: traits)
    }

    /// TextKit's usage height minus the trailing gap SwiftUI does not draw —
    /// the same arithmetic `CodeMessageHeightMeasurer` uses.
    static func height(text: String, width: CGFloat, displayScale: CGFloat,
                       traits: UITraitCollection? = nil) -> CGFloat {
        let attributed = attributed(text, traits: traits)
        let raw = AssistantMarkdownTextLayout.height(
            of: attributed, width: width, displayScale: displayScale)
        return ceil(max(0, raw - lineSpacing(traits: traits)))
    }
}

final class CodeUserBubbleTextView: UITextView {
    var userBubbleLineSpacing: CGFloat = 0
    private var lastMeasuredWidth: CGFloat = -1

    init() {
        super.init(frame: .zero, textContainer: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: CGSize {
        guard bounds.width > 0, let attributedText, attributedText.length > 0 else {
            return CGSize(width: UIView.noIntrinsicMetric, height: 0)
        }
        let raw = AssistantMarkdownTextLayout.height(
            of: attributedText, width: bounds.width,
            displayScale: traitCollection.displayScale)
        let height = ceil(max(0, raw - userBubbleLineSpacing))
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

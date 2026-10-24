#if canImport(UIKit)
import CoreText
import SwiftUI
import Textual
import UIKit

/// An inline attachment inside a TextKit text block.
///
/// Textual resolves two constructs as run attachments: Git badges and math
/// formulas. The legacy renderer draws them as SwiftUI views inside the text
/// flow; this attachment keeps the same views and the same `sizeThatFits`
/// numbers, but mounts them through TextKit 2's view provider so measurement
/// and drawing read one string.
final class AssistantInlineAttachment: NSTextAttachment {
    enum Payload {
        case gitBadge([GitDirective])
        case math(latex: String, isBlock: Bool, fontSize: CGFloat)
    }

    let payload: Payload
    let accessibilityText: String

    init(payload: Payload, size: CGSize, baselineOffset: CGFloat,
         accessibilityText: String) {
        self.payload = payload
        self.accessibilityText = accessibilityText
        super.init(data: nil, ofType: nil)
        bounds = CGRect(x: 0, y: baselineOffset,
                        width: size.width, height: size.height)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewProvider(for parentView: UIView?,
                               location: NSTextLocation,
                               textContainer: NSTextContainer?) -> NSTextAttachmentViewProvider? {
        let provider = AssistantInlineAttachmentProvider(
            textAttachment: self,
            parentView: parentView,
            textLayoutManager: textContainer?.textLayoutManager,
            location: location)
        provider.tracksTextAttachmentViewBounds = true
        return provider
    }

    /// The badge metrics are the legacy attachment's `sizeThatFits`: the
    /// 0.8× base font size drives both the capsule and its baseline.
    static func gitBadgeMetrics(label: String,
                                baseFontSize: CGFloat) -> (size: CGSize, baselineOffset: CGFloat) {
        let size = 0.8 * baseFontSize
        let font = CTFontCreateUIFontForLanguage(.system, size, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let text = NSAttributedString(string: label, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
        ])
        let line = CTLineCreateWithAttributedString(text)
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) + size * 2.8
        return (CGSize(width: width.rounded(.up), height: size * 1.8),
                -0.22 * baseFontSize)
    }
}

private final class AssistantInlineAttachmentProvider: NSTextAttachmentViewProvider {
    private var host: UIHostingController<AnyView>?

    override func loadView() {
        guard let attachment = textAttachment as? AssistantInlineAttachment else { return }
        // Attachment view loading is always driven from the main thread; the
        // badge's SwiftUI body is MainActor-isolated.
        MainActor.assumeIsolated {
            let content: AnyView
            switch attachment.payload {
            case .gitBadge(let directives):
                content = AnyView(ChatGitBadgeAttachment(directives: directives).body)
            case .math(let latex, let isBlock, let fontSize):
                content = AnyView(TextualMathView(
                    latex: latex, isBlock: isBlock, fontSize: fontSize))
            }
            let host = UIHostingController(rootView: content)
            host.view.backgroundColor = .clear
            host.view.isUserInteractionEnabled = true
            host.view.isAccessibilityElement = true
            host.view.accessibilityLabel = attachment.accessibilityText
            self.host = host
            view = host.view
        }
    }
}
#endif

#if DEBUG
import CDMarkdownKit
import SwiftUI
import UIKit

/// Typography for the assistant body, resolved the same way the product does.
///
/// `ChatMetrics` expresses line spacing as a ratio of the reference body size;
/// Textual's `FontScaled` multiplies that ratio by the *current* point size.
/// TextKit 2 has to be given the resolved point value, not the ratio.
struct TextKitSpikeTypography {
    let bodySize: CGFloat
    let lineSpacing: CGFloat
    let paragraphSpacing: CGFloat

    static var current: TextKitSpikeTypography {
        let bodySize = ChatMetrics.bodySize
        return TextKitSpikeTypography(
            bodySize: bodySize,
            lineSpacing: ChatMetrics.bodyLineSpacingRatio * bodySize,
            paragraphSpacing: ChatMetrics.paragraphSpacingRatio * bodySize)
    }

    var font: UIFont { .systemFont(ofSize: bodySize) }

    /// Parser configured with the product's running-text font and leading.
    /// Paragraph spacing is left at zero here: a single `MarkdownBlockSnapshot`
    /// is one paragraph, so inter-block spacing lives outside this string.
    func makeParser() -> CDMarkdownParser {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        paragraph.paragraphSpacing = 0
        return CDMarkdownParser(font: font,
                                fontColor: .label,
                                backgroundColor: .clear,
                                paragraphStyle: paragraph,
                                automaticLinkDetectionEnabled: true)
    }

    /// The same attributes without a Markdown parser in the way. Used as the
    /// control that separates engine parity from parser/styling parity.
    func plainAttributedString(_ text: String, paragraphSpacing: CGFloat) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        paragraph.paragraphSpacing = paragraphSpacing
        return NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: UIColor.label,
            .paragraphStyle: paragraph,
        ])
    }
}

/// Minimal TextKit 2 stack, mirroring what `CDMarkdownTextView.sizeThatFits`
/// does internally: a detached `NSTextContentStorage` + `NSTextLayoutManager`
/// + `NSTextContainer`, measured with `usageBoundsForTextContainer`.
enum TextKit2Probe {
    static func height(of attributed: NSAttributedString, width: CGFloat) -> CGFloat {
        let storage = NSTextContentStorage()
        storage.attributedString = attributed
        let manager = NSTextLayoutManager()
        storage.addTextLayoutManager(manager)
        let container = NSTextContainer(
            size: CGSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        manager.textContainer = container
        manager.ensureLayout(for: manager.documentRange)
        return manager.usageBoundsForTextContainer.maxY
    }
}

/// CDMarkdownKit path: parse with its own parser, then measure with its own
/// `CDMarkdownTextView.sizeThatFits` (which builds a detached TextKit 2 stack).
@MainActor
enum CDMarkdownProbe {
    struct Result {
        let height: CGFloat
        let parseMilliseconds: Double
        let measureMilliseconds: Double
        let isTextKit2: Bool
        let lineFragmentPadding: CGFloat
        let textContainerInset: UIEdgeInsets
    }

    static func parse(_ markdown: String,
                      typography: TextKitSpikeTypography) async -> (NSAttributedString, Double) {
        let started = Date().timeIntervalSinceReferenceDate
        let attributed = await typography.makeParser().parse(markdown)
        return (attributed, (Date().timeIntervalSinceReferenceDate - started) * 1000)
    }

    static func measure(_ markdown: String,
                        width: CGFloat,
                        typography: TextKitSpikeTypography) async -> (Result, NSAttributedString) {
        let (attributed, parseMilliseconds) = await parse(markdown, typography: typography)
        let view = CDMarkdownTextView.makeTextView(frame: .zero)
        view.isScrollEnabled = false
        view.isSelectable = false
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        let started = Date().timeIntervalSinceReferenceDate
        view.attributedText = attributed
        let fitted = view.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        let measureMilliseconds = (Date().timeIntervalSinceReferenceDate - started) * 1000
        let result = Result(height: fitted.height,
                            parseMilliseconds: parseMilliseconds,
                            measureMilliseconds: measureMilliseconds,
                            isTextKit2: view.textLayoutManager != nil,
                            lineFragmentPadding: view.textContainer.lineFragmentPadding,
                            textContainerInset: view.textContainerInset)
        return (result, attributed)
    }
}

/// Current product renderer, measured on screen. `ChatMarkdownView` parses
/// Markdown in a `.task`, so the hosting view has to be in a window for the
/// content to exist at all; an off-window `sizeThatFits` only sees the VStack
/// spacing (the 2pt incident).
@MainActor
enum HostedMarkdownProbe {
    struct Result {
        let height: CGFloat
        let firstHeight: CGFloat
        let settled: Bool
        let sampleCount: Int
        let elapsedMilliseconds: Double
        /// Safe area captured while the hosting view was in the window. The
        /// first run showed a constant ~68pt offset on every pure fixture —
        /// `UIHostingController.sizeThatFits` adds the inherited safe area.
        let hostInsets: UIEdgeInsets
        let windowInsets: UIEdgeInsets
    }

    static func measure(_ markdown: String,
                        width: CGFloat,
                        in window: UIWindow,
                        timeout: TimeInterval = 15) async -> Result {
        await measure(view: AnyView(ChatMarkdownView(text: markdown)),
                      width: width, in: window, timeout: timeout)
    }

    /// Bare SwiftUI `Text` with the same font and leading as the product's
    /// paragraph style. Separates "SwiftUI Text layout" from "Textual's block
    /// styling" when the product height disagrees with TextKit 2.
    /// Height without a window. Synchronous SwiftUI content (bare `Text`)
    /// measures correctly here; `ChatMarkdownView` cannot, which is the 2pt
    /// incident this spike exists to replace.
    static func offWindowHeight(view: AnyView, width: CGFloat) -> CGFloat {
        let controller = UIHostingController(rootView: view)
        return controller.sizeThatFits(
            in: CGSize(width: width, height: .greatestFiniteMagnitude)).height
    }

    static func bareTextView(_ text: String,
                             typography: TextKitSpikeTypography) -> AnyView {
        AnyView(
            Text(text)
                .font(.system(size: typography.bodySize))
                .lineSpacing(typography.lineSpacing)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading))
    }

    static func measureBareText(_ text: String,
                                width: CGFloat,
                                typography: TextKitSpikeTypography,
                                in window: UIWindow,
                                timeout: TimeInterval = 15) async -> Result {
        await measure(view: bareTextView(text, typography: typography),
                      width: width, in: window, timeout: timeout)
    }

    static func measure(view: AnyView,
                        width: CGFloat,
                        in window: UIWindow,
                        timeout: TimeInterval = 15) async -> Result {
        let controller = UIHostingController(rootView: view)
        guard let root = window.rootViewController, let hostView = controller.view else {
            return Result(height: -1, firstHeight: -1, settled: false,
                          sampleCount: 0, elapsedMilliseconds: 0,
                          hostInsets: .zero, windowInsets: window.safeAreaInsets)
        }
        hostView.backgroundColor = .clear
        // Place the probe below the status bar: a view fully inside the safe
        // area has zero safe-area insets, so `sizeThatFits` cannot fold a
        // status-bar inset into the measured text height.
        hostView.frame = CGRect(x: 0, y: window.safeAreaInsets.top,
                                width: width, height: 800)
        root.addChild(controller)
        root.view.addSubview(hostView)
        controller.didMove(toParent: root)
        hostView.layoutIfNeeded()

        let started = Date()
        var firstHeight: CGFloat = -1
        var lastHeight: CGFloat = -1
        var stableSamples = 0
        var sampleCount = 0
        var settled = false
        while Date().timeIntervalSince(started) < timeout {
            try? await Task.sleep(for: .milliseconds(80))
            let height = controller.sizeThatFits(
                in: CGSize(width: width, height: .greatestFiniteMagnitude)).height
            if firstHeight < 0 { firstHeight = height }
            sampleCount += 1
            if abs(height - lastHeight) <= 0.01 {
                stableSamples += 1
            } else {
                stableSamples = 0
            }
            lastHeight = height
            // `> 8` rejects the pre-parse VStack spacing (the 2pt incident).
            if stableSamples >= 4, height > 8 {
                settled = true
                break
            }
        }

        let hostInsets = hostView.safeAreaInsets
        controller.willMove(toParent: nil)
        hostView.removeFromSuperview()
        controller.removeFromParent()
        return Result(height: lastHeight,
                      firstHeight: firstHeight,
                      settled: settled,
                      sampleCount: sampleCount,
                      elapsedMilliseconds: Date().timeIntervalSince(started) * 1000,
                      hostInsets: hostInsets,
                      windowInsets: window.safeAreaInsets)
    }
}
#endif

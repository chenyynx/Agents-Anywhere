#if DEBUG
import QuartzCore
import SwiftUI
import UIKit

/// C5/M4.2 mask spike. It proves the two things the hybrid tail could not:
/// the per-line mask uses the same TextKit 2 layout as the height, and the
/// reveal animation is attached with the official values.
@MainActor
enum TextKitMaskSpikeAutoRun {
    static let launchArgument = "aa-textkit-mask-spike"
    static let resultFileName = "textkit-mask-spike.json"
    private static let width: CGFloat = 380

    static func run() async {
        let window = UIWindow(frame: UIScreen.main.bounds)
        let controller = UIViewController()
        window.rootViewController = controller
        window.makeKeyAndVisible()

        let textView = AssistantMarkdownBlockTextView()
        textView.translatesAutoresizingMaskIntoConstraints = true
        textView.frame = CGRect(x: 0, y: 0, width: width, height: 1200)
        controller.view.addSubview(textView)
        controller.view.layoutIfNeeded()
        textView.layoutIfNeeded()

        let text = String(repeating: "The quick brown fox jumps over the lazy dog. ",
                          count: 20)
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 7.43
        let attributed = NSAttributedString(string: text, attributes: [
            .font: UIFont.systemFont(ofSize: 13),
            .foregroundColor: UIColor.label,
            .paragraphStyle: style,
        ])
        textView.attributedText = attributed
        textView.layoutIfNeeded()
        if let manager = textView.textLayoutManager {
            manager.ensureLayout(for: manager.documentRange)
        }
        try? await Task.sleep(for: .milliseconds(150))

        var failures: [String] = []
        let displayScale = max(1, UITraitCollection.current.displayScale)
        let measured = AssistantMarkdownTextLayout.height(
            of: attributed, width: width, displayScale: displayScale)
        let layoutHeight = textView.textLayoutManager?
            .usageBoundsForTextContainer.maxY ?? -1
        if textView.textLayoutManager == nil {
            failures.append("text view has no TextKit 2 layout manager")
        }
        if layoutHeight <= 0 {
            failures.append("layout height is \(layoutHeight)")
        }
        if abs(layoutHeight - measured) > 1.0 {
            failures.append("layout \(layoutHeight) vs measured \(measured)")
        }

        let revealed = min(160, attributed.length)
        let range = NSRange(location: 0, length: revealed)
        let rects = AssistantMarkdownMaskRenderer.lineRects(for: range, in: textView)
        if rects.isEmpty { failures.append("no line rects for \(revealed) characters") }
        let lastMaxY = rects.map(\.maxY).max() ?? -1
        if lastMaxY <= 0 { failures.append("line rects have no vertical extent") }
        if layoutHeight > 0, lastMaxY > layoutHeight + 1 {
            failures.append("mask lastMaxY \(lastMaxY) exceeds layout \(layoutHeight)")
        }

        let mask = AssistantMarkdownMaskRenderer.makeMaskContainer(for: textView)
        let runLayer = AssistantMarkdownMaskRenderer.appendRun(
            rects: rects, to: textView, mask: mask)
        if runLayer == nil { failures.append("mask run layer was not created") }
        if textView.layer.mask !== mask { failures.append("mask container not installed") }

        let animation = runLayer?.animation(forKey: "reveal") as? CABasicAnimation
        var animationDuration: Double = -1
        var animationFillMode = "missing"
        if let animation {
            animationDuration = animation.duration
            animationFillMode = animation.fillMode.rawValue
            if abs(animation.duration - 0.6) > 0.0001 {
                failures.append("reveal duration \(animation.duration) != 0.6")
            }
            if animation.fillMode != .backwards {
                failures.append("reveal fillMode \(animationFillMode) != backwards")
            }
            if animation.timingFunction == nil {
                failures.append("reveal timing function missing")
            }
        } else {
            failures.append("reveal animation missing")
        }

        // C5/M4.3: can a TextKit 2 text view mount an inline attachment view
        // provider, measure it, hit-test it, and keep it under the reveal
        // mask? This decides the primary vs. fallback design for Git badges
        // and inline math.
        let attachmentSpike = await runAttachmentSpike(
            controller: controller, width: width, displayScale: displayScale)
        failures.append(contentsOf: attachmentSpike.failures)

        let report: [String: Any] = [
            "completed": true,
            "passed": failures.isEmpty,
            "failures": failures,
            "device": UIDevice.current.name,
            "system": UIDevice.current.systemVersion,
            "width": Double(width),
            "displayScale": Double(displayScale),
            "textLength": attributed.length,
            "revealedCharacters": revealed,
            "lineRectCount": rects.count,
            "firstRect": rects.first.map { [$0.minX, $0.minY, $0.width, $0.height] } ?? [],
            "lastMaxY": Double(lastMaxY),
            "measuredHeight": Double(measured),
            "layoutHeight": Double(layoutHeight),
            "maskInstalled": textView.layer.mask === mask,
            "animationDuration": animationDuration,
            "animationFillMode": animationFillMode,
            "attachment": attachmentSpike.report,
        ]
        if let data = try? JSONSerialization.data(
            withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent(resultFileName)
            try? data.write(to: url)
        }
    }

    /// M4.3 attachment spike. A tall chip (44pt) on the first line makes the
    /// line grow, so a broken measurement cannot hide behind the text's own
    /// line height. The provider must mount, sit under the masked layer, and
    /// be reachable by hit-testing (the badge/menu interaction path).
    private static func runAttachmentSpike(
        controller: UIViewController,
        width: CGFloat,
        displayScale: CGFloat
    ) async -> (failures: [String], report: [String: Any]) {
        var failures: [String] = []
        let chipSize = CGSize(width: 120, height: 44)
        let attachment = SpikeInlineAttachment(size: chipSize, baselineOffset: 10)
        let base: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 13),
            .foregroundColor: UIColor.label,
        ]
        let attributed = NSMutableAttributedString(string: "before ", attributes: base)
        attributed.append(NSAttributedString(attachment: attachment))
        attributed.append(NSAttributedString(string: " after", attributes: base))
        let plain = NSAttributedString(string: "before   after", attributes: base)

        let measuredWithAttachment = AssistantMarkdownTextLayout.height(
            of: attributed, width: width, displayScale: displayScale)
        let measuredPlain = AssistantMarkdownTextLayout.height(
            of: plain, width: width, displayScale: displayScale)
        if measuredWithAttachment < measuredPlain + chipSize.height - 6 {
            failures.append(
                "attachment not measured: \(measuredWithAttachment) vs plain \(measuredPlain)")
        }

        // Probe the engine the product should use: the TextKit 2 initializer,
        // not the legacy `init(frame:textContainer:)` path. If the provider
        // only mounts here, the product text view must migrate.
        let textView = UITextView(usingTextLayoutManager: true)
        textView.isEditable = false
        textView.isScrollEnabled = false
        textView.isSelectable = false
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.translatesAutoresizingMaskIntoConstraints = true
        textView.frame = CGRect(x: 0, y: 0, width: width, height: 300)
        // The spike proves the interaction path, so unlike the product text
        // view it must accept touches.
        textView.isUserInteractionEnabled = true
        controller.view.addSubview(textView)
        textView.attributedText = attributed
        controller.view.layoutIfNeeded()
        textView.layoutIfNeeded()
        try? await Task.sleep(for: .milliseconds(250))
        textView.layoutIfNeeded()

        let providerView = firstView(
            withIdentifier: "spike.inlineAttachment", in: textView)
        if providerView == nil {
            failures.append("attachment view provider did not mount")
        }
        if textView.textLayoutManager == nil {
            failures.append("attachment spike text view has no TextKit 2 layout manager")
        }
        let layoutHeight = textView.textLayoutManager?
            .usageBoundsForTextContainer.maxY ?? -1
        if layoutHeight > 0, abs(layoutHeight - measuredWithAttachment) > 1.0 {
            failures.append(
                "attachment layout \(layoutHeight) vs measured \(measuredWithAttachment)")
        }

        var hitTested = false
        if let providerView, providerView.bounds.width > 0, providerView.bounds.height > 0 {
            let centre = providerView.convert(
                CGPoint(x: providerView.bounds.midX, y: providerView.bounds.midY),
                to: textView)
            if let hit = textView.hitTest(centre, with: nil) {
                hitTested = hit === providerView || hit.isDescendant(of: providerView)
            }
        }
        if providerView == nil || !hitTested {
            failures.append("attachment view is not hit-testable")
        }

        let mask = AssistantMarkdownMaskRenderer.makeMaskContainer(for: textView)
        textView.layer.mask = mask
        if let providerView, !providerView.isDescendant(of: textView) {
            failures.append("attachment view left the masked tree")
        }

        let report: [String: Any] = [
            "mounted": providerView != nil,
            "textKit2": textView.textLayoutManager != nil,
            "frame": providerView.map {
                [Double($0.frame.minX), Double($0.frame.minY),
                 Double($0.frame.width), Double($0.frame.height)]
            } ?? [],
            "measuredPlain": Double(measuredPlain),
            "measuredWithAttachment": Double(measuredWithAttachment),
            "layoutHeight": Double(layoutHeight),
            "hitTest": hitTested,
            "maskInstalled": textView.layer.mask === mask,
        ]
        return (failures, report)
    }

    private static func firstView(withIdentifier id: String, in root: UIView) -> UIView? {
        if root.accessibilityIdentifier == id { return root }
        for subview in root.subviews {
            if let found = firstView(withIdentifier: id, in: subview) { return found }
        }
        return nil
    }
}

/// M4.3 spike payload: a fixed-height chip whose host view stands in for the
/// Git badge. The bounds are set by the caller, exactly the shape the real
/// inline attachment will use.
private final class SpikeInlineAttachment: NSTextAttachment {
    init(size: CGSize, baselineOffset: CGFloat) {
        super.init(data: nil, ofType: nil)
        bounds = CGRect(x: 0, y: baselineOffset, width: size.width, height: size.height)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewProvider(for parentView: UIView?,
                               location: NSTextLocation,
                               textContainer: NSTextContainer?) -> NSTextAttachmentViewProvider? {
        return SpikeInlineAttachmentProvider(
            textAttachment: self,
            parentView: parentView,
            textLayoutManager: textContainer?.textLayoutManager,
            location: location)
    }
}

private final class SpikeInlineAttachmentProvider: NSTextAttachmentViewProvider {
    private var host: UIHostingController<SpikeInlineChip>?

    // `attachmentBounds` runs before `loadView`, and the bounds-tracking flag
    // must already be set when it does; setting it after init is too late.
    override init(textAttachment: NSTextAttachment, parentView: UIView?,
                  textLayoutManager: NSTextLayoutManager?, location: NSTextLocation) {
        super.init(textAttachment: textAttachment, parentView: parentView,
                   textLayoutManager: textLayoutManager, location: location)
        tracksTextAttachmentViewBounds = true
    }

    override func loadView() {
        let host = UIHostingController(rootView: SpikeInlineChip())
        host.view.backgroundColor = .clear
        host.view.accessibilityIdentifier = "spike.inlineAttachment"
        host.view.isUserInteractionEnabled = true
        self.host = host
        view = host.view
    }
}

private struct SpikeInlineChip: View {
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.triangle.branch")
            Text("main")
        }
        .font(.system(size: 11))
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.quaternary, in: Capsule())
    }
}

struct TextKitMaskSpikeRootView: View {
    var body: some View {
        Text("TextKit mask spike")
            .task { await TextKitMaskSpikeAutoRun.run() }
    }
}
#endif

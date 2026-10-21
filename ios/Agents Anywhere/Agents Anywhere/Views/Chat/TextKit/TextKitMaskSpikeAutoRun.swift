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
        ]
        if let data = try? JSONSerialization.data(
            withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent(resultFileName)
            try? data.write(to: url)
        }
    }
}

struct TextKitMaskSpikeRootView: View {
    var body: some View {
        Text("TextKit mask spike")
            .task { await TextKitMaskSpikeAutoRun.run() }
    }
}
#endif

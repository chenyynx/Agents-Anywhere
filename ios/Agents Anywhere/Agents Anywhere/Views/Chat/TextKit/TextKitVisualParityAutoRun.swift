#if DEBUG
import SwiftUI
import UIKit

/// C5 visual-parity gate. Renders the same Markdown fixture through the
/// product's SwiftUI/Textual path and through the TextKit 2 path, then writes
/// both snapshots plus their heights. It never runs in a release build and
/// never changes the product renderer.
@MainActor
enum TextKitVisualParityAutoRunModel {
    static let launchArgument = "aa-textkit-parity"
    static let resultFileName = "textkit-parity.json"
    static let legacyImageName = "parity-legacy.png"
    static let textKitImageName = "parity-textkit.png"
}

struct TextKitVisualParityRootView: View {
    var body: some View {
        TextKitVisualParityHost()
            .ignoresSafeArea()
    }
}

private struct TextKitVisualParityHost: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> TextKitVisualParityController {
        TextKitVisualParityController()
    }

    func updateUIViewController(_ controller: TextKitVisualParityController,
                                context: Context) {}
}

@MainActor
final class TextKitVisualParityController: UIViewController {
    private let contentWidth: CGFloat = 388
    private var didRun = false

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !didRun else { return }
        didRun = true
        Task { await run() }
    }

    private func run() async {
        await wait(600)
        let legacyHeight = await captureLegacy()
        let textKit = captureTextKit()
        writeReport(legacyHeight: legacyHeight,
                    textKitHeight: textKit.height,
                    textKitBlocks: textKit.blocks)
    }

    // MARK: - Legacy path

    private func captureLegacy() async -> CGFloat {
        // The product hosts this view inside a timeline row, not under the
        // status bar. Ignore the parity window's top safe area so the capture
        // compares content, not the 68pt inset the M1 spike also hit.
        let host = UIHostingController(rootView: ChatMarkdownView(
            text: TextKitM3AutoRunModel.fixture,
            isStreaming: false,
            resolvesFileReferences: false)
            .ignoresSafeArea())
        host.overrideUserInterfaceStyle = .light
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = true
        host.view.frame = CGRect(x: 0, y: 0, width: contentWidth, height: 200)
        host.view.backgroundColor = .white
        view.addSubview(host.view)
        host.didMove(toParent: self)
        host.view.layoutIfNeeded()

        // `ChatMarkdownView` parses in a task; the view must be in the window
        // for that task to run (the M1 spike measured 0pt offscreen).
        await wait(2_500)

        let fitting = host.sizeThatFits(in: CGSize(
            width: contentWidth, height: .greatestFiniteMagnitude))
        let height = max(1, ceil(fitting.height))
        host.view.frame = CGRect(x: 0, y: 0, width: contentWidth, height: height)
        host.view.layoutIfNeeded()
        await wait(200)

        let shot = trimmedSnapshot(of: host.view)
        writePNG(shot.image, name: TextKitVisualParityAutoRunModel.legacyImageName)

        host.willMove(toParent: nil)
        host.view.removeFromSuperview()
        host.removeFromParent()
        return shot.height
    }

    // MARK: - TextKit path

    private func captureTextKit() -> (height: CGFloat, blocks: [[String: Any]]) {
        let typography = TimelineChatContentAdapter.typography(
            dynamicType: "UICTContentSizeCategoryL",
            layoutDirection: 0,
            boldText: false)
        guard let document = AssistantMarkdownDocumentParser.make(
            text: TextKitM3AutoRunModel.fixture,
            resolvesFileReferences: false,
            typography: typography) else { return (0, []) }

        let scale = UIScreen.main.scale
        let height = max(1, ceil(AssistantMarkdownTextLayout.measure(
            document, width: contentWidth, displayScale: scale)))
        var blocks: [[String: Any]] = []
        for (index, block) in document.blocks.enumerated() {
            blocks.append([
                "kind": block.kindName,
                "group": document.blockGroups.indices.contains(index)
                    ? document.blockGroups[index] : -1,
                "height": Double(AssistantMarkdownTextLayout.height(
                    of: block, width: contentWidth, displayScale: scale)),
                "spacingAfter": index + 1 < document.blocks.count
                    ? Double(AssistantMarkdownTextLayout.topLevelSpacing(
                        after: index, in: document)) : 0,
            ])
        }
        let cell = AssistantMarkdownCell(
            frame: CGRect(x: 0, y: 0, width: contentWidth, height: height))
        cell.overrideUserInterfaceStyle = .light
        cell.backgroundColor = .white
        view.addSubview(cell)
        cell.configure(document)
        cell.setNeedsLayout()
        cell.layoutIfNeeded()
        cell.contentView.layoutIfNeeded()

        let shot = trimmedSnapshot(of: cell)
        writePNG(shot.image, name: TextKitVisualParityAutoRunModel.textKitImageName)
        cell.removeFromSuperview()
        return (shot.height, blocks)
    }

    // MARK: - Output

    private func snapshot(of view: UIView) -> UIImage {
        let bounds = view.bounds
        let renderer = UIGraphicsImageRenderer(bounds: bounds)
        return renderer.image { _ in
            view.drawHierarchy(in: bounds, afterScreenUpdates: true)
        }
    }

    /// Drop the white margins around the rendered content. The legacy host
    /// reports its window's safe-area inset as blank rows; compare content,
    /// not capture chrome.
    private func trimmedSnapshot(of view: UIView) -> (image: UIImage, height: CGFloat) {
        let image = snapshot(of: view)
        guard let cg = image.cgImage,
              let data = cg.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else {
            return (image, image.size.height)
        }
        let width = cg.width
        let height = cg.height
        let bytesPerRow = cg.bytesPerRow
        let bytesPerPixel = max(1, cg.bitsPerPixel / 8)
        var first = height
        var last = -1
        for y in 0..<height {
            var hasInk = false
            for x in stride(from: 0, to: width, by: 4) {
                let offset = y * bytesPerRow + x * bytesPerPixel
                guard offset + 2 < CFDataGetLength(data) else { continue }
                if bytes[offset] < 245 || bytes[offset + 1] < 245
                    || bytes[offset + 2] < 245 {
                    hasInk = true
                    break
                }
            }
            if hasInk {
                if first == height { first = y }
                last = y
            }
        }
        guard last >= first, let cropped = cg.cropping(
            to: CGRect(x: 0, y: first, width: width,
                       height: last - first + 1)) else {
            return (image, image.size.height)
        }
        return (UIImage(cgImage: cropped, scale: image.scale,
                        orientation: image.imageOrientation),
                CGFloat(last - first + 1) / image.scale)
    }

    private func writePNG(_ image: UIImage, name: String) {
        guard let data = image.pngData() else { return }
        let url = documentsDirectory.appendingPathComponent(name)
        try? data.write(to: url)
    }

    private func writeReport(legacyHeight: CGFloat,
                             textKitHeight: CGFloat,
                             textKitBlocks: [[String: Any]]) {
        let report: [String: Any] = [
            "completed": true,
            "width": Double(contentWidth),
            "legacyHeight": Double(legacyHeight),
            "textKitHeight": Double(textKitHeight),
            "textKitBlocks": textKitBlocks,
            "device": UIDevice.current.name,
            "system": UIDevice.current.systemVersion,
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: documentsDirectory
            .appendingPathComponent(TextKitVisualParityAutoRunModel.resultFileName))
    }

    private var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private func wait(_ milliseconds: Int) async {
        try? await Task.sleep(for: .milliseconds(milliseconds))
    }
}
#endif

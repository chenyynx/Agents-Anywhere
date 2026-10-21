#if DEBUG
import QuartzCore
import SwiftUI
import UIKit

/// C5/M4.3 static gate. It proves the new block kinds (image, display math)
/// and the file-change footer are measured by the engine that renders them,
/// that an image load/failure cannot change the row height, and that the
/// per-width numbers match the block functions.
@MainActor
final class TextKitM4_3AutoRunModel: TimelineCollectionContentProviding {
    static let launchArgument = "aa-textkit-m43"
    static let resultFileName = "textkit-m43.json"

    static let fixture = """
    A short paragraph before the media.

    ![alt](https://example.invalid/m43.png)

    $$ \\int_0^1 x^2\\,dx = \\frac{1}{3} $$

    A closing paragraph after the formula.
    """

    enum Kind { case topPlain, assistantTextKit, bottomPlain }

    struct Entry: Identifiable {
        let id: String
        let kind: Kind
        let text: String
    }

    let entries: [Entry] = [
        Entry(id: "m43-top", kind: .topPlain, text: "A short opening line."),
        Entry(id: "m43-assistant", kind: .assistantTextKit, text: fixture),
        Entry(id: "m43-bottom", kind: .bottomPlain, text: "A short closing line."),
    ]

    var contentGeneration: Int { 1 }
    var itemCount: Int { entries.count }
    weak var controller: TimelineCollectionController?

    private let document: AssistantMarkdownDocument?
    private var failures: [String] = []
    private var report: [String: Any] = [:]
    private var didRun = false

    init() {
        let typography = TimelineChatContentAdapter.typography(
            dynamicType: "UICTContentSizeCategoryL", layoutDirection: 0, boldText: false)
        document = AssistantMarkdownDocumentParser.make(
            text: Self.fixture, resolvesFileReferences: false, typography: typography)
    }

    // MARK: - Content providing

    func item(at index: Int) -> TimelineListItem { .group(entries[index].id) }

    func contentSignature(for item: TimelineListItem) -> TimelineContentSignature {
        guard case .group(let id) = item,
              let entry = entries.first(where: { $0.id == id }) else {
            return .notice(id: "missing", status: .unknown, revision: 0)
        }
        let isAssistant = entry.kind == .assistantTextKit
        return .group(TimelineGroupContentSignature(
            rows: [TimelineRowContentSignature(id: entry.id, revision: 0, updatedSeq: 0)],
            disclosureExpanded: false,
            revealingRowIDs: [],
            inlineNotices: [],
            attachments: [],
            turnAction: isAssistant
                ? TimelineTurnActionSignature(
                    replyIDs: [entry.id],
                    changeIDs: ["m43-change"],
                    startsMidTurn: false,
                    replyRevisions: [0],
                    changeRevisions: [0])
                : nil,
            turnSuppression: TimelineTurnSuppression(
                isRunning: false, hasNewerItems: false, hasPendingUserMessage: false)))
    }

    func heightKey(for item: TimelineListItem, width: CGFloat) -> TimelineHeightKey {
        TimelineHeightKey(itemID: item.itemID,
            contentRevision: contentSignature(for: item).contentRevision,
            width: width,
            dynamicType: "UICTContentSizeCategoryL",
            typographyRevision: 1,
            layoutDirection: 0)
    }

    func estimateKind(for item: TimelineListItem) -> TimelineHeightEstimateKind { .row }
    func heightPolicy(for item: TimelineListItem) -> TimelineRowHeightPolicy { .measured }

    func measurementContent(for item: TimelineListItem) -> TimelineMeasurementContent {
        guard case .group(let id) = item,
              let entry = entries.first(where: { $0.id == id }) else { return .plainText }
        return entry.kind == .assistantTextKit ? .markdown : .plainText
    }

    func rowView(for item: TimelineListItem) -> AnyView {
        guard case .group(let id) = item,
              let entry = entries.first(where: { $0.id == id }) else { return AnyView(EmptyView()) }
        if entry.kind == .assistantTextKit {
            return AnyView(ChatMarkdownView(text: entry.text))
        }
        return AnyView(Text(entry.text)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading))
    }

    func rowIDs(in item: TimelineListItem) -> [String] {
        if case .group(let id) = item { return [id] }
        return []
    }

    func item(containingRow rowID: String) -> TimelineListItem? {
        guard entries.contains(where: { $0.id == rowID }) else { return nil }
        return .group(rowID)
    }

    func interactionState() -> TimelineLayoutInteractionState {
        TimelineLayoutInteractionState()
    }

    func assistantMarkdown(for item: TimelineListItem) -> AssistantMarkdownDocument? {
        guard case .group(let id) = item, id == "m43-assistant" else { return nil }
        return document
    }

    /// A synthetic review + actions footer at the same constants the product
    /// adapter uses. The review view itself is the legacy SwiftUI footer; the
    /// gate only needs its fixed footprint to prove the row arithmetic.
    func assistantFooter(for item: TimelineListItem) -> AssistantFooterHost? {
        guard case .group(let id) = item, id == "m43-assistant" else { return nil }
        let height = AssistantFooterMetrics.contentHeight(
            hasReview: true, hasReplies: true,
            actionRowHeight: SessionTurnActionsRow.rowHeight)
        let view = VStack(alignment: .leading,
                          spacing: AssistantFooterMetrics.groupSpacing) {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.gray.opacity(0.2))
                .frame(height: AssistantFooterMetrics.reviewRowHeight)
            SessionTurnActionsRow(copyText: "A static TextKit reply.",
                                  timestampText: "10:30")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        return AssistantFooterHost(height: height, view: AnyView(view))
    }

    // MARK: - Gate

    func attach(_ controller: TimelineCollectionController) {
        guard self.controller == nil else { return }
        self.controller = controller
        Task { await run() }
    }

    private func run() async {
        guard !didRun else { return }
        didRun = true
        await wait(700)
        guard let controller else {
            failures.append("m43: no controller")
            finish()
            return
        }
        let item = item(at: 1)
        let stored = controller.layout.attributes(for: item.itemID)?.frame.height ?? 0
        let measured = controller.measuredTextKitHeight(for: item) ?? -1
        let estimate = estimateKind(for: item).height
        let pending = controller.layout.pendingMeasurements.contains(item)

        var sample: (content: CGFloat, frame: CGFloat, inWindow: Bool)?
        var sampleWidth: CGFloat = 0
        var assistantCell: AssistantMarkdownCell?
        for _ in 0..<10 {
            controller.collectionView.layoutIfNeeded()
            if let indexPath = controller.indexPath(for: item),
               let cell = controller.collectionView.cellForItem(at: indexPath) {
                controller.collectionView.layoutIfNeeded()
                if let cell = cell as? AssistantMarkdownCell {
                    assistantCell = cell
                }
                let width = cell.contentView.bounds.width
                if width > 0 {
                    let content = cell.contentView.systemLayoutSizeFitting(
                        CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
                        withHorizontalFittingPriority: .required,
                        verticalFittingPriority: .fittingSizeLevel).height
                    sample = (content, cell.bounds.height, cell.window != nil)
                    sampleWidth = width
                    if cell.window != nil, abs(content - stored) <= 1 { break }
                }
            }
            await wait(100)
        }

        let counts = document?.blockCounts ?? [:]
        let blocks = document?.blocks ?? []
        let cellContent = sample?.content ?? -1
        let cellFrame = sample?.frame ?? -1
        let inWindow = sample?.inWindow ?? false

        let footerHeight = assistantFooter(for: item).map {
            AssistantFooterMetrics.groupSpacing + $0.height
        } ?? 0
        let documentOnly = sampleWidth > 0 ? document.map {
            AssistantMarkdownTextLayout.measure(
                $0, width: sampleWidth,
                displayScale: controller.traitCollection.displayScale)
        } : nil
        let footerDelta = documentOnly.map { measured - $0 } ?? -1

        if document == nil { failures.append("m43: document rejected") }
        if counts["image"] != 1 {
            failures.append("m43: \(counts["image"] ?? -1) image blocks, expected 1")
        }
        if counts["math"] != 1 {
            failures.append("m43: \(counts["math"] ?? -1) math blocks, expected 1")
        }
        if blocks.count != 4 {
            failures.append("m43: \(blocks.count) blocks, expected 4")
        }
        if measured < 0 { failures.append("m43: no synchronous measurement") }
        if abs(stored - measured) > 0.5 {
            failures.append("m43: stored \(stored) != measured \(measured)")
        }
        if abs(footerDelta - footerHeight) > 1 {
            failures.append("m43 footer: delta \(footerDelta) vs \(footerHeight)")
        }
        if abs(cellContent - stored) > 1 {
            failures.append("m43: cell content \(cellContent) vs stored \(stored)")
        }
        if cellFrame < cellContent - 0.5 {
            failures.append("m43: cell frame \(cellFrame) clips content \(cellContent)")
        }
        if !inWindow { failures.append("m43: cell is not in a window") }
        if pending { failures.append("m43: row entered pendingMeasurements") }
        if abs(stored - estimate) <= 0.5 {
            failures.append("m43: stored height equals the estimate")
        }

        var overlaps = 0
        let attributes = controller.layout.orderedAttributes
        for (upper, lower) in zip(attributes, attributes.dropFirst()) {
            if upper.frame.maxY > lower.frame.minY + 0.5 { overlaps += 1 }
        }
        if overlaps > 0 { failures.append("m43: \(overlaps) adjacent frames overlap") }

        // Every block view must install the layout's own number.
        var blockHeights: [CGFloat] = []
        if let assistantCell {
            blockHeights = assistantCell.debugBlockHeights
            let expected = blocks.map {
                AssistantMarkdownTextLayout.height(
                    of: $0, width: sampleWidth,
                    displayScale: controller.traitCollection.displayScale)
            }
            if blockHeights.count != expected.count {
                failures.append("m43: \(blockHeights.count) block constraints, expected \(expected.count)")
            } else {
                for (index, pair) in zip(blockHeights, expected).enumerated()
                where abs(pair.0 - pair.1) > 0.5 {
                    failures.append("m43 block \(index): \(pair.0) vs measured \(pair.1)")
                }
            }
            if assistantCell.debugFooterHeight.map({
                abs($0 - (footerHeight - AssistantFooterMetrics.groupSpacing)) > 0.5
            }) ?? true {
                failures.append("m43 footer: cell has no host at the expected height")
            }
        } else {
            failures.append("m43: assistant row is not an AssistantMarkdownCell")
        }

        // The image must keep its reserved box before and after a load/failure.
        var imageHeightBefore: CGFloat = -1
        var imageHeightAfter: CGFloat = -1
        if let assistantCell,
           let imageView = assistantCell.debugArrangedBlockViews
            .compactMap({ $0 as? AssistantImageBlockView }).first {
            imageHeightBefore = imageView.debugHostSize.height
            await wait(2000)
            imageHeightAfter = imageView.debugHostSize.height
        } else {
            failures.append("m43: no image block view")
        }
        let expectedImageHeight = blocks.compactMap { block -> CGFloat? in
            guard case .image(let image) = block else { return nil }
            return AssistantMarkdownTextLayout.height(
                of: block, width: sampleWidth,
                displayScale: controller.traitCollection.displayScale)
        }.first ?? -1
        if imageHeightBefore > 0, abs(imageHeightBefore - expectedImageHeight) > 0.5 {
            failures.append("m43 image: reserved \(imageHeightBefore) vs measured \(expectedImageHeight)")
        }
        if imageHeightBefore != imageHeightAfter {
            failures.append("m43 image: height changed \(imageHeightBefore) -> \(imageHeightAfter)")
        }

        // The same block functions at a wider column: the image is capped at
        // 420 and the math keeps its typographic bounds.
        let wideImageHeight = blocks.compactMap { block -> CGFloat? in
            guard case .image(let image) = block else { return nil }
            return AssistantMarkdownTextLayout.height(
                of: block, width: 760, displayScale: 1)
        }.first ?? -1
        if abs(wideImageHeight - 315) > 0.5 {
            failures.append("m43 image: 760-wide height \(wideImageHeight), expected 315")
        }
        let narrowImageHeight = blocks.compactMap { block -> CGFloat? in
            guard case .image(let image) = block else { return nil }
            return AssistantMarkdownTextLayout.height(
                of: block, width: 360, displayScale: 1)
        }.first ?? -1
        if !(narrowImageHeight > 0 && narrowImageHeight < wideImageHeight) {
            failures.append("m43 image: narrow \(narrowImageHeight) vs wide \(wideImageHeight)")
        }

        if let assistantCell, sampleWidth > 0,
           let screenshot = assistantCell.contentView.snapshotImage() {
            try? screenshot.pngData()?.write(
                to: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("m43-static.png"))
        }

        report["textKit"] = [
            "stored": Double(stored),
            "measured": Double(measured),
            "cellContent": Double(cellContent),
            "estimate": Double(estimate),
            "pending": pending,
            "overlaps": overlaps,
            "blockCounts": counts,
            "blocks": blocks.count,
            "blockHeights": blockHeights.map(Double.init),
            "footerDelta": Double(footerDelta),
            "footerHeight": Double(footerHeight),
            "imageHeightBefore": Double(imageHeightBefore),
            "imageHeightAfter": Double(imageHeightAfter),
            "imageWideHeight": Double(wideImageHeight),
            "imageNarrowHeight": Double(narrowImageHeight),
        ] as [String: Any]
        finish()
    }

    private func finish() {
        report["failures"] = failures
        report["completed"] = true
        report["passed"] = failures.isEmpty
        report["device"] = UIDevice.current.name
        report["system"] = UIDevice.current.systemVersion
        guard let data = try? JSONSerialization.data(
            withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) else { return }
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Self.resultFileName)
        try? data.write(to: url)
    }

    private func wait(_ milliseconds: Int) async {
        try? await Task.sleep(for: .milliseconds(milliseconds))
    }
}

/// Only reachable through the launch argument; the product root is untouched.
struct TextKitM4_3AutoRunRootView: View {
    @State private var model = TextKitM4_3AutoRunModel()

    var body: some View {
        TimelineCollectionView(content: model, measurer: TextKitM4_3NoopMeasurer(),
            onControllerReady: { model.attach($0) })
            .ignoresSafeArea()
    }
}

/// The M4.3 timeline has no hosting row that needs offscreen measurement.
@MainActor
private final class TextKitM4_3NoopMeasurer: TimelineHeightMeasuring {
    var traitOverrides: UITraitCollection? { nil }
    func measure(itemID: String, width: CGFloat) -> CGFloat? { nil }
}

private extension UIView {
    func snapshotImage() -> UIImage? {
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let renderer = UIGraphicsImageRenderer(bounds: bounds)
        return renderer.image { _ in
            drawHierarchy(in: bounds, afterScreenUpdates: true)
        }
    }
}
#endif

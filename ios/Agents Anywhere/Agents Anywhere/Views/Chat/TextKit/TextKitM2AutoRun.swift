#if DEBUG
import Observation
import SwiftUI
import UIKit

/// C5/M2 simulator gate. A dedicated three-row timeline (plain, long static
/// assistant body, plain) that fits the viewport, so the assertion does not
/// depend on scrolling: the TextKit 2 row must be measured synchronously
/// before apply, stored as that measurement, rendered by the matching cell,
/// and never enter pending/estimate/visible-fit paths.
@MainActor
@Observable
final class TextKitM2AutoRunModel: TimelineCollectionContentProviding {
    static let launchArgument = "aa-textkit-m2"
    static let resultFileName = "textkit-m2.json"

    enum Kind: String, CaseIterable { case topPlain, assistantTextKit, bottomPlain }

    struct Entry: Identifiable, Equatable {
        let id: String
        var kind: Kind
        var text: String
        var revision: Int = 0
    }

    private(set) var entries: [Entry] = []
    private(set) var contentGeneration = 0
    weak var controller: TimelineCollectionController?

    @ObservationIgnored private var failures: [String] = []
    @ObservationIgnored private var report: [String: Any] = [:]
    @ObservationIgnored private var didRun = false
    @ObservationIgnored private var initialHeights: [String: CGFloat] = [:]
    @ObservationIgnored private var document: AssistantMarkdownDocument?

    private static let fixture = """
    ## A long static reply

    The measurement has to come from the same engine that draws the text. This paragraph is deliberately long enough to wrap across several lines at the product column width, so a mismatch between measurement and rendering shows up as an overlap or a blank block rather than a rounding difference. It also carries **bold**, `inline code`, and a [web link](https://example.com) inside running text, which the M2 builder maps onto UIKit attributes.

    ## A second section

    A second heading and a second paragraph make the block model exercise the twelve-point inter-block spacing, not just a single text block. The words stay plain Markdown paragraphs; lists, quotes, code blocks and tables deliberately fall back to the hosting cell until M3.

    The closing paragraph keeps the row static. No streaming marker is set, so the controller must measure this document synchronously before the snapshot applies and store exactly that height.
    """

    init() {
        entries = [
            Entry(id: "top-plain", kind: .topPlain, text: "A short opening line."),
            Entry(id: "textkit-assistant-1", kind: .assistantTextKit, text: Self.fixture),
            Entry(id: "bottom-plain", kind: .bottomPlain, text: "A short closing line."),
        ]
        contentGeneration = 1
        document = AssistantMarkdownDocumentParser.make(
            text: Self.fixture,
            resolvesFileReferences: false,
            typography: TimelineChatContentAdapter.typography(
                dynamicType: "UICTContentSizeCategoryL",
                layoutDirection: 0,
                boldText: false))
    }

    // MARK: - Content providing

    var itemCount: Int { entries.count }

    func item(at index: Int) -> TimelineListItem { listItem(entries[index]) }

    func contentSignature(for item: TimelineListItem) -> TimelineContentSignature {
        guard case .group(let id) = item,
              let entry = entries.first(where: { $0.id == id }) else {
            return .notice(id: "missing", status: .unknown, revision: 0)
        }
        return .group(TimelineGroupContentSignature(
            rows: [TimelineRowContentSignature(id: entry.id, revision: entry.revision,
                                               updatedSeq: entry.revision)],
            disclosureExpanded: false,
            inlineNotices: [],
            attachments: [],
            turnAction: nil,
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
        guard let entry = entries.first(where: { $0.id == rowID }) else { return nil }
        return listItem(entry)
    }

    func interactionState() -> TimelineLayoutInteractionState {
        TimelineLayoutInteractionState()
    }

    func assistantMarkdown(for item: TimelineListItem) -> AssistantMarkdownDocument? {
        guard case .group(let id) = item, id == "textkit-assistant-1" else { return nil }
        return document
    }

    // MARK: - Gate

    func attach(_ controller: TimelineCollectionController) {
        guard self.controller == nil else { return }
        self.controller = controller
        controller.onApplyCompleted = { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.captureInitialHeights(controller)
        }
        Task { await run() }
    }

    private func captureInitialHeights(_ controller: TimelineCollectionController) {
        guard initialHeights.isEmpty else { return }
        controller.collectionView.layoutIfNeeded()
        for entry in entries {
            let item = listItem(entry)
            if let height = controller.layout.attributes(for: item.itemID)?.frame.height {
                initialHeights[item.itemID] = height
            }
        }
    }

    private func run() async {
        guard !didRun else { return }
        didRun = true
        await wait(700)
        guard let controller else {
            failures.append("textkit: no controller")
            finish()
            return
        }
        let item = listItem(entries[1])
        let stored = initialHeights[item.itemID]
            ?? controller.layout.attributes(for: item.itemID)?.frame.height ?? 0
        let measured = controller.measuredTextKitHeight(for: item) ?? -1
        let estimate = estimateKind(for: item).height
        let pending = controller.layout.pendingMeasurements.contains(item)

        var sample: (content: CGFloat, frame: CGFloat, inWindow: Bool)?
        for _ in 0..<10 {
            controller.collectionView.layoutIfNeeded()
            if let indexPath = controller.indexPath(for: item),
               let cell = controller.collectionView.cellForItem(at: indexPath) {
                controller.collectionView.layoutIfNeeded()
                let width = cell.contentView.bounds.width
                if width > 0 {
                    let content = cell.contentView.systemLayoutSizeFitting(
                        CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
                        withHorizontalFittingPriority: .required,
                        verticalFittingPriority: .fittingSizeLevel).height
                    sample = (content, cell.bounds.height, cell.window != nil)
                    if cell.window != nil, abs(content - stored) <= 1 { break }
                }
            }
            await wait(100)
        }

        var overlaps = 0
        let attributes = controller.layout.orderedAttributes
        for (upper, lower) in zip(attributes, attributes.dropFirst()) {
            if upper.frame.maxY > lower.frame.minY + 0.5 { overlaps += 1 }
        }

        let typography = TimelineChatContentAdapter.typography(
            dynamicType: "UICTContentSizeCategoryL", layoutDirection: 0, boldText: false)
        let plainDocument = AssistantMarkdownDocumentParser.make(
            text: "A plain paragraph.", resolvesFileReferences: false, typography: typography)
        let listDocument = AssistantMarkdownDocumentParser.make(
            text: "- one\n- two", resolvesFileReferences: false, typography: typography)
        let codeDocument = AssistantMarkdownDocumentParser.make(
            text: "```swift\nlet value = 1\n```", resolvesFileReferences: false, typography: typography)

        let cellContent = sample?.content ?? -1
        let cellFrame = sample?.frame ?? -1
        let inWindow = sample?.inWindow ?? false

        if measured < 0 {
            failures.append("textkit: row has no synchronous document measurement")
        }
        if abs(stored - measured) > 0.5 {
            failures.append("textkit: firstStored \(stored) != measured \(measured)")
        }
        if abs(cellContent - stored) > 1 {
            failures.append("textkit: cell content \(cellContent) vs stored \(stored)")
        }
        if cellFrame < cellContent - 0.5 {
            failures.append("textkit: cell frame \(cellFrame) clips content \(cellContent)")
        }
        if !inWindow { failures.append("textkit: cell is not in a window") }
        if pending { failures.append("textkit: row entered pendingMeasurements") }
        if abs(stored - estimate) <= 0.5 {
            failures.append("textkit: stored height \(stored) equals the estimate \(estimate)")
        }
        if overlaps > 0 { failures.append("textkit: \(overlaps) adjacent frames overlap") }
        if plainDocument == nil { failures.append("textkit parser: plain paragraph rejected") }
        if listDocument != nil { failures.append("textkit parser: list accepted in M2") }
        if codeDocument != nil { failures.append("textkit parser: code block accepted in M2") }

        report["textKit"] = [
            "stored": Double(stored),
            "measured": Double(measured),
            "estimate": Double(estimate),
            "cellContent": Double(cellContent),
            "cellFrame": Double(cellFrame),
            "cellInWindow": inWindow,
            "cellMaterialized": sample != nil,
            "pending": pending,
            "overlaps": overlaps,
            "blocks": document?.blocks.count ?? 0,
            "plainAccepted": plainDocument != nil,
            "listRejected": listDocument == nil,
            "codeRejected": codeDocument == nil,
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

    private func listItem(_ entry: Entry) -> TimelineListItem { .group(entry.id) }

    private func wait(_ milliseconds: Int) async {
        try? await Task.sleep(for: .milliseconds(milliseconds))
    }
}

/// Only reachable through the launch argument; the product root is untouched.
struct TextKitM2AutoRunRootView: View {
    @State private var model = TextKitM2AutoRunModel()

    var body: some View {
        TimelineCollectionView(content: model, measurer: TextKitM2NoopMeasurer(),
            onControllerReady: { model.attach($0) })
            .ignoresSafeArea()
    }
}

/// The M2 timeline has no hosting rows that need offscreen measurement; the
/// protocol still requires a measurer. Returning nil keeps it inert.
@MainActor
private final class TextKitM2NoopMeasurer: TimelineHeightMeasuring {
    var traitOverrides: UITraitCollection? { nil }
    func measure(itemID: String, width: CGFloat) -> CGFloat? { nil }
}
#endif

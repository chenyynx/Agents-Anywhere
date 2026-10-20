#if DEBUG
import Observation
import QuartzCore
import SwiftUI
import UIKit

/// C5/M4 streaming gate. It drives the real collection with a scripted stream:
/// the assistant row grows through eight batches, then commits to a static
/// message. Every batch must be measured by the engine (not the estimate),
/// keep a stable set of reusable block views, and never overlap the next row.
@MainActor
@Observable
final class TextKitM4AutoRunModel: TimelineCollectionContentProviding {
    static let launchArgument = "aa-textkit-m4"
    static let resultFileName = "textkit-m4.json"

    struct Entry: Identifiable {
        let id: String
        var text: String
        var revision: Int
        var isStreaming: Bool
        var reveal: Bool
        var streamingDocument: AssistantStreamingDocument?
        var staticDocument: AssistantMarkdownDocument?
    }

    private(set) var entries: [Entry]
    private(set) var contentGeneration = 1
    weak var controller: TimelineCollectionController?

    @ObservationIgnored private var failures: [String] = []
    @ObservationIgnored private var report: [String: Any] = [:]
    @ObservationIgnored private var didRun = false
    @ObservationIgnored private var builder = AssistantStreamingDocumentBuilder()
    @ObservationIgnored private var batches: [String] = []
    @ObservationIgnored private var typography: TimelineTypographySnapshot

    init() {
        typography = TimelineChatContentAdapter.typography(
            dynamicType: "UICTContentSizeCategoryL",
            layoutDirection: 0,
            boldText: false)
        let fixture = TextKitM3AutoRunModel.fixture
        batches = Self.prefixes(of: fixture, count: 8)
        let first = batches.first ?? ""
        entries = [
            Entry(id: "m4-top", text: "A short opening line.", revision: 0,
                  isStreaming: false, reveal: false,
                  streamingDocument: nil, staticDocument: nil),
            Entry(id: "m4-stream", text: first, revision: 1,
                  isStreaming: true, reveal: true,
                  streamingDocument: builder.make(text: first,
                                                  typography: typography),
                  staticDocument: nil),
            Entry(id: "m4-bottom", text: "A short closing line.", revision: 0,
                  isStreaming: false, reveal: false,
                  streamingDocument: nil, staticDocument: nil),
        ]
    }

    private static func prefixes(of text: String, count: Int) -> [String] {
        let characters = Array(text)
        guard !characters.isEmpty, count > 0 else { return [] }
        return (1...count).map { index in
            String(characters[0..<(characters.count * index / count)])
        }
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
            rows: [TimelineRowContentSignature(id: entry.id,
                                               revision: entry.revision,
                                               updatedSeq: entry.revision)],
            disclosureExpanded: false,
            revealingRowIDs: entry.reveal ? [entry.id] : [],
            inlineNotices: [],
            attachments: [],
            turnAction: nil,
            turnSuppression: TimelineTurnSuppression(
                isRunning: entry.isStreaming,
                hasNewerItems: false,
                hasPendingUserMessage: false)))
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
        return entry.isStreaming || entry.staticDocument != nil ? .markdown : .plainText
    }

    func rowView(for item: TimelineListItem) -> AnyView {
        guard case .group(let id) = item,
              let entry = entries.first(where: { $0.id == id }) else {
            return AnyView(EmptyView())
        }
        if entry.isStreaming || entry.staticDocument != nil {
            return AnyView(ChatMarkdownView(
                text: entry.text,
                isStreaming: entry.reveal,
                resolvesFileReferences: true))
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
        guard case .group(let id) = item,
              let entry = entries.first(where: { $0.id == id }),
              !entry.isStreaming, !entry.reveal else { return nil }
        return entry.staticDocument
    }

    func assistantStreamingDocument(for item: TimelineListItem) -> AssistantStreamingDocument? {
        guard case .group(let id) = item,
              let entry = entries.first(where: { $0.id == id }),
              entry.isStreaming || entry.reveal else { return nil }
        return entry.streamingDocument
    }

    func assistantStreamingReveal(for item: TimelineListItem) -> Bool {
        guard case .group(let id) = item,
              let entry = entries.first(where: { $0.id == id }) else { return false }
        return entry.reveal
    }

    func assistantTurnFooter(for item: TimelineListItem) -> AssistantTurnFooter? { nil }

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
            failures.append("m4: no controller")
            finish()
            return
        }
        let item = listItem(entries[1])
        var samples: [[String: Any]] = []
        var previousHeight: CGFloat = 0
        var lastStreamingHeight: CGFloat = 0
        var expectedStable = 0
        var cellIdentity: ObjectIdentifier?

        // Batch 0 is the document the model starts with; the remaining batches
        // append text and reload. Every batch, including the first, is asserted.
        for (batchIndex, text) in batches.enumerated() {
            if batchIndex > 0 {
                advance(to: text)
                controller.reloadFromContent()
            }
            await wait(220)
            controller.collectionView.layoutIfNeeded()

            guard let entry = entries.first(where: { $0.id == "m4-stream" }),
                  let document = entry.streamingDocument else {
                failures.append("m4 batch \(batchIndex): no streaming document")
                continue
            }
            guard let attributes = controller.layout.attributes(for: item.itemID) else {
                failures.append("m4 batch \(batchIndex): no layout attributes")
                continue
            }
            guard let indexPath = controller.indexPath(for: item),
                  let cell = controller.collectionView.cellForItem(at: indexPath)
                    as? AssistantMarkdownCell else {
                failures.append("m4 batch \(batchIndex): row is not an AssistantMarkdownCell")
                continue
            }
            let width = cell.contentView.bounds.width
            guard width > 0 else {
                failures.append("m4 batch \(batchIndex): zero cell width")
                continue
            }
            let identity = ObjectIdentifier(cell)
            if let cellIdentity, cellIdentity != identity {
                failures.append("m4 batch \(batchIndex): cell instance replaced")
            }
            cellIdentity = identity
            controller.collectionView.layoutIfNeeded()
            let stored = attributes.frame.height
            let measured = AssistantMarkdownTextLayout.measure(
                document.document, width: width,
                displayScale: controller.traitCollection.displayScale)
            let content = cell.contentView.systemLayoutSizeFitting(
                CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
                withHorizontalFittingPriority: .required,
                verticalFittingPriority: .fittingSizeLevel).height
            let arranged = cell.debugArrangedBlockViews.count
            let expectedArranged = document.stableBlockCount
                + (document.tailText.isEmpty ? 0 : 1)

            // The layout stores the ceiling of the measurement; compare
            // against one point so the rounding itself is not a failure.
            if abs(stored - measured) > 1.0 {
                failures.append("m4 batch \(batchIndex): stored \(stored) != measured \(measured)")
            }
            if content > stored + 1 {
                failures.append("m4 batch \(batchIndex): content \(content) clips stored \(stored)")
            }
            if abs(content - stored) > 1.5 {
                failures.append("m4 batch \(batchIndex): content \(content) vs stored \(stored)")
            }
            if arranged != expectedArranged {
                failures.append("m4 batch \(batchIndex): \(arranged) views, expected \(expectedArranged)")
            }
            // The tail host is the only view whose rendered height comes from
            // the other engine. Compare its own fitting height with the
            // constraint the TextKit measurement installed.
            let tailConstraint = cell.debugTailConstraintHeight
            var tailFit = cell.debugTailFitHeight ?? 0
            // Wait for the SwiftUI parse to settle, then require a real value:
            // a present tail host with no rendered height is a failure, not a
            // skipped comparison.
            for _ in 0..<5 {
                if tailConstraint == nil { break }
                if let tailConstraint, tailFit > 0,
                   abs(tailFit - tailConstraint) <= 1.5 { break }
                await wait(50)
                controller.collectionView.layoutIfNeeded()
                tailFit = cell.debugTailFitHeight ?? 0
            }
            if let tailConstraint {
                if tailFit <= 0 {
                    failures.append("m4 batch \(batchIndex): tail host rendered no height")
                } else if abs(tailFit - tailConstraint) > 1.5 {
                    failures.append("m4 batch \(batchIndex): tail fit \(tailFit) vs constraint \(tailConstraint)")
                }
            } else if !document.tailText.isEmpty {
                failures.append("m4 batch \(batchIndex): tail text without a tail host")
            }
            if batchIndex == batches.count - 1,
               cell.debugStableViewsBuilt != document.stableBlockCount {
                failures.append("m4 batch \(batchIndex): built \(cell.debugStableViewsBuilt) stable views for \(document.stableBlockCount) blocks")
            }
            if stored + 0.5 < previousHeight {
                failures.append("m4 batch \(batchIndex): height shrank \(previousHeight) -> \(stored)")
            }
            if cell.debugStableViewsBuilt > document.stableBlockCount {
                failures.append("m4 batch \(batchIndex): rebuilt stable views \(cell.debugStableViewsBuilt) > \(document.stableBlockCount)")
            }
            if document.stableBlockCount < expectedStable {
                failures.append("m4 batch \(batchIndex): stable blocks regressed")
            }
            expectedStable = document.stableBlockCount
            previousHeight = stored
            lastStreamingHeight = stored

            samples.append([
                "batch": batchIndex,
                "textLength": document.document.plainTextLength,
                "tailLength": document.tailText.utf8.count,
                "stableBlocks": document.stableBlockCount,
                "arrangedViews": arranged,
                "stored": Double(stored),
                "measured": Double(measured),
                "content": Double(content),
                "stableViewsBuilt": cell.debugStableViewsBuilt,
                "tailUpdates": cell.debugTailUpdates,
                "tailFit": Double(tailFit),
                "tailConstraint": Double(cell.debugTailConstraintHeight ?? -1),
            ])
        }

        if expectedStable <= 0 {
            failures.append("m4: the stream never promoted a stable block")
        }

        // Phase 1: the real completion frame. The wire item is done but the
        // final glyphs are still revealing; the row must stay on the TextKit
        // cell (with its tail host), not fall back to a fresh hosting view.
        finishReveal()
        controller.reloadFromContent()
        await wait(250)
        controller.collectionView.layoutIfNeeded()
        guard let revealingEntry = entries.first(where: { $0.id == "m4-stream" }),
              let revealingDocument = revealingEntry.streamingDocument else {
            failures.append("m4 done+revealing: no streaming document")
            finish()
            return
        }
        guard let revealingAttributes = controller.layout.attributes(for: item.itemID) else {
            failures.append("m4 done+revealing: no layout attributes")
            finish()
            return
        }
        guard let revealingIndexPath = controller.indexPath(for: item),
              let revealingCell = controller.collectionView.cellForItem(at: revealingIndexPath)
                as? AssistantMarkdownCell else {
            failures.append("m4 done+revealing: row left the TextKit cell")
            finish()
            return
        }
        if let cellIdentity, cellIdentity != ObjectIdentifier(revealingCell) {
            failures.append("m4 done+revealing: cell instance replaced")
        }
        let revealingWidth = revealingCell.contentView.bounds.width
        let revealingStored = revealingAttributes.frame.height
        let revealingMeasured = AssistantMarkdownTextLayout.measure(
            revealingDocument.document, width: revealingWidth,
            displayScale: controller.traitCollection.displayScale)
        if abs(revealingStored - revealingMeasured) > 1.0 {
            failures.append("m4 done+revealing: stored \(revealingStored) != measured \(revealingMeasured)")
        }
        if abs(revealingStored - lastStreamingHeight) > 1.5 {
            failures.append("m4 done+revealing: height jumped \(lastStreamingHeight) -> \(revealingStored)")
        }

        // Phase 2: the reveal clock settles; the same row becomes static.
        settleStatic()
        controller.reloadFromContent()
        await wait(250)
        controller.collectionView.layoutIfNeeded()
        guard let entry = entries.first(where: { $0.id == "m4-stream" }),
              let staticDocument = entry.staticDocument else {
            failures.append("m4 completion: no static document")
            finish()
            return
        }
        guard let attributes = controller.layout.attributes(for: item.itemID) else {
            failures.append("m4 completion: no layout attributes")
            finish()
            return
        }
        guard let indexPath = controller.indexPath(for: item),
              let cell = controller.collectionView.cellForItem(at: indexPath)
                as? AssistantMarkdownCell else {
            failures.append("m4 completion: row is not an AssistantMarkdownCell")
            finish()
            return
        }
        let width = cell.contentView.bounds.width
        let stored = attributes.frame.height
        let measured = AssistantMarkdownTextLayout.measure(
            staticDocument, width: width,
            displayScale: controller.traitCollection.displayScale)
        if abs(stored - measured) > 1.0 {
            failures.append("m4 completion: stored \(stored) != measured \(measured)")
        }
        if abs(stored - revealingStored) > 1.5 {
            failures.append("m4 completion: height jumped \(revealingStored) -> \(stored)")
        }
        if abs(revealingMeasured - measured) > 0.5 {
            failures.append("m4 completion: stream/static measurement differ")
        }
        if abs(cell.contentView.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel).height - stored) > 1.5 {
            failures.append("m4 completion: cell content does not match stored height")
        }
        var overlaps = 0
        let attributesList = controller.layout.orderedAttributes
        for (upper, lower) in zip(attributesList, attributesList.dropFirst()) {
            if upper.frame.maxY > lower.frame.minY + 0.5 { overlaps += 1 }
        }
        if overlaps > 0 { failures.append("m4: \(overlaps) adjacent frames overlap") }

        report["batches"] = samples
        report["doneRevealing"] = [
            "stored": Double(revealingStored),
            "measured": Double(revealingMeasured),
            "arrangedViews": revealingCell.debugArrangedBlockViews.count,
            "tailFit": Double(revealingCell.debugTailFitHeight ?? -1),
            "sameCell": cellIdentity == ObjectIdentifier(revealingCell),
        ] as [String: Any]
        report["completion"] = [
            "stored": Double(stored),
            "measured": Double(measured),
            "lastStreamingHeight": Double(lastStreamingHeight),
            "stableViewsBuilt": cell.debugStableViewsBuilt,
            "tailUpdates": cell.debugTailUpdates,
            "overlaps": overlaps,
            "sameCellAsDoneRevealing": ObjectIdentifier(cell) == ObjectIdentifier(revealingCell),
        ] as [String: Any]
        finish()
    }

    private func advance(to text: String) {
        guard let index = entries.firstIndex(where: { $0.id == "m4-stream" }) else { return }
        entries[index].text = text
        entries[index].revision += 1
        entries[index].reveal = true
        entries[index].streamingDocument = builder.make(
            text: text, typography: typography)
        contentGeneration += 1
    }

    /// The real completion frame: the wire item is done while the final glyphs
    /// are still revealing. The streaming document must stay available.
    private func finishReveal() {
        guard let index = entries.firstIndex(where: { $0.id == "m4-stream" }) else { return }
        entries[index].revision += 1
        entries[index].isStreaming = false
        entries[index].reveal = true
        entries[index].streamingDocument = builder.make(
            text: entries[index].text, typography: typography)
        contentGeneration += 1
    }

    /// The reveal clock has settled; the row hands over to the static body.
    private func settleStatic() {
        guard let index = entries.firstIndex(where: { $0.id == "m4-stream" }) else { return }
        entries[index].revision += 1
        entries[index].reveal = false
        entries[index].streamingDocument = nil
        entries[index].staticDocument = AssistantMarkdownDocumentParser.make(
            text: entries[index].text,
            resolvesFileReferences: true,
            typography: typography)
        contentGeneration += 1
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
struct TextKitM4AutoRunRootView: View {
    @State private var model = TextKitM4AutoRunModel()

    var body: some View {
        TimelineCollectionView(content: model, measurer: TextKitM4NoopMeasurer(),
            onControllerReady: { model.attach($0) })
            .ignoresSafeArea()
    }
}

@MainActor
private final class TextKitM4NoopMeasurer: TimelineHeightMeasuring {
    var traitOverrides: UITraitCollection? { nil }
    func measure(itemID: String, width: CGFloat) -> CGFloat? { nil }
}
#endif

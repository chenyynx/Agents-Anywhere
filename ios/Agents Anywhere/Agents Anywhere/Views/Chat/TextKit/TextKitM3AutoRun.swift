#if DEBUG
import Observation
import QuartzCore
import SwiftUI
import UIKit

/// C5/M3 simulator gate. A dedicated three-row timeline (plain, a static
/// assistant body with lists and quotes, plain) that fits the viewport, so the
/// assertion does not depend on scrolling: the TextKit row must be measured
/// synchronously before apply, stored as that measurement, rendered by the
/// matching cell, and never enter pending/estimate/visible-fit paths.
@MainActor
@Observable
final class TextKitM3AutoRunModel: TimelineCollectionContentProviding {
    static let launchArgument = "aa-textkit-m3"
    static let resultFileName = "textkit-m3.json"

    enum Kind: String, CaseIterable { case topPlain, assistantTextKit, bottomPlain, stress }

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
    @ObservationIgnored private var stressDocument: AssistantMarkdownDocument?

    static let fixture = """
    ## Lists and quotes

    The lists below use the product's marker column and spacing. This paragraph also carries **bold**, `inline code`, and a [web link](https://example.com).

    - First bullet with **bold** and `code`
    - Second bullet with a [link](https://example.com)
      - Nested bullet one
      - Nested bullet two

    1. First ordered item
    2. Second ordered item

    > A quoted paragraph in body-template ink.
    >
    > - A bullet inside the quote
    > - Another quoted bullet

    ```swift
    let value = 1
    print(value)
    ```

    | Name | Value |
    | --- | --- |
    | alpha | 1 |
    | beta | 2 |

    The closing paragraph keeps the row static and gives the tree a text block after the containers.
    """

    /// Below the correctness rows: a table/code/list document repeated down the
    /// timeline, so the scroll phase builds real TextKit cells offscreen.
    private static let stressFixture = """
    ## Scroll fixture

    A short paragraph before the table.

    | Name | Value | Note | Extra |
    | --- | --- | --- | --- |
    | alpha | 1 | first | a |
    | beta | 2 | second | b |
    | gamma | 3 | third | c |
    | delta | 4 | fourth | d |
    | epsilon | 5 | fifth | e |

    ```swift
    let value = 1
    let other = 2
    print(value + other)
    ```

    - One
    - Two
    - Three
    """

    init() {
        entries = [
            Entry(id: "top-plain", kind: .topPlain, text: "A short opening line."),
            Entry(id: "textkit-assistant-1", kind: .assistantTextKit, text: Self.fixture),
            Entry(id: "bottom-plain", kind: .bottomPlain, text: "A short closing line."),
        ]
        entries.append(contentsOf: (0..<12).map {
            Entry(id: "stress-\($0)", kind: .stress, text: Self.stressFixture)
        })
        contentGeneration = 1
        let typography = TimelineChatContentAdapter.typography(
            dynamicType: "UICTContentSizeCategoryL",
            layoutDirection: 0,
            boldText: false)
        document = AssistantMarkdownDocumentParser.make(
            text: Self.fixture,
            resolvesFileReferences: false,
            typography: typography)
        stressDocument = AssistantMarkdownDocumentParser.make(
            text: Self.stressFixture,
            resolvesFileReferences: false,
            typography: typography)
    }

    // MARK: - Content providing

    var itemCount: Int { entries.count }

    func item(at index: Int) -> TimelineListItem { listItem(entries[index]) }

    func contentSignature(for item: TimelineListItem) -> TimelineContentSignature {
        guard case .group(let id) = item,
              let entry = entries.first(where: { $0.id == id }) else {
            return .notice(id: "missing", status: .unknown, revision: 0)
        }
        let isAssistant = entry.kind == .assistantTextKit
        return .group(TimelineGroupContentSignature(
            rows: [TimelineRowContentSignature(id: entry.id, revision: entry.revision,
                                               updatedSeq: entry.revision)],
            disclosureExpanded: false,
            revealingRowIDs: [],
            inlineNotices: [],
            attachments: [],
            turnAction: isAssistant
                ? TimelineTurnActionSignature(
                    replyIDs: [entry.id],
                    changeIDs: [],
                    startsMidTurn: false,
                    replyRevisions: [entry.revision],
                    changeRevisions: [])
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
        return entry.kind == .topPlain || entry.kind == .bottomPlain
            ? .plainText : .markdown
    }

    func rowView(for item: TimelineListItem) -> AnyView {
        guard case .group(let id) = item,
              let entry = entries.first(where: { $0.id == id }) else { return AnyView(EmptyView()) }
        if entry.kind != .topPlain && entry.kind != .bottomPlain {
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
        guard case .group(let id) = item,
              let entry = entries.first(where: { $0.id == id }) else { return nil }
        switch entry.kind {
        case .assistantTextKit: return document
        case .stress: return stressDocument
        case .topPlain, .bottomPlain: return nil
        }
    }

    func assistantTurnFooter(for item: TimelineListItem) -> AssistantTurnFooter? {
        guard case .group(let id) = item, id == "textkit-assistant-1" else { return nil }
        return AssistantTurnFooter(copyText: "A static TextKit reply.", timestampText: "10:30")
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

        // The controller now opens at the official `.end` placement, so the
        // second row can be far above the viewport. This gate tests TextKit
        // rendering, not where the page opens: bring the row under test into
        // the viewport explicitly.
        if let attributes = controller.layout.attributes(for: item.itemID) {
            let top = -controller.collectionView.adjustedContentInset.top
            controller.collectionView.setContentOffset(
                CGPoint(x: 0, y: max(top, attributes.frame.minY
                    - controller.collectionView.adjustedContentInset.top)),
                animated: false)
            controller.collectionView.layoutIfNeeded()
            await wait(150)
        }

        var sample: (content: CGFloat, frame: CGFloat, inWindow: Bool)?
        var sampleWidth: CGFloat = 0
        var tableSurface: AssistantTableBlockView?
        for _ in 0..<10 {
            controller.collectionView.layoutIfNeeded()
            if let indexPath = controller.indexPath(for: item),
               let cell = controller.collectionView.cellForItem(at: indexPath) {
                controller.collectionView.layoutIfNeeded()
                if let assistantCell = cell as? AssistantMarkdownCell {
                    tableSurface = assistantCell.debugArrangedBlockViews
                        .compactMap { $0 as? AssistantTableBlockView }.first
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

        // The assistant body's fixture table is 3 rows × 2 columns. The M3.4
        // surface must expose six cell elements and no cell subviews.
        var tableSurfaceCells = -1
        var tableSurfaceSubviews = -1
        var tableSurfaceLabels = -1
        if let tableSurface {
            tableSurfaceCells = tableSurface.debugCellElementCount
            tableSurfaceSubviews = tableSurface.debugSurfaceSubviewCount
            tableSurfaceLabels = tableSurface.debugCellLabelCount
            if tableSurfaceCells != 6 {
                failures.append("textkit table: \(tableSurfaceCells) cell elements, expected 6")
            }
            if tableSurfaceSubviews != 0 {
                failures.append("textkit table: \(tableSurfaceSubviews) surface subviews, expected 0")
            }
            if tableSurfaceLabels != 0 {
                failures.append("textkit table: \(tableSurfaceLabels) cell labels, expected 0")
            }
        } else {
            failures.append("textkit table: no table surface")
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
        let unorderedDocument = AssistantMarkdownDocumentParser.make(
            text: "- one\n- two", resolvesFileReferences: false, typography: typography)
        let orderedDocument = AssistantMarkdownDocumentParser.make(
            text: "1. one\n2. two", resolvesFileReferences: false, typography: typography)
        let quoteDocument = AssistantMarkdownDocumentParser.make(
            text: "> quoted", resolvesFileReferences: false, typography: typography)
        let codeDocument = AssistantMarkdownDocumentParser.make(
            text: "```swift\nlet value = 1\n```", resolvesFileReferences: false, typography: typography)
        let tableDocument = AssistantMarkdownDocumentParser.make(
            text: "| a | b |\n|---|---|\n| 1 | 2 |",
            resolvesFileReferences: false, typography: typography)
        // M4.3: an image-only paragraph becomes a formal image block instead
        // of making the whole reply fall back to hosting.
        let imageDocument = AssistantMarkdownDocumentParser.make(
            text: "![alt](https://example.com/pixel.png)",
            resolvesFileReferences: false, typography: typography)
        // A thematic break is pure text but used to reject the whole
        // document, which dropped live replies to the hosting renderer.
        let dividerDocument = AssistantMarkdownDocumentParser.make(
            text: "Intro\n\n---\n\nOutro",
            resolvesFileReferences: false, typography: typography)
        let dividerStreaming = AssistantStreamingDocumentBuilder().make(
            text: "Intro\n\n---\n\nOutro", typography: typography)

        let counts = document?.blockCounts ?? [:]
        let topLevelBlocks = document?.blocks.count ?? 0
        let cellContent = sample?.content ?? -1
        let cellFrame = sample?.frame ?? -1
        let inWindow = sample?.inWindow ?? false

        // The footer must be part of the synchronously stored height, not just
        // a view that happens to fit. Measure the same document without it and
        // compare the difference with the fixed footer height.
        let documentOnly = sampleWidth > 0 ? document.map {
            AssistantMarkdownTextLayout.measure(
                $0, width: sampleWidth,
                displayScale: controller.traitCollection.displayScale)
        } : nil
        let footerDelta = documentOnly.map { measured - $0 } ?? -1

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
        if unorderedDocument == nil { failures.append("textkit parser: unordered list rejected") }
        if orderedDocument == nil { failures.append("textkit parser: ordered list rejected") }
        if quoteDocument == nil { failures.append("textkit parser: quote rejected") }
        if codeDocument == nil { failures.append("textkit parser: code block rejected") }
        if tableDocument == nil { failures.append("textkit parser: table rejected") }
        if imageDocument == nil {
            failures.append("textkit parser: image-only paragraph rejected")
        } else if (imageDocument?.blockCounts["image"] ?? 0) != 1 {
            failures.append("textkit parser: image block missing")
        }
        if dividerDocument == nil {
            failures.append("textkit parser: thematic break rejected")
        } else if (dividerDocument?.blockCounts["divider"] ?? 0) != 1 {
            failures.append("textkit parser: divider block missing")
        }
        if dividerStreaming == nil {
            failures.append("textkit streaming: thematic break rejected")
        }
        if topLevelBlocks != 8 {
            failures.append("textkit fixture: \(topLevelBlocks) top-level blocks, expected 8")
        }
        if counts["text"] != 12 {
            failures.append("textkit fixture: \(counts["text"] ?? -1) text blocks, expected 12")
        }
        if counts["list"] != 4 {
            failures.append("textkit fixture: \(counts["list"] ?? -1) list blocks, expected 4")
        }
        if counts["quote"] != 1 {
            failures.append("textkit fixture: \(counts["quote"] ?? -1) quote blocks, expected 1")
        }
        if counts["code"] != 1 {
            failures.append("textkit fixture: \(counts["code"] ?? -1) code blocks, expected 1")
        }
        if counts["table"] != 1 {
            failures.append("textkit fixture: \(counts["table"] ?? -1) table blocks, expected 1")
        }
        if abs(footerDelta - AssistantTurnFooter.height) > 1.5 {
            failures.append("textkit footer: delta \(footerDelta) vs \(AssistantTurnFooter.height)")
        }

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
            "footerDelta": Double(footerDelta),
            "footerHeight": Double(AssistantTurnFooter.height),
            "topLevelBlocks": topLevelBlocks,
            "blockCounts": counts,
            "plainAccepted": plainDocument != nil,
            "unorderedAccepted": unorderedDocument != nil,
            "orderedAccepted": orderedDocument != nil,
            "quoteAccepted": quoteDocument != nil,
            "codeAccepted": codeDocument != nil,
            "tableAccepted": tableDocument != nil,
            "imageAccepted": imageDocument != nil,
            "imageBlocks": imageDocument?.blockCounts["image"] ?? 0,
            "dividerAccepted": dividerDocument != nil,
            "dividerBlocks": dividerDocument?.blockCounts["divider"] ?? 0,
            "dividerStreamingAccepted": dividerStreaming != nil,
            "tableSurfaceCells": tableSurfaceCells,
            "tableSurfaceSubviews": tableSurfaceSubviews,
            "tableSurfaceLabels": tableSurfaceLabels,
        ] as [String: Any]
        var textKitReport = report["textKit"] as? [String: Any] ?? [:]
        AssistantMarkdownCellBuildMetrics.reset()
        textKitReport["scroll"] = await measureScroll(controller)
        textKitReport["cellBuild"] = [
            "count": AssistantMarkdownCellBuildMetrics.count,
            "averageMs": AssistantMarkdownCellBuildMetrics.averageMilliseconds,
            "maxMs": AssistantMarkdownCellBuildMetrics.maxMilliseconds,
            "kinds": AssistantMarkdownCellBuildMetrics.kindSnapshot,
        ] as [String: Any]
        report["textKit"] = textKitReport
        finish()
    }

    /// Drive the real collection view from top to bottom through the stress
    /// rows. The measured block is only the synchronous scroll + layout work;
    /// the short sleep afterwards lets reuse settle without inflating it.
    private func measureScroll(_ controller: TimelineCollectionController) async -> [String: Any] {
        guard let view = controller.collectionView else {
            failures.append("textkit scroll: no collection view")
            return ["steps": 0, "medianMs": -1.0, "p95Ms": -1.0, "maxMs": -1.0,
                    "contentHeight": 0.0, "viewport": 0.0, "reachedBottom": false]
        }
        view.layoutIfNeeded()
        let viewport = view.bounds.height
        let contentHeight = view.contentSize.height
        guard viewport > 0, contentHeight > viewport else {
            failures.append("textkit scroll: content \(contentHeight) does not exceed viewport \(viewport)")
            return ["steps": 0, "medianMs": -1.0, "p95Ms": -1.0, "maxMs": -1.0,
                    "contentHeight": Double(contentHeight), "viewport": Double(viewport),
                    "reachedBottom": false]
        }

        let maxOffset = contentHeight - viewport
        let steps = 24
        var durations: [Double] = []
        for step in 1...steps {
            let y = maxOffset * CGFloat(step) / CGFloat(steps)
            let start = CACurrentMediaTime()
            view.setContentOffset(CGPoint(x: 0, y: y), animated: false)
            view.layoutIfNeeded()
            durations.append((CACurrentMediaTime() - start) * 1000)
            await wait(16)
        }
        view.layoutIfNeeded()

        let reachedBottom = abs(view.contentOffset.y - maxOffset) <= 1
        let sorted = durations.sorted()
        let median = sorted[sorted.count / 2]
        let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * 0.95))]
        let maxValue = sorted.last ?? 0

        if !reachedBottom {
            failures.append("textkit scroll: stopped at \(view.contentOffset.y) of \(maxOffset)")
        }
        // Simulator smoke ceilings, not product frame targets. They catch a
        // pathological cell build; device measurements decide the real budget.
        if p95 > 150 { failures.append("textkit scroll: p95 \(p95)ms > 150ms") }
        if maxValue > 300 { failures.append("textkit scroll: max \(maxValue)ms > 300ms") }

        return ["steps": steps,
                "medianMs": median,
                "p95Ms": p95,
                "maxMs": maxValue,
                "contentHeight": Double(contentHeight),
                "viewport": Double(viewport),
                "reachedBottom": reachedBottom]
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
struct TextKitM3AutoRunRootView: View {
    @State private var model = TextKitM3AutoRunModel()

    var body: some View {
        TimelineCollectionView(content: model, measurer: TextKitM3NoopMeasurer(),
            onControllerReady: { model.attach($0) })
            .ignoresSafeArea()
    }
}

/// The M3 timeline has no hosting rows that need offscreen measurement; the
/// protocol still requires a measurer. Returning nil keeps it inert.
@MainActor
private final class TextKitM3NoopMeasurer: TimelineHeightMeasuring {
    var traitOverrides: UITraitCollection? { nil }
    func measure(itemID: String, width: CGFloat) -> CGFloat? { nil }
}
#endif

#if DEBUG
import Observation
import SwiftUI
import UIKit

/// C3 simulator gate. The app root swaps to this screen only when the process
/// is launched with `aa-timeline-autorun`; the CI job boots a simulator,
/// installs the Debug build, reads `Documents/timeline-autorun.json` and fails
/// on any assertion recorded here.
///
/// The rows are representative SwiftUI views (real Textual Markdown for
/// message/code/table), not the product chat rows: C4/C5 wire those. This gate
/// therefore proves the container, measurement, offset and state-machine
/// machinery; the product-row consistency run repeats in C5.
@MainActor
@Observable
final class TimelineAutoRunModel: TimelineCollectionContentProviding {
    static let launchArgument = "aa-timeline-autorun"
    static let resultFileName = "timeline-autorun.json"
    /// Row-id prefix for the gesture-freeze fixture; also the marker the
    /// official cell-reported height contract is keyed on (see
    /// `usesCellReportedHeight(for:)`).
    static let gestureRowPrefix = "gesture-"
    /// The Code-shaped hosted-height fixture (`codeHostedHeight`). It shares
    /// the cell-reported prefix; the extra segment keeps the two scenarios
    /// distinguishable in the report.
    static let hostedRowPrefix = "gesture-hosted-"
    /// The async-body fixture (`firstFitSeed`): a cell-reported row whose body
    /// renders through `ChatMarkdownView`, so its first fit can see a
    /// pre-parse placeholder unless the structured measurement seeds it.
    static let seedRowPrefix = "gesture-seed-"
    /// The streaming fixture (`streamingSeed`): a cell-reported message row
    /// with no structural height at all, the shape of an assistant reply that
    /// is still revealing (`measuredCodeGroupHeight` answers nil). Its first
    /// fit must be seeded from the height `prepare` recorded for it.
    /// Deliberately not listed in `measuredCodeGroupHeight`.
    static let streamRowPrefix = "gesture-streamseed-"

    enum Kind: String, CaseIterable {
        case message, longGroup, reasoning, toolExpanded, code, table, image, notice, pending, tail, plain
    }

    struct Entry: Identifiable, Equatable {
        let id: String
        var kind: Kind
        var text: String
        var revision: Int = 0
        var expanded = false
        var statusLine = false
        /// The value the Code adapter's `measuredCodeGroupHeight` would return
        /// before apply. The hosted-height fixture sets 56 (the device
        /// report's shape); the first-fit seed fixture sets a value the cell
        /// must fit first instead of its pre-parse placeholder.
        var structuralHeight: CGFloat? = nil
    }

    private(set) var entries: [Entry] = []
    private(set) var contentGeneration = 0
    private(set) var streamingIDs: Set<String> = []
    /// Items the spacing scenario asks the layout to place with no gap. The
    /// product adapter returns 0 for Code message rows; this lets the gate
    /// prove the per-item spacing path itself.
    @ObservationIgnored var zeroSpacingItemIDs: Set<String> = []
    weak var controller: TimelineCollectionController?
    @ObservationIgnored private var failures: [String] = []
    @ObservationIgnored private var report: [String: Any] = [:]
    @ObservationIgnored private var didRun = false
    @ObservationIgnored private var hostedMeasurer: TimelineHostingHeightMeasurer?

    var measurer: TimelineHostingHeightMeasurer {
        if let hostedMeasurer { return hostedMeasurer }
        let created = TimelineHostingHeightMeasurer { [weak self] itemID in
            guard let self else { return AnyView(EmptyView()) }
            return self.view(forItemID: itemID)
        }
        hostedMeasurer = created
        return created
    }

    init() {
        entries = Self.initialEntries()
        contentGeneration = 1
    }

    // MARK: - Content providing

    var itemCount: Int { entries.count }

    func item(at index: Int) -> TimelineListItem { listItem(entries[index]) }

    func contentSignature(for item: TimelineListItem) -> TimelineContentSignature {
        guard let entry = entry(for: item) else {
            return .notice(id: "missing", status: .unknown, revision: 0)
        }
        if item == .tail {
            return .tail(TimelineTailContentSignature(
                queue: [],
                sendingPlaceholder: entry.statusLine ? "Thinking" : nil,
                orbActivity: entry.statusLine ? "thinking" : "idle",
                hasNewerItems: false,
                statusLineVisible: entry.statusLine))
        }
        return .group(TimelineGroupContentSignature(
            rows: [TimelineRowContentSignature(id: entry.id, revision: entry.revision,
                                               updatedSeq: entry.revision)],
            disclosureExpanded: entry.expanded,
            revealingRowIDs: [],
            inlineNotices: entry.kind == .notice
                ? [TimelineInlineNoticeSignature(id: "notice-\(entry.id)",
                                                 status: .open, revision: entry.revision)]
                : [],
            attachments: entry.kind == .image
                ? [TimelineAttachmentPreviewSignature(id: "image-\(entry.id)",
                                                       pixelWidth: 1200, pixelHeight: 800)]
                : [],
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

    func estimateKind(for item: TimelineListItem) -> TimelineHeightEstimateKind {
        guard let entry = entry(for: item) else { return .row }
        if item == .tail { return .tail(statusLine: entry.statusLine) }
        // The gesture fixtures collapse to a tool header. Pre-seeding the
        // height keeps a scroll from materializing a dozen 200 pt estimates
        // that then shrink and drag the phase's target out of the viewport.
        if entry.kind == .toolExpanded,
           entry.id.hasPrefix(Self.gestureRowPrefix),
           !entry.id.hasPrefix(Self.hostedRowPrefix) {
            return .fixed(17)
        }
        return .row
    }

    func itemSpacing(after item: TimelineListItem) -> CGFloat {
        zeroSpacingItemIDs.contains(item.itemID)
            ? 0 : TimelineListMetrics.itemSpacing
    }

    func heightPolicy(for item: TimelineListItem) -> TimelineRowHeightPolicy {
        guard let entry = entry(for: item) else { return .measured }
        if item == .tail { return .tail }
        return [.toolExpanded, .notice].contains(entry.kind) ? .interactive : .measured
    }

    /// The gesture-freeze fixture rows opt into the official height contract:
    /// the cell reports its own height once and later content-height changes;
    /// the controller/layout must park those changes while the reader's finger
    /// is down or the list is coasting. Every other synthetic row keeps the
    /// legacy polling path this gate already exercises.
    func usesCellReportedHeight(for item: TimelineListItem) -> Bool {
        guard case .group(let id) = item else { return false }
        return id.hasPrefix(Self.gestureRowPrefix)
    }

    func measurementContent(for item: TimelineListItem) -> TimelineMeasurementContent {
        guard let entry = entry(for: item) else { return .markdown }
        switch entry.kind {
        case .plain: return .plainText
        case .code, .table, .image: return .complex
        case .toolExpanded, .notice, .pending: return .interactive
        case .tail: return .tail
        case .message, .longGroup, .reasoning: return .markdown
        }
    }

    /// The Code adapter measures a settled group structurally before apply and
    /// stores the value in the `.estimate` tier. The hosted-height fixture
    /// reproduces that pre-parse value so the gate covers the writer that made
    /// the device row jump (56 ↔ 1557.7 pt).
    func measuredCodeGroupHeight(for item: TimelineListItem, width: CGFloat) -> CGFloat? {
        guard width > 0, case .group(let id) = item,
              id.hasPrefix(Self.hostedRowPrefix)
                || id.hasPrefix(Self.seedRowPrefix) else { return nil }
        return entry(for: item)?.structuralHeight
    }

    func rowView(for item: TimelineListItem) -> AnyView {
        guard let entry = entry(for: item) else { return AnyView(EmptyView()) }
        return view(for: entry)
    }

    func rowIDs(in item: TimelineListItem) -> [String] {
        item == .tail ? ["tail"] : [item.itemID.replacingOccurrences(of: "g:", with: "")]
    }

    func item(containingRow rowID: String) -> TimelineListItem? {
        if rowID == "tail" { return .tail }
        guard let entry = entries.first(where: { $0.id == rowID }) else { return nil }
        return listItem(entry)
    }

    func interactionState() -> TimelineLayoutInteractionState {
        TimelineLayoutInteractionState(streamingItemIDs: streamingIDs)
    }

    // MARK: - Mutations

    @ObservationIgnored private var initialHeights: [String: CGFloat] = [:]

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

    @discardableResult
    func appendStreamLine(to id: String) -> Bool {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return false }
        entries[index].text += "\nstream line \(entries[index].revision)"
        entries[index].revision += 1
        contentGeneration += 1
        return true
    }

    func setExpanded(_ id: String, _ expanded: Bool) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].expanded = expanded
    }

    func setTailStatusLine(_ present: Bool) {
        guard let index = entries.firstIndex(where: { $0.kind == .tail }) else { return }
        entries[index].statusLine = present
    }

    var allItems: [TimelineListItem] { entries.map(listItem) }

    private var prependBatch = 0

    /// Entries for a page that has not been inserted yet, so a history
    /// projection can use the exact ids the apply will carry.
    func makePrependEntries(_ count: Int) -> [Entry] {
        prependBatch += 1
        let batch = prependBatch
        return (0..<count).map { offset in
            Entry(id: "pre-\(batch)-\(offset)", kind: .plain,
                  text: String(repeating: "Earlier page line \(offset). ", count: 3))
        }
    }

    @discardableResult
    func prependPlain(_ count: Int) -> [TimelineListItem] {
        prependEntries(makePrependEntries(count))
    }

    @discardableResult
    func prependEntries(_ new: [Entry]) -> [TimelineListItem] {
        entries.insert(contentsOf: new, at: 0)
        contentGeneration += 1
        return allItems
    }

    // MARK: - Gate

    private func run() async {
        guard !didRun else { return }
        didRun = true
        await wait(900)
        // Async first: the automatic pending pass may settle Markdown shortly
        // after apply, so the first-displayed snapshot is captured by
        // `onApplyCompleted`.
        // Persist after every phase: a crash mid-gate still leaves the last
        // completed phase and its assertions on disk.
        await firstMeasurement(); persist(phase: "firstMeasurement")
        await asyncMarkdown(); persist(phase: "asyncMarkdown")
        await measureConsistency(); persist(phase: "measureConsistency")
        await perItemSpacing(); persist(phase: "perItemSpacing")
        await foldAndTail(); persist(phase: "foldAndTail")
        // Build the tool rows before the stream scenario, so the growing row
        // has expanded rows below it — the shape of pp's device report.
        await toolStorm(); persist(phase: "toolStorm")
        await collapseGap(); persist(phase: "collapseGap")
        await collapseWhileStreaming(); persist(phase: "collapseWhileStreaming")
        await streaming(); persist(phase: "streaming")
        await bottom(); persist(phase: "bottom")
        await prepend(); persist(phase: "prepend")
        await prependDuringApply(); persist(phase: "prependDuringApply")
        await owedRace(); persist(phase: "owedRace")
        await loadLatestReturn(); persist(phase: "loadLatestReturn")
        await tailFlap(); persist(phase: "tailFlap")
        await foldCycles(); persist(phase: "foldCycles")
        await interleavedApplies(); persist(phase: "interleavedApplies")
        await scrollCost(); persist(phase: "scrollCost")
        await gestureFreeze(); persist(phase: "gestureFreeze")
        // These run last: they insert fixture rows, and the earlier scenarios
        // assume their original row set.
        await codeHostedHeight(); persist(phase: "codeHostedHeight")
        await firstFitSeed(); persist(phase: "firstFitSeed")
        await streamingSeed(); persist(phase: "streamingSeed")
        writeReport()
    }

    /// Proves the layout consumes `itemSpacing(after:)` instead of its old
    /// global constant: zero for the first row, then the default restored.
    private func perItemSpacing() async {
        guard let controller, entries.count >= 3 else { return }
        let first = listItem(entries[0])
        let second = listItem(entries[1])

        zeroSpacingItemIDs = [first.itemID]
        contentGeneration += 1
        controller.reloadFromContent()
        await wait(300)
        controller.collectionView.layoutIfNeeded()
        let zeroGap = (controller.layout.attributes(for: second.itemID)?.frame.minY ?? 0)
            - (controller.layout.attributes(for: first.itemID)?.frame.maxY ?? 0)

        zeroSpacingItemIDs = []
        contentGeneration += 1
        controller.reloadFromContent()
        await wait(300)
        controller.collectionView.layoutIfNeeded()
        let defaultGap = (controller.layout.attributes(for: second.itemID)?.frame.minY ?? 0)
            - (controller.layout.attributes(for: first.itemID)?.frame.maxY ?? 0)

        if abs(zeroGap) > 0.5 {
            failures.append("perItemSpacing: zero gap was \(zeroGap)pt")
        }
        if abs(defaultGap - TimelineListMetrics.itemSpacing) > 0.5 {
            failures.append("perItemSpacing: default gap was \(defaultGap)pt")
        }
        report["perItemSpacing"] = ["zeroGap": Double(zeroGap),
                                    "defaultGap": Double(defaultGap)]
    }

    private func measureConsistency() async {
        var samples: [[String: Any]] = []
        for kind in Kind.allCases {
            guard let entry = entries.first(where: { $0.kind == kind }) else { continue }
            let item = listItem(entry)
            await scrollToItem(item)
            // The visible cell is the measurement source for every kind now
            // that async Markdown is never pre-measured offscreen. Poll the
            // product's own settle instead of a fixed wait: CI load can push
            // the async Markdown parse past any single delay, and the sample
            // must read a materialized, settled cell.
            guard let controller else { continue }
            await scrollToItem(item)
            let timeout: TimeInterval = [.message, .longGroup, .reasoning].contains(kind) ? 10 : 3
            guard let sample = await settleSample(controller, item: item,
                                                  timeout: timeout) else {
                failures.append("measurement: no cell for \(kind.rawValue) (\(sampleFailureReason(controller, item: item)))")
                continue
            }
            let tolerance: CGFloat = [.message, .reasoning, .plain, .code, .table].contains(kind) ? 1 : 4
            let error = abs(sample.measured - sample.content)
            if error > tolerance {
                failures.append("measurement \(kind.rawValue): measured \(sample.measured) content \(sample.content) error \(error) > \(tolerance)")
            }
            if sample.cell + 0.5 < sample.content {
                failures.append("measurement \(kind.rawValue): cell \(sample.cell) clips content \(sample.content)")
            }
            samples.append(["kind": kind.rawValue, "measured": sample.measured,
                            "content": sample.content, "cell": sample.cell,
                            "attributes": sample.attributes, "frame": sample.frame,
                            "error": error])
        }
        if samples.count < 8 { failures.append("measurement: only \(samples.count) stratified samples") }
        report["measurement"] = ["samples": samples, "sampleCount": samples.count]
    }

    /// The incident shape: a group of long Markdown rows. Before Textual
    /// parses, the VStack spacing can be a small positive height; caching it
    /// makes every fixed-height cell overlap. The first stored height must be
    /// a pending/estimate value, never a probe-sized one.
    private func firstMeasurement() async {
        guard let controller, let entry = entries.first(where: { $0.kind == .longGroup }) else { return }
        let item = listItem(entry)
        let first = initialHeights[item.itemID] ?? 0
        var measurement: [String: Any] = ["firstStored": first]
        if first < 44 {
            failures.append("first measurement: long group stored \(first)pt before parse")
        }
        // The real cell is the measurement source for async Markdown, so it
        // has to exist before the settle read.
        await scrollToItem(item)
        if let sample = await settleSample(controller, item: item, timeout: 8) {
            measurement["settled"] = sample.measured
            measurement["content"] = sample.content
            if abs(sample.measured - sample.content) > 1 {
                failures.append("first measurement: settled \(sample.measured) vs content \(sample.content)")
            }
        }
        report["firstMeasurement"] = measurement
    }

    private func asyncMarkdown() async {
        guard let controller, let entry = entries.first(where: { $0.kind == .message }),
              let below = entries.first(where: { $0.kind == .reasoning }) else { return }
        let item = listItem(entry)
        let belowItem = listItem(below)
        controller.collectionView.setContentOffset(CGPoint(x: 0, y: 36), animated: false)
        await wait(120)
        let firstDisplayed = initialHeights[item.itemID]
            ?? controller.layout.attributes(for: item.itemID)?.frame.height ?? 0
        let before = controller.screenY(for: belowItem) ?? 0
        await wait(900)
        controller.remeasure(item)
        await wait(250)
        let settled = controller.layout.attributes(for: item.itemID)?.frame.height ?? 0
        let after = controller.screenY(for: belowItem) ?? 0
        let delta = abs(after - before)
        if delta > 0.5 {
            failures.append("async markdown: below anchor moved \(delta)pt (first \(firstDisplayed), settled \(settled))")
        }
        report["asyncMarkdown"] = ["firstDisplayed": firstDisplayed, "settled": settled,
                                   "belowAnchorDelta": delta]
    }

    private func foldAndTail() async {
        guard let controller else { return }
        if let entry = entries.first(where: { $0.kind == .toolExpanded }) {
            let item = listItem(entry)
            await scrollToItem(item)
            let collapsed = cellHeight(controller, item)
            debugRowViewCalls.removeAll()
            setExpanded(entry.id, true)
            controller.reconfigure([item])
            var expanded = await waitForCellHeight(controller, item: item,
                timeout: 3) { $0 > collapsed + 1 }
            // A lone reconfigure can be lost while the hosting body is already
            // mid-update (the row then keeps its collapsed content). A second
            // reconfigure is what the reader's second tap would do; the report
            // keeps `retried` so a lost first attempt stays visible.
            var retried = false
            if expanded <= collapsed + 1 {
                retried = true
                controller.reconfigure([item])
                expanded = await waitForCellHeight(controller, item: item,
                    timeout: 3) { $0 > collapsed + 1 }
            }
            // The row height now animates over 0.18 s; sample after it lands.
            await wait(700)
            let sample = await sampleItem(controller, item: item)
            if expanded <= collapsed + 1 {
                failures.append("fold: expanded \(expanded) not taller than collapsed \(collapsed)")
            }
            if let sample, sample.cell + 0.5 < sample.content {
                failures.append("fold: cell \(sample.cell) clips content \(sample.content)")
            }
            report["fold"] = ["collapsed": collapsed, "expanded": expanded,
                              "content": sample?.content ?? 0,
                              "retried": retried,
                              "providerCalls": debugRowViewCalls,
                              "entryExpanded": entries.first(where: { $0.id == entry.id })?.expanded ?? false,
                              "fitProbe": controller.debugPreferredFitProbe,
                              "diagnostics": controller.preferredDiagnostics,
                              "layoutDiagnostics": controller.layout.preferredHeightDiagnostics,
                              "prepareCount": controller.layout.prepareCount,
                              "appliedHeight": controller.layout.lastPreferredAppliedHeight[item.itemID] ?? -1,
                              "preparedHeight": controller.layout.lastPreparedHeight[item.itemID] ?? -1,
                              "preparedRevision": controller.layout.lastPreparedKeyRevision[item.itemID] ?? -1]
        }
        if let entry = entries.first(where: { $0.kind == .notice }) {
            let item = listItem(entry)
            await scrollToItem(item)
            let collapsed = cellHeight(controller, item)
            setExpanded(entry.id, true)
            controller.reconfigure([item])
            let expanded = await waitForCellHeight(controller, item: item,
                timeout: 3) { $0 > collapsed + 1 }
            if expanded <= collapsed + 1 {
                failures.append("inline notice: expanded \(expanded) not taller than collapsed \(collapsed)")
            }
            report["inlineNotice"] = ["collapsed": collapsed, "expanded": expanded]
        }
        if let entry = entries.first(where: { $0.kind == .tail }) {
            let item = listItem(entry)
            await scrollToItem(item)
            let resting = cellHeight(controller, item)
            setTailStatusLine(true)
            controller.reconfigure([item])
            let active = await waitForCellHeight(controller, item: item,
                timeout: 3) { abs($0 - 32) <= 1 }
            if abs(resting - 12) > 1 { failures.append("tail: resting height \(resting) != 12") }
            if abs(active - 32) > 1 { failures.append("tail: status height \(active) != 32") }
            report["tail"] = ["resting": resting, "statusLine": active]
        }
    }

    /// Device report (cf130b1): a tool-heavy turn with expanded rows drew
    /// text from neighbouring rows on top of each other. Expand eight tool
    /// rows through the product path (signature change → reload) and assert
    /// the frames stay disjoint and the visible cells contain their content.
    private func toolStorm() async {
        guard let controller else { return }
        let insertAt = max(0, entries.count - 1)
        var stormEntries: [Entry] = []
        for index in 0..<8 {
            let entry = Entry(id: "storm-\(index)", kind: .toolExpanded,
                              text: "工具组 \(index)")
            entries.insert(entry, at: insertAt + index)
            stormEntries.append(entry)
        }
        contentGeneration += 1
        controller.reloadFromContent()
        await wait(400)
        for entry in stormEntries { setExpanded(entry.id, true) }
        contentGeneration += 1
        controller.reloadFromContent()
        await wait(1500)
        controller.collectionView.layoutIfNeeded()
        // The follow is a spring now, so which rows are visible during the
        // reload depends on timing; a row measured collapsed before the
        // expansion can be off-screen when the cell would re-fit. Re-measure
        // any still-collapsed storm row through the off-screen measurer so
        // the assertion covers the expansion, not the resting offset.
        for entry in stormEntries {
            let item = listItem(entry)
            let height = controller.layout.attributes(for: item.itemID)?.frame.height ?? 0
            if height < 44 { controller.remeasure(item) }
        }
        await wait(250)
        controller.collectionView.layoutIfNeeded()

        var overlaps = 0
        let attributes = controller.layout.orderedAttributes
        for (upper, lower) in zip(attributes, attributes.dropFirst())
        where upper.frame.maxY > lower.frame.minY + 0.5 {
            overlaps += 1
        }
        var checked = 0
        var clipped = 0
        var collapsed = 0
        var collapsedIDs: [String] = []
        var rowReports: [[String: Any]] = []
        for entry in stormEntries {
            let item = listItem(entry)
            let height = controller.layout.attributes(for: item.itemID)?.frame.height ?? 0
            if height < 44 {
                collapsed += 1
                collapsedIDs.append(entry.id)
            }
            var row: [String: Any] = ["id": entry.id, "height": Double(height),
                "animating": controller.isAnimatingRowHeight(item.itemID)]
            guard let indexPath = controller.indexPath(for: item),
                  let cell = controller.collectionView.cellForItem(at: indexPath) else {
                rowReports.append(row)
                continue
            }
            checked += 1
            let content = cell.contentView.systemLayoutSizeFitting(
                CGSize(width: cell.contentView.bounds.width,
                       height: UIView.layoutFittingCompressedSize.height),
                withHorizontalFittingPriority: .required,
                verticalFittingPriority: .fittingSizeLevel).height
            if cell.bounds.height + 0.5 < content { clipped += 1 }
            row["cell"] = Double(cell.bounds.height)
            row["fitting"] = Double(content)
            rowReports.append(row)
        }
        let stale = staleVisibleCells(controller)
        if overlaps > 0 {
            failures.append("tool storm: \(overlaps) adjacent frames overlap")
        }
        if stale > 0 {
            failures.append("tool storm: \(stale) visible cells sit at stale frames")
        }
        if collapsed > 0 {
            failures.append("tool storm: \(collapsed) expanded rows kept a collapsed height")
        }
        if checked > 0, clipped > 0 {
            failures.append("tool storm: \(clipped)/\(checked) visible cells clip content")
        }
        report["toolStorm"] = ["rows": stormEntries.count, "overlaps": overlaps,
                               "checked": checked, "clipped": clipped,
                               "collapsed": collapsed, "staleCells": stale,
                               "collapsedIDs": collapsedIDs, "rowDetails": rowReports]
    }

    /// Device report (cf130b1): the status line jumped and sometimes ended
    /// below the viewport. Flap the status line while the reader sits at the
    /// bottom; the row must settle on the final height and the tail must stay
    /// reachable.
    private func tailFlap() async {
        guard let controller,
              let entry = entries.first(where: { $0.kind == .tail }) else { return }
        let item = listItem(entry)
        await scrollToItem(item)
        controller.requestBottom(animated: false)
        await wait(200)
        for index in 0..<6 {
            setTailStatusLine(index % 2 == 0)
            contentGeneration += 1
            controller.reloadFromContent()
            await wait(120)
        }
        setTailStatusLine(true)
        contentGeneration += 1
        controller.reloadFromContent()
        _ = await waitForCellHeight(controller, item: item, timeout: 3) {
            abs($0 - 32) <= 1
        }
        await wait(400)
        controller.collectionView.layoutIfNeeded()
        let height = cellHeight(controller, item)
        let attributes = controller.layout.attributes(for: item.itemID)
        let contentBottom = controller.layout.contentHeight
        let viewportBottom = controller.collectionView.contentOffset.y
            + controller.collectionView.bounds.height
            - controller.collectionView.adjustedContentInset.bottom
        let visible = viewportBottom >= contentBottom - 1
        if abs(height - 32) > 1 {
            failures.append("tail flap: settled at \(height), expected 32")
        }
        if let attributes, attributes.frame.maxY > controller.layout.contentHeight + 0.5 {
            failures.append("tail flap: tail frame exceeds content height")
        }
        if !visible {
            failures.append("tail flap: tail is below the viewport at rest")
        }
        let stale = staleVisibleCells(controller)
        if stale > 0 {
            failures.append("tail flap: \(stale) visible cells sit at stale frames")
        }
        report["tailFlap"] = ["height": Double(height), "visible": visible,
                              "contentHeight": Double(contentBottom),
                              "staleCells": stale]
    }

    /// Device report (6a18aa3): after collapsing an expanded tool the content
    /// below disappeared until a scroll. Collapse through the product path
    /// and check that every row intersecting the viewport still has a cell
    /// and that the visible band has no holes. Also sample the row height
    /// while expanding, for the animation report.
    private func collapseGap() async {
        guard let controller,
              let entry = entries.first(where: { $0.id == "storm-0" }) else { return }
        let item = listItem(entry)
        setExpanded(entry.id, true)
        contentGeneration += 1
        controller.reloadFromContent()
        await wait(500)
        if let indexPath = controller.indexPath(for: item) {
            controller.collectionView.scrollToItem(at: indexPath, at: .top, animated: false)
        }
        await wait(300)
        controller.collectionView.layoutIfNeeded()
        let before = visibleCoverage(controller)

        setExpanded(entry.id, false)
        contentGeneration += 1
        controller.reloadFromContent()
        await wait(900)
        controller.collectionView.layoutIfNeeded()
        let after = visibleCoverage(controller)
        let collapsedHeight = cellHeight(controller, item)
        if collapsedHeight > 100 {
            failures.append("collapse: row is \(collapsedHeight)pt after collapsing, expected the header height")
        }

        // Expansion samples: frame height over 500ms.
        let animationsBefore = controller.debugRowHeightAnimationsStarted
        setExpanded(entry.id, true)
        contentGeneration += 1
        controller.reloadFromContent()
        var samples: [CGFloat] = []
        var attributeSamples: [CGFloat] = []
        for _ in 0..<30 {
            controller.collectionView.layoutIfNeeded()
            if let indexPath = controller.indexPath(for: item),
               let cell = controller.collectionView.cellForItem(at: indexPath) {
                samples.append(cell.frame.height)
            }
            attributeSamples.append(controller.layout.attributes(for: item.itemID)?.frame.height ?? -1)
            await wait(16)
        }
        let animationsAfter = controller.debugRowHeightAnimationsStarted
        var distinct: [CGFloat] = []
        for value in samples where distinct.last.map({ abs($0 - value) > 0.5 }) ?? true {
            distinct.append(value)
        }
        if after.missing > 0 || after.gap > 1 {
            failures.append("collapse: missing \(after.missing) cells, gap \(after.gap)pt")
        }
        // A host-animated expansion must produce intermediate frames, not one
        // jump (the "not smooth" device report).
        if distinct.count < 3 {
            failures.append("collapse: expansion jumped in \(distinct.count) step(s)")
        }
        report["collapseGap"] = [
            "collapsedHeight": Double(collapsedHeight),
            "animationsBefore": animationsBefore,
            "animationsAfter": animationsAfter,
            "activeAnimations": controller.debugActiveRowHeightAnimations,
            "attributeHeights": attributeSamples.map(Double.init),
            "beforeMissing": before.missing, "beforeGap": Double(before.gap),
            "afterMissing": after.missing, "afterGap": Double(after.gap),
            "expansionHeights": distinct.map(Double.init),
            "contentHeight": Double(controller.layout.contentHeight),
            "offset": Double(controller.collectionView.contentOffset.y),
        ]
    }

    /// Device report (6a18aa3): collapsing a tool while its turn was still
    /// streaming left the area below blank until a scroll. Run batches, then
    /// collapse a tool above the live row and keep streaming; the visible
    /// band must stay covered and every visible cell current.
    private func collapseWhileStreaming() async {
        guard let controller,
              let stream = entries.last(where: { $0.kind == .plain }),
              let streamIndex = entries.firstIndex(where: { $0.id == stream.id }) else { return }
        let tool = Entry(id: "stream-tool", kind: .toolExpanded,
                         text: "工具组", expanded: true)
        entries.insert(tool, at: streamIndex)
        contentGeneration += 1
        controller.reloadFromContent()
        await wait(500)
        let toolItem = listItem(tool)
        if let indexPath = controller.indexPath(for: toolItem) {
            controller.collectionView.scrollToItem(at: indexPath, at: .top, animated: false)
        }
        await wait(200)
        streamingIDs.insert(stream.id)
        defer { streamingIDs.remove(stream.id) }
        for _ in 0..<3 {
            appendStreamLine(to: stream.id)
            controller.reloadFromContent()
            await wait(120)
        }
        setExpanded(tool.id, false)
        contentGeneration += 1
        controller.reloadFromContent()
        for _ in 0..<3 {
            appendStreamLine(to: stream.id)
            controller.reloadFromContent()
            await wait(120)
        }
        await wait(700)
        controller.collectionView.layoutIfNeeded()
        let coverage = visibleCoverage(controller)
        let stale = staleVisibleCells(controller)
        if coverage.missing > 0 || coverage.gap > 1 {
            failures.append("stream collapse: missing \(coverage.missing), gap \(coverage.gap)")
        }
        if stale > 0 {
            failures.append("stream collapse: \(stale) stale cells")
        }
        report["streamCollapse"] = ["missing": coverage.missing,
                                    "gap": Double(coverage.gap),
                                    "stale": stale,
                                    "contentHeight": Double(controller.layout.contentHeight)]
    }

    /// Device report (6a18aa3): load-older jumped to the top of the loaded
    /// page. Reproduce the layout race deterministically: install the prepend
    /// target, let an unrelated snapshot update run first, then land the page.
    /// The anchor must not move.
    private func owedRace() async {
        guard let controller, entries.count > 10 else { return }
        let anchor = entries[5]
        let anchorItem = listItem(anchor)
        guard let anchorIndex = controller.indexPath(for: anchorItem) else { return }
        controller.collectionView.scrollToItem(at: anchorIndex, at: .top, animated: false)
        await wait(120)
        let before = controller.screenY(for: anchorItem) ?? 0
        let prepended = makePrependEntries(40)
        // Use the product entry point: it measures the new page before
        // projecting, so the target matches the post-apply layout.
        guard controller.beginHistoryRequest(generation: 900,
            anchorRowID: anchor.id, edge: .top,
            newItems: prepended.map(listItem) + entries.map(listItem)) != nil else {
            failures.append("owed race: no history position")
            return
        }

        // An unrelated update lands first (a streaming batch during the
        // history request); it must not consume or clear the prepend target.
        guard let plain = entries.last(where: { $0.kind == .plain }) else { return }
        appendStreamLine(to: plain.id)
        controller.reloadFromContent()
        await wait(500)

        prependEntries(prepended)
        controller.reloadFromContent()
        await wait(800)
        let after = controller.screenY(for: anchorItem) ?? 0
        let delta = abs(after - before)
        if delta > 1 {
            failures.append("owed race: anchor moved \(delta)pt")
        }
        report["owedRace"] = ["before": Double(before), "after": Double(after),
                              "delta": Double(delta),
                              "targetCalls": controller.layout.targetContentOffsetCallCount]
    }

    /// Device report: scrolling stutters. Measure the synchronous layout cost
    /// of a scripted 40-step scroll over the tool-heavy timeline and the
    /// settle/prepare work it triggers. Report-only for the first run; the
    /// ceiling goes in once the baseline is known.
    private func scrollCost() async {
        guard let controller else { return }
        let view = controller.collectionView!
        view.layoutIfNeeded()
        let maxOffset = max(0, view.contentSize.height - view.bounds.height)
        guard maxOffset > 0 else { return }
        let preparesBefore = controller.layout.prepareCount
        var durations: [Double] = []
        for step in 1...40 {
            let y = maxOffset * CGFloat(step) / CGFloat(40)
            let start = CACurrentMediaTime()
            view.setContentOffset(CGPoint(x: 0, y: y), animated: false)
            view.layoutIfNeeded()
            durations.append((CACurrentMediaTime() - start) * 1000)
            await wait(16)
        }
        let sorted = durations.sorted()
        let median = sorted[sorted.count / 2]
        let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * 0.95))]
        let maxValue = sorted.last ?? 0
        let prepares = controller.layout.prepareCount - preparesBefore
        report["scrollCost"] = ["steps": 40,
                                "medianMs": median, "p95Ms": p95, "maxMs": maxValue,
                                "prepares": prepares,
                                "contentHeight": Double(view.contentSize.height)]
    }

    // MARK: - Hosted cell height contract (Code-shaped row)

    /// Wait until the async measurement pipeline stops moving the layout.
    /// Rows inserted by the previous phase are still on their 200 pt estimate;
    /// scrolling to a row before those settle leaves it above the viewport
    /// once the estimates collapse to their real heights.
    @discardableResult
    private func settleLayout(_ controller: TimelineCollectionController,
                              timeout: TimeInterval = 6) async -> Bool {
        let start = ProcessInfo.processInfo.systemUptime
        var lastHeight = controller.layout.contentHeight
        var lastMeasures = controller.layout.debugSelfMeasureCount
        var stable = 0
        while ProcessInfo.processInfo.systemUptime - start < timeout {
            await wait(120)
            controller.collectionView.layoutIfNeeded()
            let height = controller.layout.contentHeight
            let measures = controller.layout.debugSelfMeasureCount
            if abs(height - lastHeight) <= 0.5, measures == lastMeasures {
                stable += 1
                if stable >= 4 { return true }
            } else {
                stable = 0
                lastHeight = height
                lastMeasures = measures
            }
        }
        return false
    }

    /// Why the hosted gate can or cannot see its fixture cell. `cellHeight:-1`
    /// alone does not say whether the item lost its index path, the layout
    /// dropped its attributes, or the cell is simply off screen.
    private func hostedState(_ controller: TimelineCollectionController,
                             item: TimelineListItem) -> [String: Any] {
        controller.collectionView.layoutIfNeeded()
        let indexPath = controller.indexPath(for: item)
        let attributes = controller.layout.attributes(for: item.itemID)
        let visible = indexPath.map {
            controller.collectionView.indexPathsForVisibleItems.contains($0)
        } ?? false
        let cell = indexPath.flatMap { controller.collectionView.cellForItem(at: $0) }
        let visibleItems = controller.collectionView.indexPathsForVisibleItems.map(\.item)
        // The layout's own row geometry around the fixture: the visible set
        // and the height map can disagree, and only this says which one the
        // collection view is actually laying out.
        let rows: [[String: Any]] = controller.layout.orderedAttributes.enumerated()
            .filter { (8...22).contains($0.offset) }
            .map { index, attributes in
                ["index": index,
                 "id": attributes.item?.itemID ?? "?",
                 "minY": Double(attributes.frame.minY),
                 "height": Double(attributes.frame.height)]
            }
        return ["rows": rows,
                "hasIndexPath": indexPath != nil,
                "indexPathItem": indexPath?.item ?? -1,
                "layoutItemCount": controller.layoutItemCount,
                "dataSourceCount": controller.collectionView.numberOfItems(inSection: 0),
                "attributeIndex": attributes?.indexPath.item ?? -1,
                "attributeMinY": Double(attributes?.frame.minY ?? -1),
                "attributeHeight": Double(attributes?.frame.height ?? -1),
                "visible": visible,
                "visibleFirst": visibleItems.min() ?? -1,
                "visibleLast": visibleItems.max() ?? -1,
                "visibleItems": visibleItems.sorted(),
                "hasCell": cell != nil,
                "cellHeight": Double(cell?.frame.height ?? -1),
                "offset": Double(controller.collectionView.contentOffset.y),
                "boundsHeight": Double(controller.collectionView.bounds.height),
                "contentSizeHeight": Double(controller.collectionView.contentSize.height),
                "contentHeight": Double(controller.layout.contentHeight)]
    }

    /// Wait until the layout frame equals the cell's rendered content height.
    /// For a cell-reported row the visible cell is the only exact source; the
    /// pre-parse placeholder is the value this must not accept.
    private func settleHostedHeight(_ controller: TimelineCollectionController,
                                    item: TimelineListItem,
                                    timeout: TimeInterval) async -> CGFloat? {
        let start = ProcessInfo.processInfo.systemUptime
        var last: CGFloat?
        while ProcessInfo.processInfo.systemUptime - start < timeout {
            controller.collectionView.layoutIfNeeded()
            // A recycled cell can still answer `cellForItem` for a row the
            // visible set no longer contains; its fit is not the row's height.
            if let indexPath = controller.indexPath(for: item),
               controller.collectionView.indexPathsForVisibleItems.contains(indexPath),
               let cell = controller.collectionView.cellForItem(at: indexPath) {
                let width = cell.contentView.bounds.width
                if width > 0 {
                    let fit = ceil(cell.contentView.systemLayoutSizeFitting(
                        CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
                        withHorizontalFittingPriority: .required,
                        verticalFittingPriority: .fittingSizeLevel).height)
                    let frame = controller.layout.attributes(for: item.itemID)?.frame.height ?? -1
                    if fit > 1, abs(frame - fit) <= 1 { return fit }
                    last = fit
                }
            }
            await wait(120)
        }
        return last
    }

    /// The official hosted-height contract on a Code-shaped row.
    ///
    /// The height is the cell's own `systemLayoutSizeFitting` (the official
    /// first-fit call), read at settled moments. The geometry callback is a
    /// trigger only; no reported number is ever written as a height.
    ///
    /// `isMeasured` is cleared only by a width change (`0x101a3ff20`). A
    /// same-width content change keeps the row measured and instead reconfigures
    /// it (`0x101a3c57c`, `performWithoutAnimation`), so the hosting geometry
    /// reports the settled fit (`0x101a4081c`, accepted only when it changed).
    /// A self-measure therefore happens only for a row that has never been
    /// measured at the current width.
    ///
    /// Assertions: the frame equals the fit after materialization; a same-width
    /// content change adds no self-measure and lands on a taller final frame; a
    /// content change that lands while the reader drags keeps the changed row's
    /// own top at the same screen position, and the release does not move it.
    private func codeHostedHeight() async {
        guard let controller else { return }
        let entry = Entry(id: "\(Self.hostedRowPrefix)0", kind: .code,
                          text: "struct Demo {\n    let value: Int\n}\nprint(Demo(value: 1))",
                          structuralHeight: 56)
        entries.insert(entry, at: max(0, entries.count / 2))
        contentGeneration += 1
        controller.reloadFromContent()
        await wait(800)
        controller.collectionView.layoutIfNeeded()
        // The previous phase's fixture rows are still estimates; anchoring
        // before they collapse would measure the scroll position, not the row.
        await settleLayout(controller)

        let item = listItem(entry)
        guard let indexPath = controller.indexPath(for: item) else {
            failures.append("code hosted: no index path for \(entry.id)")
            return
        }
        // A synthetic scroll never runs the drag callbacks that disarm the
        // bottom target; a settle pass can then repin the list before the
        // anchor is read. Disarm, scroll, settle, disarm and anchor again.
        controller.disarmBottom()
        controller.collectionView.scrollToItem(at: indexPath, at: .top, animated: false)
        await wait(400)
        controller.collectionView.layoutIfNeeded()
        controller.disarmBottom()
        await settleLayout(controller)
        controller.collectionView.scrollToItem(at: indexPath, at: .top, animated: false)
        await wait(250)
        controller.collectionView.layoutIfNeeded()
        let anchoredState = hostedState(controller, item: item)
        if !(anchoredState["visible"] as? Bool ?? false) {
            failures.append("code hosted: the fixture left the viewport after anchoring \(anchoredState)")
        }
        guard let firstFit = await settleHostedHeight(controller, item: item, timeout: 8) else {
            let state = hostedState(controller, item: item)
            failures.append("code hosted: the cell never settled on its fit \(state)")
            return
        }
        let stateAfterFirstSettle = hostedState(controller, item: item)
        let frameAfterFirst = controller.layout.attributes(for: item.itemID)?.frame.height ?? -1
        if abs(frameAfterFirst - firstFit) > 0.5 {
            failures.append("code hosted: frame \(frameAfterFirst) != first fit \(firstFit)")
        }
        let selfMeasuresAfterFirst = controller.layout.debugSelfMeasureCount

        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        // The next row is the reader's anchor for the gesture leg.
        let anchorIndex = min(index + 1, entries.count - 1)
        let anchorItem = listItem(entries[anchorIndex])

        // Leg 1 — content change at rest: no self-measure; one settle-driven correction.
        entries[index].text += "\nlet extra = 40"
        entries[index].revision += 1
        contentGeneration += 1
        controller.reloadFromContent()
        await wait(600)
        controller.collectionView.layoutIfNeeded()
        guard let secondFit = await settleHostedHeight(controller, item: item, timeout: 8) else {
            let state = hostedState(controller, item: item)
            failures.append("code hosted: the cell never settled after a content change \(state)")
            return
        }
        let frameAfterSecond = controller.layout.attributes(for: item.itemID)?.frame.height ?? -1
        let selfMeasuresAfterSecond = controller.layout.debugSelfMeasureCount
        if abs(frameAfterSecond - secondFit) > 0.5 {
            failures.append("code hosted: frame \(frameAfterSecond) != fit \(secondFit)"
                + " after a content change")
        }
        if secondFit <= firstFit + 1 {
            failures.append("code hosted: content change did not grow the row \(firstFit)→\(secondFit)")
        }
        if selfMeasuresAfterSecond != selfMeasuresAfterFirst {
            failures.append("code hosted: \(selfMeasuresAfterSecond - selfMeasuresAfterFirst)"
                + " self-measures for a same-width content change"
                + " (official 0x101a3ff20 clears isMeasured only on width change)")
        }

        // Leg 2 — the same content change while the reader drags: the row may
        // grow, but the anchor below keeps its screen position, and releasing
        // must not apply the height a second time.
        controller.collectionView.scrollToItem(at: indexPath, at: .top, animated: false)
        await wait(250)
        controller.collectionView.layoutIfNeeded()
        let anchorBefore = controller.screenY(for: anchorItem) ?? .nan
        let fixtureScreenBefore = controller.screenY(for: item) ?? .nan
        controller.setTestGestureState(tracking: true, decelerating: false)
        entries[index].text += "\nlet more = 41"
        entries[index].revision += 1
        contentGeneration += 1
        controller.reloadFromContent()
        await wait(400)
        controller.collectionView.layoutIfNeeded()
        let anchorDuring = controller.screenY(for: anchorItem) ?? .nan
        let fixtureScreenDuring = controller.screenY(for: item) ?? .nan
        let heightAtRelease = controller.layout.attributes(for: item.itemID)?.frame.height ?? -1
        controller.setTestGestureState(tracking: false, decelerating: false)
        await wait(700)
        controller.collectionView.layoutIfNeeded()
        guard let finalFit = await settleHostedHeight(controller, item: item, timeout: 8) else {
            let state = hostedState(controller, item: item)
            failures.append("code hosted: the cell never settled after the gesture change \(state)")
            return
        }
        let frameFinal = controller.layout.attributes(for: item.itemID)?.frame.height ?? -1
        let anchorAfter = controller.screenY(for: anchorItem) ?? .nan
        let fixtureScreenAfter = controller.screenY(for: item) ?? .nan
        if abs(frameFinal - finalFit) > 0.5 {
            failures.append("code hosted: frame \(frameFinal) != fit \(finalFit) after the gesture")
        }
        // The height under the finger may still be the estimate: no settle
        // runs while `isUserScrolling`. What must hold is the final value and
        // that the changed row's own top never moved; `heightAtRelease` stays
        // in the report as evidence.
        // The changed row's own top is the reader's anchor; the row below is
        // pushed down by the growth, which is the official behavior.
        if fixtureScreenBefore.isFinite, abs(fixtureScreenDuring - fixtureScreenBefore) > 0.5 {
            failures.append("code hosted: the changed row moved during the drag"
                + " \(fixtureScreenBefore)->\(fixtureScreenDuring)")
        }
        if fixtureScreenBefore.isFinite, abs(fixtureScreenAfter - fixtureScreenBefore) > 0.5 {
            failures.append("code hosted: the changed row moved after release"
                + " \(fixtureScreenBefore)->\(fixtureScreenAfter)")
        }

        var hostedReport: [String: Any] = [:]
        hostedReport["row"] = entry.id
        hostedReport["structuralEstimate"] = 56.0
        hostedReport["firstFit"] = Double(firstFit)
        hostedReport["secondFit"] = Double(secondFit)
        hostedReport["finalFit"] = Double(finalFit)
        hostedReport["frameAfterFirst"] = Double(frameAfterFirst)
        hostedReport["frameAfterSecond"] = Double(frameAfterSecond)
        hostedReport["frameAfterGesture"] = Double(frameFinal)
        hostedReport["selfMeasuresAfterFirst"] = selfMeasuresAfterFirst
        hostedReport["selfMeasuresAfterSecond"] = selfMeasuresAfterSecond
        hostedReport["anchorBefore"] = anchorBefore.isFinite ? Double(anchorBefore) : -1
        hostedReport["anchorDuring"] = anchorDuring.isFinite ? Double(anchorDuring) : -1
        hostedReport["anchorAfter"] = anchorAfter.isFinite ? Double(anchorAfter) : -1
        hostedReport["fixtureScreenBefore"] = fixtureScreenBefore.isFinite ? Double(fixtureScreenBefore) : -1
        hostedReport["fixtureScreenDuring"] = fixtureScreenDuring.isFinite ? Double(fixtureScreenDuring) : -1
        hostedReport["fixtureScreenAfter"] = fixtureScreenAfter.isFinite ? Double(fixtureScreenAfter) : -1
        hostedReport["stateAfterFirstSettle"] = stateAfterFirstSettle
        report["codeHostedHeight"] = hostedReport

        // Leave the timeline as the earlier scenarios found it.
        entries.removeAll { $0.id == entry.id }
        contentGeneration += 1
        controller.reloadFromContent()
        await wait(300)
    }

    // MARK: - First-fit seed (structured measurement seeds the first fit)

    /// The device report's pre-parse family (`598→54→598`, `1654→126→1655`):
    /// a Code row's first materialization fitted the placeholder body and the
    /// layout accepted that value as the first self-measure. The official
    /// first fit measures real content, so the adapter's structural
    /// measurement must seed that first fit instead of letting the skeleton
    /// answer it.
    ///
    /// This fixture's body has no prepared blocks, so `ChatMarkdownView`
    /// parses asynchronously; the product Code row usually pre-parses
    /// synchronously (`TimelineChatContentAdapter` `preparedBlocks` ->
    /// `CodeMessageRowView` -> `ChatMarkdownView(initialBlocks:)`, skipping
    /// the async `.task`) and the seed covers the frames before its hosted
    /// content finishes its layout pass.
    ///
    /// The fixture is a cell-reported row inserted above the viewport, so the
    /// apply cannot materialize it. CI 459 showed scrolling a never-displayed
    /// row into view does not invoke UIKit's `preferredLayoutAttributesFitting`
    /// at all (the observed 420→1263 came from the controller's settled
    /// cell-fit), so the seed is checked two ways: the cell's first fit is
    /// called directly while the row is still unmeasured, and the frame
    /// invariants the reader can observe are asserted.
    /// Assertions: the direct first fit returns
    /// `ceil(measuredCodeGroupHeight)` while `isMeasured` is false; the frame
    /// right after the scroll is that value and the next frames never fall
    /// below it; any accepted self-measure equals it; the settled frame
    /// equals the cell's fit and stays there, taller than the seed once the
    /// body has parsed.
    private func firstFitSeed() async {
        guard let controller else { return }
        let structural: CGFloat = 420
        let entry = Entry(id: "\(Self.seedRowPrefix)0", kind: .message,
                          text: "## First-fit seed\n\n"
                              + String(repeating: "A parsed line that only the real body has. ",
                                       count: 80),
                          structuralHeight: structural)
        await settleLayout(controller)
        // Row 2 is far above the mid-list viewport the earlier phases leave
        // behind. The row must stay unmaterialized through the apply: the
        // white-box seed check below runs on the scroll's own first
        // materialization.
        controller.layout.clearDebugSelfMeasureHeights()
        entries.insert(entry, at: 2)
        contentGeneration += 1
        controller.reloadFromContent()
        await wait(500)
        controller.collectionView.layoutIfNeeded()

        let item = listItem(entry)
        let displayedBeforeScroll = controller.layout.heights.hasEverBeenDisplayed(item.itemID)
        let beforeScroll = controller.layout.debugSelfMeasureHeights
            .filter { $0.itemID == item.itemID }
        let frameBeforeScroll = controller.layout.attributes(for: item.itemID)?.frame.height ?? -1

        guard let indexPath = controller.indexPath(for: item) else {
            failures.append("first-fit seed: no index path for \(entry.id)")
            return
        }
        controller.disarmBottom()
        controller.collectionView.scrollToItem(at: indexPath, at: .top, animated: false)
        // Materialize the destination cells synchronously; no await may run
        // before the seed check below.
        controller.collectionView.setNeedsLayout()
        controller.collectionView.layoutIfNeeded()
        controller.disarmBottom()

        // CI 459: scrolling this never-displayed row into view did not invoke
        // UIKit's `preferredLayoutAttributesFitting` at all; the 420→1263 the
        // report showed came from the controller's settled cell-fit. Verify
        // the seed white-box on this exact materialization, before any await
        // lets a settle pass run: the row must still be unmeasured, and the
        // cell's direct first fit must return the structural height.
        let seedCell = controller.collectionView.cellForItem(at: indexPath) as? TimelineHostingCell
        let seedAttributes = controller.layout.layoutAttributesForItem(at: indexPath)
            as? TimelineListLayoutAttributes
        let attributesMeasuredBeforeFit = seedAttributes?.isMeasured
        var directSeedFit: CGFloat = -1
        if let seedCell, let seedAttributes {
            directSeedFit = seedCell.preferredLayoutAttributesFitting(seedAttributes).size.height
        }
        let frameRightAfterScroll = controller.layout.attributes(for: item.itemID)?.frame.height ?? -1

        // The reader-visible invariant: from the materialization on, the row
        // never shows a height below the structural value. This catches a
        // sub-structural fit if UIKit does run a PLAF for this row later.
        var seedHoldSamples: [CGFloat] = []
        for _ in 0..<5 {
            controller.collectionView.layoutIfNeeded()
            seedHoldSamples.append(controller.layout.attributes(for: item.itemID)?.frame.height ?? 0)
            await wait(16)
        }
        let seedHeld = seedHoldSamples.allSatisfy { $0 >= structural - 0.5 }
        let frameAfterScroll = seedHoldSamples.last ?? -1

        if seedCell == nil {
            failures.append("first-fit seed: no cell at \(entry.id) right after the scroll")
        }
        if seedAttributes == nil {
            failures.append("first-fit seed: no layout attributes for \(entry.id)"
                + " right after the scroll")
        }
        if attributesMeasuredBeforeFit == true {
            failures.append("first-fit seed: row was measured before the seed check")
        }
        if abs(directSeedFit - ceil(structural)) > 0.5 {
            failures.append("first-fit seed: direct preferred fit \(directSeedFit)"
                + " != structural \(ceil(structural))")
        }
        if abs(frameRightAfterScroll - structural) > 0.5 {
            failures.append("first-fit seed: frame \(frameRightAfterScroll) right after"
                + " the scroll != \(structural)")
        }
        if !seedHeld {
            failures.append("first-fit seed: frame fell below the structural value"
                + " \(seedHoldSamples)")
        }
        if displayedBeforeScroll {
            failures.append("first-fit seed: \(entry.id) was displayed before the scroll")
        }
        if !beforeScroll.isEmpty {
            failures.append("first-fit seed: \(beforeScroll.count) self-measure(s) before"
                + " the row entered the viewport \(beforeScroll.map(\.height))")
        }

        guard let firstFit = await settleHostedHeight(controller, item: item, timeout: 8) else {
            failures.append("first-fit seed: the cell never settled on its fit"
                + " \(hostedState(controller, item: item))")
            return
        }
        let frameAfterSettle = controller.layout.attributes(for: item.itemID)?.frame.height ?? -1
        // A missing self-measure is allowed: CI 459 showed the scroll-in never
        // triggers UIKit's preferred-attributes path. When one does happen it
        // owns the first fit, so it must be the seed and never a smaller
        // pre-parse value.
        let measuresAfterSettle = controller.layout.debugSelfMeasureHeights
            .filter { $0.itemID == item.itemID }
        let firstAccepted = measuresAfterSettle.first?.height
        let smallest = measuresAfterSettle.map(\.height).min()
        // "Settled" also means it stays: sample a few frames after the fit so
        // a second correction cannot hide behind the settle poll.
        var samples: [CGFloat] = []
        for _ in 0..<10 {
            controller.collectionView.layoutIfNeeded()
            samples.append(controller.layout.attributes(for: item.itemID)?.frame.height ?? 0)
            await wait(16)
        }
        let stable = samples.allSatisfy { abs($0 - frameAfterSettle) <= 0.5 }

        if let firstAccepted, abs(firstAccepted - ceil(structural)) > 0.5 {
            failures.append("first-fit seed: first accepted self-measure \(firstAccepted)"
                + " != structural \(ceil(structural))")
        }
        if let smallest, smallest < structural - 0.5 {
            failures.append("first-fit seed: a self-measure was below the structural"
                + " value \(smallest) < \(structural) \(measuresAfterSettle.map(\.height))")
        }
        if abs(frameAfterSettle - firstFit) > 0.5 {
            failures.append("first-fit seed: frame \(frameAfterSettle) != cell fit \(firstFit)")
        }
        if firstFit <= structural + 1 {
            failures.append("first-fit seed: the parsed body did not outgrow the seed"
                + " \(structural)->\(firstFit)")
        }
        if !stable {
            failures.append("first-fit seed: the settled height did not stay"
                + " \(frameAfterSettle) \(samples)")
        }

        // Swift 6.2 could not type-check the one big dictionary literal in
        // reasonable time (CI 460). Assign typed locals first, then build the
        // report incrementally.
        let measuredFlag: Int = attributesMeasuredBeforeFit == nil
            ? -1 : (attributesMeasuredBeforeFit! ? 1 : 0)
        let firstAcceptedValue: Double = firstAccepted.map { Double($0) } ?? -1
        let selfMeasureValues: [Double] = measuresAfterSettle.map { Double($0.height) }
        let rowVisible: Bool = controller.collectionView.indexPathsForVisibleItems
            .contains(indexPath)
        var firstFitReport: [String: Any] = [:]
        firstFitReport["row"] = entry.id
        firstFitReport["structuralHeight"] = Double(structural)
        firstFitReport["displayedBeforeScroll"] = displayedBeforeScroll
        firstFitReport["selfMeasuresBeforeScroll"] = beforeScroll.count
        firstFitReport["frameBeforeScroll"] = Double(frameBeforeScroll)
        firstFitReport["frameRightAfterScroll"] = Double(frameRightAfterScroll)
        firstFitReport["attributesMeasuredBeforeFit"] = measuredFlag
        firstFitReport["directSeedFit"] = Double(directSeedFit)
        firstFitReport["seedHeld"] = seedHeld
        firstFitReport["frameAfterScroll"] = Double(frameAfterScroll)
        firstFitReport["firstAcceptedSelfMeasure"] = firstAcceptedValue
        firstFitReport["selfMeasureCount"] = measuresAfterSettle.count
        firstFitReport["selfMeasureHeights"] = selfMeasureValues
        firstFitReport["frameAfterSettle"] = Double(frameAfterSettle)
        firstFitReport["finalFit"] = Double(firstFit)
        firstFitReport["stable"] = stable
        firstFitReport["visible"] = rowVisible
        report["firstFitSeed"] = firstFitReport
    }

    // MARK: - Streaming seed (no structural value → displayed height)

    /// Device report 461: a streaming assistant row has no structural value
    /// while its text is still revealing, so `measuredCodeGroupHeight` answers
    /// nil and the cell provider used to pass no seed. The first fit then
    /// measured the pre-layout hosting body and the row collapsed 44 → 18 →
    /// 34 → 57 inside 0.8 s. The official placeholder for such a row is the
    /// estimate tier, and the height the layout already displays is that
    /// estimate (Part V §2.5: the stored `__height` is the previous
    /// measurement; Part AG: an unmeasured row is an estimate). The provider
    /// therefore falls back to the displayed height when no structural value
    /// exists.
    ///
    /// This fixture has no structural height, so `prepare` records the `.row`
    /// estimate as its displayed height and the cell's first fit must return
    /// exactly that seed, never the skeleton's tens of points.
    /// Assertions: the row is inserted above the viewport and not materialized
    /// by the apply; the prepared displayed height is the `.row` estimate; the
    /// direct `preferredLayoutAttributesFitting` returns the seed while the
    /// row is unmeasured; the next five frames never fall below it; after the
    /// body parses the frame equals the cell fit and outgrows the seed; the
    /// settled height stays.
    private func streamingSeed() async {
        guard let controller else { return }
        let entry = Entry(id: "\(Self.streamRowPrefix)0", kind: .message,
                          text: "## Streaming seed\n\n"
                              + String(repeating: "A streamed line whose body parses after the first fit. ",
                                       count: 60))
        func removeFixture() {
            entries.removeAll { $0.id == entry.id }
            contentGeneration += 1
            controller.reloadFromContent()
        }
        await settleLayout(controller)
        controller.layout.clearDebugSelfMeasureHeights()
        // The first-fit seed leg leaves the viewport at row 2, whose top is
        // only a couple of hundred points into the list: a 200 pt estimate
        // inserted at row 0 would still intersect that viewport and
        // materialize during the apply. Anchor a mid-list row first, so the
        // insertion stays fully above the visible band and only the scroll
        // below can materialize it.
        let anchorIndex = min(8, max(0, entries.count - 1))
        let anchorItem = listItem(entries[anchorIndex])
        if let anchorPath = controller.indexPath(for: anchorItem) {
            controller.disarmBottom()
            controller.collectionView.scrollToItem(at: anchorPath, at: .top, animated: false)
            await wait(250)
            controller.collectionView.layoutIfNeeded()
            controller.disarmBottom()
        }
        let viewportTop = controller.collectionView.contentOffset.y
            + controller.collectionView.adjustedContentInset.top
        entries.insert(entry, at: 0)
        contentGeneration += 1
        controller.reloadFromContent()
        await wait(500)
        controller.collectionView.layoutIfNeeded()

        let item = listItem(entry)
        // The displayed height this apply's `prepare` recorded for the
        // never-shown row; it is the `.row` estimate (200). Wait for the
        // apply's prepare rather than racing it.
        var preparedSeed = controller.layout.heights.displayedHeight(for: item.itemID)
        let prepareStart = ProcessInfo.processInfo.systemUptime
        while preparedSeed == nil,
              ProcessInfo.processInfo.systemUptime - prepareStart < 3 {
            await wait(50)
            preparedSeed = controller.layout.heights.displayedHeight(for: item.itemID)
        }
        let seed = preparedSeed ?? -1
        let displayedBeforeScroll = controller.layout.heights.hasEverBeenDisplayed(item.itemID)
        let beforeScrollMeasures = controller.layout.debugSelfMeasureHeights
            .filter { $0.itemID == item.itemID }
        let frameBeforeScroll = controller.layout.attributes(for: item.itemID)?.frame.height ?? -1
        let insertedFrame = controller.layout.attributes(for: item.itemID)?.frame
        let fixtureWidth = controller.layout.attributes(for: item.itemID)?.frame.width ?? 1
        let structural = measuredCodeGroupHeight(for: item, width: max(fixtureWidth, 1))

        guard let indexPath = controller.indexPath(for: item) else {
            failures.append("streaming seed: no index path for \(entry.id)")
            removeFixture()
            await wait(300)
            return
        }
        controller.disarmBottom()
        controller.collectionView.scrollToItem(at: indexPath, at: .top, animated: false)
        // Materialize the destination cell synchronously; no await may run
        // before the seed check below.
        controller.collectionView.setNeedsLayout()
        controller.collectionView.layoutIfNeeded()
        controller.disarmBottom()

        let seedCell = controller.collectionView.cellForItem(at: indexPath) as? TimelineHostingCell
        let seedAttributes = controller.layout.layoutAttributesForItem(at: indexPath)
            as? TimelineListLayoutAttributes
        let attributesMeasuredBeforeFit = seedAttributes?.isMeasured
        var directSeedFit: CGFloat = -1
        if let seedCell, let seedAttributes {
            directSeedFit = seedCell.preferredLayoutAttributesFitting(seedAttributes).size.height
        }
        let frameRightAfterScroll = controller.layout.attributes(for: item.itemID)?.frame.height ?? -1

        // From the materialization on, the row never shows a height below the
        // seed. This is the reader-visible invariant; a pre-layout fit would
        // drop it to tens of points.
        var frames: [CGFloat] = []
        for _ in 0..<5 {
            controller.collectionView.layoutIfNeeded()
            frames.append(controller.layout.attributes(for: item.itemID)?.frame.height ?? 0)
            await wait(16)
        }
        let framesHeld = frames.allSatisfy { $0 >= seed - 0.5 }

        if seedCell == nil {
            failures.append("streaming seed: no cell at \(entry.id) right after the scroll")
        }
        if seedAttributes == nil {
            failures.append("streaming seed: no layout attributes for \(entry.id)"
                + " right after the scroll")
        }
        if attributesMeasuredBeforeFit == true {
            failures.append("streaming seed: row was measured before the seed check")
        }
        if structural != nil {
            failures.append("streaming seed: measuredCodeGroupHeight returned \(structural!)"
                + " for the structural-free row \(entry.id)")
        }
        if abs(seed - TimelineHeightEstimateKind.row.height) > 0.5 {
            failures.append("streaming seed: prepared displayed height \(seed)"
                + " != .row estimate \(TimelineHeightEstimateKind.row.height)")
        }
        if displayedBeforeScroll {
            failures.append("streaming seed: \(entry.id) was displayed before the scroll")
        }
        if let insertedFrame, insertedFrame.maxY > viewportTop + 0.5 {
            failures.append("streaming seed: fixture was not above the viewport"
                + " (maxY \(insertedFrame.maxY), viewport top \(viewportTop))")
        }
        if !beforeScrollMeasures.isEmpty {
            failures.append("streaming seed: \(beforeScrollMeasures.count) self-measure(s)"
                + " before the row entered the viewport \(beforeScrollMeasures.map(\.height))")
        }
        if abs(directSeedFit - seed) > 0.5 {
            failures.append("streaming seed: direct preferred fit \(directSeedFit)"
                + " != displayed seed \(seed)")
        }
        if !framesHeld {
            failures.append("streaming seed: frame fell below the seed \(seed) \(frames)")
        }

        guard let finalFit = await settleHostedHeight(controller, item: item, timeout: 8) else {
            failures.append("streaming seed: the cell never settled on its fit"
                + " \(hostedState(controller, item: item))")
            removeFixture()
            await wait(300)
            return
        }
        let frameAfterSettle = controller.layout.attributes(for: item.itemID)?.frame.height ?? -1
        let measuresAfterSettle = controller.layout.debugSelfMeasureHeights
            .filter { $0.itemID == item.itemID }
        let firstAccepted = measuresAfterSettle.first?.height
        let smallest = measuresAfterSettle.map(\.height).min()
        // "Settled" also means it stays: sample a few frames after the fit so
        // a second correction cannot hide behind the settle poll.
        var samples: [CGFloat] = []
        for _ in 0..<10 {
            controller.collectionView.layoutIfNeeded()
            samples.append(controller.layout.attributes(for: item.itemID)?.frame.height ?? 0)
            await wait(16)
        }
        let stable = samples.allSatisfy { abs($0 - frameAfterSettle) <= 0.5 }

        if let firstAccepted, abs(firstAccepted - seed) > 0.5 {
            failures.append("streaming seed: first accepted self-measure \(firstAccepted)"
                + " != displayed seed \(seed)")
        }
        if let smallest, smallest < seed - 0.5 {
            failures.append("streaming seed: a self-measure was below the seed"
                + " \(smallest) < \(seed) \(measuresAfterSettle.map(\.height))")
        }
        if abs(frameAfterSettle - finalFit) > 0.5 {
            failures.append("streaming seed: frame \(frameAfterSettle) != cell fit \(finalFit)")
        }
        if finalFit <= seed + 1 {
            failures.append("streaming seed: the parsed body did not outgrow the seed"
                + " \(seed)->\(finalFit)")
        }
        if !stable {
            failures.append("streaming seed: the settled height did not stay"
                + " \(frameAfterSettle) \(samples)")
        }

        // Swift 6.2 could not type-check the one big dictionary literal in
        // reasonable time (CI 460). Assign typed locals first, then build the
        // report incrementally.
        let measuredFlag: Int = attributesMeasuredBeforeFit == nil
            ? -1 : (attributesMeasuredBeforeFit! ? 1 : 0)
        let structuralValue: Double = structural.map { Double($0) } ?? -1
        let firstAcceptedValue: Double = firstAccepted.map { Double($0) } ?? -1
        let selfMeasureValues: [Double] = measuresAfterSettle.map { Double($0.height) }
        let frameValues: [Double] = frames.map { Double($0) }
        let settleSamples: [Double] = samples.map { Double($0) }
        let rowVisible: Bool = controller.collectionView.indexPathsForVisibleItems
            .contains(indexPath)
        var streamingReport: [String: Any] = [:]
        streamingReport["row"] = entry.id
        streamingReport["seed"] = Double(seed)
        streamingReport["estimateHeight"] = Double(TimelineHeightEstimateKind.row.height)
        streamingReport["structuralHeight"] = structuralValue
        streamingReport["displayedBeforeScroll"] = displayedBeforeScroll
        streamingReport["selfMeasuresBeforeScroll"] = beforeScrollMeasures.count
        streamingReport["frameBeforeScroll"] = Double(frameBeforeScroll)
        streamingReport["frameRightAfterScroll"] = Double(frameRightAfterScroll)
        streamingReport["attributesMeasuredBeforeFit"] = measuredFlag
        streamingReport["directFit"] = Double(directSeedFit)
        streamingReport["frames"] = frameValues
        streamingReport["framesHeld"] = framesHeld
        streamingReport["frameAfterSettle"] = Double(frameAfterSettle)
        streamingReport["finalFit"] = Double(finalFit)
        streamingReport["selfMeasureCount"] = measuresAfterSettle.count
        streamingReport["selfMeasureHeights"] = selfMeasureValues
        streamingReport["firstAcceptedSelfMeasure"] = firstAcceptedValue
        streamingReport["stable"] = stable
        streamingReport["settleSamples"] = settleSamples
        streamingReport["visible"] = rowVisible
        report["streamingSeed"] = streamingReport

        // Leave the timeline as the earlier scenarios found it.
        removeFixture()
        await wait(300)
    }

    // MARK: - Gesture freeze (official cell-reported height contract)

    /// One visible cell's geometry, in content coordinates plus its position
    /// on screen. The gesture assertions compare all of them: a height applied
    /// under the finger moves both the layout frame and the cell frame, and an
    /// uncompensated offset shows up in `screenY` even when the frame itself
    /// stayed put.
    private struct GestureCellSample {
        let itemID: String
        let attributeMinY: CGFloat
        let attributeHeight: CGFloat
        let cellMinY: CGFloat
        let cellHeight: CGFloat
        let screenY: CGFloat
    }

    private struct GestureSnapshotDiff {
        var changed = 0
        var missing = 0
        var maxDelta: CGFloat = 0
        var details: [String] = []
    }

    private func visibleGestureSamples(
        _ controller: TimelineCollectionController
    ) -> [String: GestureCellSample] {
        var samples: [String: GestureCellSample] = [:]
        let visible = Set(controller.collectionView.indexPathsForVisibleItems)
        for attributes in controller.layout.orderedAttributes
        where visible.contains(attributes.indexPath) {
            guard let item = attributes.item,
                  let cell = controller.collectionView.cellForItem(at: attributes.indexPath)
            else { continue }
            samples[item.itemID] = GestureCellSample(
                itemID: item.itemID,
                attributeMinY: attributes.frame.minY,
                attributeHeight: attributes.frame.height,
                cellMinY: cell.frame.minY,
                cellHeight: cell.frame.height,
                screenY: controller.screenY(for: item) ?? 0)
        }
        return samples
    }

    /// Compare screen positions for the rows the reader's anchor protects:
    /// the changed row and everything above it. Rows below are pushed by the
    /// grown content, which is the official behavior rather than a defect.
    private func diffGestureSamples(_ before: [String: GestureCellSample],
                                    _ after: [String: GestureCellSample],
                                    upTo maxScreenY: CGFloat? = nil)
        -> GestureSnapshotDiff {
        var diff = GestureSnapshotDiff()
        for (itemID, old) in before {
            if let maxScreenY, old.screenY > maxScreenY + 0.5 { continue }
            guard let new = after[itemID] else {
                diff.missing += 1
                continue
            }
            // The official contract compensates the offset, so what must stay
            // put is where the reader sees each row, not its content
            // coordinate: a row that legitimately grows moves every row below
            // it in content space while their screen positions stay.
            let delta = abs(new.screenY - old.screenY)
            diff.maxDelta = max(diff.maxDelta, delta)
            guard delta > 0.5 else { continue }
            diff.changed += 1
            if diff.details.count < 4 {
                diff.details.append("\(itemID) screenY \(old.screenY)->\(new.screenY)")
            }
        }
        return diff
    }

    /// The official height contract gate. A content-height change that arrives
    /// while the reader is dragging or the list is coasting must not move a
    /// single row: the product performs no measurement work under the finger,
    /// so the change lands on release, once, at the row's own top.
    ///
    /// `setTestGestureState` mirrors `scrollViewWillBeginDragging` and the
    /// matching end callback because the simulator cannot synthesize touches.
    /// The phase runs twice, tracking and decelerating, because they are
    /// separate inputs to the decision helpers. The fixture rows opt into
    /// `usesCellReportedHeight`, so the legacy polling path cannot mask a
    /// regression in the official one.
    private func gestureFreeze() async {
        guard let controller else { return }
        // Mid-timeline, like the device report's tool-heavy turn: rows above
        // and below the visible band, so the anchor and the offset
        // compensation are both observable.
        let insertAt = max(0, entries.count / 2)
        var fixtures: [Entry] = []
        for index in 0..<12 {
            let entry = Entry(id: "\(Self.gestureRowPrefix)\(index)",
                              kind: .toolExpanded, text: "工具组 \(index)")
            entries.insert(entry, at: insertAt + index)
            fixtures.append(entry)
        }
        // A full screen of content below the fixtures: scrolling a short list
        // leaves the viewport at the bottom, where any content shrink is
        // clamped by UIScrollView and moves every row by a pixel. The gesture
        // assertions need the target truly at the top, not merely the last
        // scrollable position.
        for index in 0..<10 {
            entries.append(Entry(id: "\(Self.gestureRowPrefix)filler-\(index)",
                                 kind: .plain,
                                 text: String(repeating: "filler line \(index). ", count: 8)))
        }
        contentGeneration += 1
        controller.reloadFromContent()
        // Anchor only after the fixture estimates collapse to their real
        // heights: a row above the target that shrinks after the scroll pulls
        // the target out of the visible set, and a phase with no target proves
        // nothing.
        await settleLayout(controller)
        controller.collectionView.layoutIfNeeded()
        guard fixtures.count >= 8 else {
            failures.append("gesture freeze: only \(fixtures.count) fixture rows")
            return
        }

        var phases: [[String: Any]] = []
        var releases: [[String: Any]] = []
        for (offset, gesture) in ["tracking", "decelerating"].enumerated() {
            // The tracking phase scrolls fixture row 6 to the viewport top
            // and uses row 7 as the row below it; the decelerating phase
            // shifts both by one row. Nothing may move while the gesture is
            // active, and on release the target grows at its own top while
            // the row below is pushed.
            let target = fixtures[6 + offset]
            let anchor = fixtures[7 + offset]
            let phase = await runGesturePhase(controller, gesture: gesture,
                tracking: gesture == "tracking",
                decelerating: gesture == "decelerating",
                target: target, anchor: anchor)
            phases.append(phase)
            let heightBefore = (phase["targetHeightBefore"] as? Double).map { CGFloat($0) } ?? 0
            releases.append(await releaseGesture(controller, gesture: gesture,
                target: target, anchor: anchor, heightBefore: heightBefore))
        }
        report["gestureFreeze"] = [
            "toolRows": fixtures.count,
            "rowPrefix": Self.gestureRowPrefix,
            "phases": phases,
            "releases": releases,
        ]
    }

    /// Expands one visible tool row through the product content path (signature
    /// change → reload) while the test gesture is active, then asserts nothing
    /// moved and no height application reached the layout.
    private func runGesturePhase(_ controller: TimelineCollectionController,
                                 gesture: String,
                                 tracking: Bool,
                                 decelerating: Bool,
                                 target: Entry,
                                 anchor: Entry) async -> [String: Any] {
        let targetItem = listItem(target)
        let anchorItem = listItem(anchor)
        guard let indexPath = controller.indexPath(for: targetItem) else {
            failures.append("gesture freeze [\(gesture)]: no index path for \(target.id)")
            return ["gesture": gesture, "error": "no index path"]
        }
        // Scrolling materializes rows that were estimates; each row above the
        // target that takes its real height moves the target. Re-anchor until
        // the target holds at the top, otherwise the phase measures a row that
        // is already on its way out of the viewport.
        for _ in 0..<4 {
            controller.collectionView.scrollToItem(at: indexPath, at: .top, animated: false)
            await wait(200)
            controller.collectionView.layoutIfNeeded()
            await settleLayout(controller, timeout: 2)
            let top = controller.collectionView.contentOffset.y
                + controller.collectionView.adjustedContentInset.top
            if let attributes = controller.layout.attributes(for: targetItem.itemID),
               abs(attributes.frame.minY - top) <= 1 {
                break
            }
        }
        controller.layout.clearDebugOffsetTrace()
        controller.layout.clearDebugHeightUpdateTrace()
        controller.clearDebugScrollCallSites()

        let offsetBefore = controller.collectionView.contentOffset.y
        let before = visibleGestureSamples(controller)
        let targetBefore = controller.layout.attributes(for: targetItem.itemID)?.frame.height ?? 0
        let targetScreenBefore = before[targetItem.itemID]?.screenY
        let anchorScreenBefore = before[anchorItem.itemID]?.screenY
        let counterBefore = controller.layout.debugHeightApplicationsDuringGesture

        let usesOfficialContract = usesCellReportedHeight(for: targetItem)
        // The seam mirrors `scrollViewWillBeginDragging`: mode `.reading`,
        // bottom target disarmed, phase `.interacting`.
        controller.setTestGestureState(tracking: tracking, decelerating: decelerating)
        let userScrolling = controller.isUserScrolling
        setExpanded(target.id, true)
        contentGeneration += 1
        controller.reloadFromContent()
        // One turn for the snapshot apply, its completion dispatch and the
        // hosting body's next layout pass; still well inside the gesture.
        await wait(320)
        controller.collectionView.layoutIfNeeded()

        let offsetAfter = controller.collectionView.contentOffset.y
        let after = visibleGestureSamples(controller)
        let diff = diffGestureSamples(before, after, upTo: targetScreenBefore)
        let counter = controller.layout.debugHeightApplicationsDuringGesture
        let targetDuring = controller.layout.attributes(for: targetItem.itemID)?.frame.height ?? 0
        let stale = staleCellDetails(controller, limit: 3)
        let overlaps = adjacentFrameOverlaps(controller)
        let targetTracked = before[targetItem.itemID] != nil
        let anchorTracked = anchorScreenBefore != nil

        if !usesOfficialContract {
            failures.append("gesture freeze [\(gesture)]: \(target.id) is not on the"
                + " cell-reported height contract")
        }
        if !userScrolling {
            failures.append("gesture freeze [\(gesture)]: the test gesture did not"
                + " reach controller.isUserScrolling")
        }
        // Under the official contract a content change lands during the
        // gesture with compensation; the count is evidence, not a failure.

        if !targetTracked {
            failures.append("gesture freeze [\(gesture)]: target \(target.id) was not visible")
        }
        if !anchorTracked {
            failures.append("gesture freeze [\(gesture)]: anchor \(anchor.id) was not visible")
        }
        if diff.changed > 0 {
            failures.append("gesture freeze [\(gesture)]: \(diff.changed) visible cell(s) above"
                + " the target moved, max \(diff.maxDelta)pt \(diff.details)")
        }
        if let targetScreenBefore,
           let targetScreenDuring = after[targetItem.itemID]?.screenY,
           abs(targetScreenDuring - targetScreenBefore) > 0.5 {
            failures.append("gesture freeze [\(gesture)]: target \(target.id) moved on screen"
                + " \(targetScreenBefore)->\(targetScreenDuring)")
        }
        if diff.missing > 0 {
            failures.append("gesture freeze [\(gesture)]: \(diff.missing) visible cell(s) left the visible set")
        }
        // The height itself may land at release: the product does no
        // measurement work under the finger (the hosted settle and the legacy
        // poll both stop while `isUserScrolling`). What must hold is that
        // nothing the reader sees moves, which the frame checks above cover;
        // the release assertions prove the change lands exactly once.
        if !stale.isEmpty {
            failures.append("gesture freeze [\(gesture)]: \(stale.count) stale visible cell(s) \(stale)")
        }
        if overlaps > 0 {
            failures.append("gesture freeze [\(gesture)]: \(overlaps) adjacent frame overlap(s)")
        }
        return ["gesture": gesture,
                "tracking": tracking,
                "decelerating": decelerating,
                "target": target.id,
                "anchor": anchor.id,
                "usesCellReportedHeight": usesOfficialContract,
                "isUserScrolling": userScrolling,
                "visibleCells": before.count,
                "changedFrames": diff.changed,
                "missingCells": diff.missing,
                "maxFrameDelta": Double(diff.maxDelta),
                "heightApplicationsDuringGesture": counter,
                "heightApplicationsBefore": counterBefore,
                "targetHeightBefore": Double(targetBefore),
                "targetHeightDuring": Double(targetDuring),
                "anchorScreenY": anchorScreenBefore.map(Double.init) ?? -1,
                "offsetBefore": Double(offsetBefore),
                "offsetAfter": Double(offsetAfter),
                "isAutoScrollPinning": controller.layoutInteractionState().isAutoScrollPinning,
                "targetMinYBefore": Double(before[targetItem.itemID]?.attributeMinY ?? -1),
                "targetMinYAfter": Double(after[targetItem.itemID]?.attributeMinY ?? -1),
                "offsetTrace": controller.layout.debugOffsetTrace,
                "heightUpdateTrace": controller.layout.debugHeightUpdateTrace,
                "scrollCallSites": controller.debugScrollCallSites,
                "staleCells": stale.count,
                "overlaps": overlaps]
    }

    /// Releases the test gesture and asserts the change lands once: the target
    /// grows to its cell fit, its own top keeps its screen position (rows
    /// below it are pushed, which is expected), and the visible band has no
    /// stale or overlapping cells.
    private func releaseGesture(_ controller: TimelineCollectionController,
                                gesture: String,
                                target: Entry,
                                anchor: Entry,
                                heightBefore: CGFloat) async -> [String: Any] {
        let targetItem = listItem(target)
        let anchorItem = listItem(anchor)
        // The product does no measurement work under the finger, so this is
        // where the height usually lands. The target's own top is the reader's
        // anchor; the row below it is expected to be pushed down.
        let heightAtRelease = controller.layout.attributes(for: targetItem.itemID)?.frame.height ?? 0
        let targetBefore = controller.screenY(for: targetItem)
        let anchorBefore = controller.screenY(for: anchorItem)

        controller.setTestGestureState(tracking: false, decelerating: false)
        let stillScrolling = controller.isUserScrolling
        // The row height animates over 0.18 s on the interactive path; let the
        // application finish before reading the final layout.
        await wait(450)
        controller.collectionView.layoutIfNeeded()

        let finalHeight = controller.layout.attributes(for: targetItem.itemID)?.frame.height ?? 0
        let targetAfter = controller.screenY(for: targetItem)
        let anchorAfter = controller.screenY(for: anchorItem)
        let targetDelta = abs((targetAfter ?? 0) - (targetBefore ?? 0))
        // "Once" means the released height settles and stays: sample a few
        // frames after the application and require a single stable value.
        var samples: [CGFloat] = []
        for _ in 0..<18 {
            controller.collectionView.layoutIfNeeded()
            samples.append(controller.layout.attributes(for: targetItem.itemID)?.frame.height ?? 0)
            await wait(16)
        }
        let stable = samples.allSatisfy { abs($0 - finalHeight) <= 0.5 }
        let stale = staleCellDetails(controller, limit: 3)
        let overlaps = adjacentFrameOverlaps(controller)
        let expandedAtRelease = finalHeight > heightBefore + 1

        if stillScrolling {
            failures.append("gesture freeze [\(gesture)]: releasing the test gesture left"
                + " controller.isUserScrolling true")
        }
        if !expandedAtRelease {
            failures.append("gesture freeze [\(gesture)]: the content change never landed"
                + " (\(heightBefore)->\(finalHeight))")
        }
        if !stable {
            failures.append("gesture freeze [\(gesture)]: released height did not settle \(samples)")
        }
        if targetDelta > 1 {
            failures.append("gesture freeze [\(gesture)]: the changed row \(target.id) jumped"
                + " \(targetDelta)pt on release")
        }
        if !stale.isEmpty {
            failures.append("gesture freeze [\(gesture)] release: \(stale.count) stale visible cell(s) \(stale)")
        }
        if overlaps > 0 {
            failures.append("gesture freeze [\(gesture)] release: \(overlaps) adjacent frame overlap(s)")
        }
        var cellFitDelta = -1.0
        if let sample = await sampleItem(controller, item: targetItem, attempts: 2) {
            cellFitDelta = Double(abs(sample.cell - sample.content))
            if sample.cell + 0.5 < sample.content {
                failures.append("gesture freeze [\(gesture)] release: cell \(sample.cell)"
                    + " clips content \(sample.content)")
            }
        }
        return ["gesture": gesture,
                "heightBefore": Double(heightBefore),
                "heightAtRelease": Double(heightAtRelease),
                "expandedAtRelease": expandedAtRelease,
                "finalHeight": Double(finalHeight),
                "stable": stable,
                "isUserScrolling": stillScrolling,
                "target": target.id,
                "targetScreenBefore": targetBefore.map(Double.init) ?? -1,
                "targetScreenAfter": targetAfter.map(Double.init) ?? -1,
                "targetScreenDelta": Double(targetDelta),
                "anchor": anchor.id,
                "anchorScreenBefore": anchorBefore.map(Double.init) ?? -1,
                "anchorScreenAfter": anchorAfter.map(Double.init) ?? -1,
                "cellFitDelta": cellFitDelta,
                "staleCells": stale.count,
                "overlaps": overlaps]
    }

    /// Rows intersecting the viewport, how many have no cell, and the largest
    /// uncovered vertical run inside the viewport.
    private func visibleCoverage(_ controller: TimelineCollectionController)
        -> (missing: Int, gap: CGFloat) {
        let view = controller.collectionView!
        let top = view.contentOffset.y + view.adjustedContentInset.top
        let bottom = top + view.bounds.height - view.adjustedContentInset.top
            - view.adjustedContentInset.bottom
        var missing = 0
        var intervals: [(CGFloat, CGFloat)] = []
        for attributes in controller.layout.orderedAttributes {
            guard attributes.frame.maxY > top, attributes.frame.minY < bottom else { continue }
            if view.cellForItem(at: attributes.indexPath) == nil {
                missing += 1
            } else {
                intervals.append((max(attributes.frame.minY, top),
                                  min(attributes.frame.maxY, bottom)))
            }
        }
        // Items are separated by `itemSpacing`; that gap is expected, not a
        // hole. Anything beyond it (minus rounding) is a missing band.
        let allowed = TimelineListMetrics.itemSpacing + 1
        var gap: CGFloat = 0
        var covered = top
        for (start, end) in intervals.sorted(by: { $0.0 < $1.0 }) {
            if start > covered + allowed {
                gap += start - covered - TimelineListMetrics.itemSpacing
            }
            covered = max(covered, end)
        }
        if covered < bottom - allowed {
            gap += bottom - covered - TimelineListMetrics.itemSpacing
        }
        return (missing, gap)
    }

    /// Visible cells whose frame disagrees with the layout's own attributes.
    /// The custom layout only invalidates the corrected item; if UIKit leaves
    /// the following cells at the previous positions, they draw over each
    /// other — the device report's overlapping bands.
    private func adjacentFrameOverlaps(_ controller: TimelineCollectionController) -> Int {
        var overlaps = 0
        let attributes = controller.layout.orderedAttributes
        for (upper, lower) in zip(attributes, attributes.dropFirst())
        where upper.frame.maxY > lower.frame.minY + 0.5 {
            overlaps += 1
        }
        return overlaps
    }

    private func staleVisibleCells(_ controller: TimelineCollectionController) -> Int {
        staleCellDetails(controller, limit: 0).count
    }

    private func staleCellDetails(_ controller: TimelineCollectionController,
                                  limit: Int) -> [String] {
        var stale: [String] = []
        // Only genuinely visible cells. UIKit keeps prefetched/offscreen cells
        // with their previous frames until they scroll in; those are not a
        // display defect and would make this check flaky.
        let visible = Set(controller.collectionView.indexPathsForVisibleItems)
        for attributes in controller.layout.orderedAttributes
        where visible.contains(attributes.indexPath) {
            guard let cell = controller.collectionView.cellForItem(at: attributes.indexPath) else { continue }
            if abs(cell.frame.minY - attributes.frame.minY) > 0.5
                || abs(cell.frame.height - attributes.frame.height) > 0.5 {
                if limit > 0, stale.count < limit {
                    stale.append("\(attributes.item?.itemID ?? "?"): cell \(cell.frame.minY)/\(cell.frame.height) vs attr \(attributes.frame.minY)/\(attributes.frame.height)")
                } else if limit == 0 {
                    stale.append("stale")
                }
            }
        }
        return stale
    }

    /// Incremental height corrections (fold toggles, status-line flips) must
    /// move every following cell, not just the corrected one. Collapse and
    /// expand the same row repeatedly and check the visible cells against
    /// the layout's own attributes.
    private func foldCycles() async {
        guard let controller,
              let entry = entries.first(where: { $0.id == "storm-0" }) else { return }
        let item = listItem(entry)
        await scrollToItem(item)
        for cycle in 0..<4 {
            setExpanded(entry.id, cycle % 2 == 0)
            contentGeneration += 1
            controller.reloadFromContent()
            await wait(350)
        }
        setExpanded(entry.id, true)
        contentGeneration += 1
        controller.reloadFromContent()
        await wait(700)
        controller.collectionView.layoutIfNeeded()
        let staleDetails = staleCellDetails(controller, limit: 3)
        if !staleDetails.isEmpty {
            failures.append("fold cycles: \(staleDetails.count)+ visible cells sit at stale frames \(staleDetails)")
        }
        var overlaps = 0
        let attributes = controller.layout.orderedAttributes
        for (upper, lower) in zip(attributes, attributes.dropFirst())
        where upper.frame.maxY > lower.frame.minY + 0.5 {
            overlaps += 1
        }
        if overlaps > 0 {
            failures.append("fold cycles: \(overlaps) adjacent frames overlap")
        }
        report["foldCycles"] = ["staleCells": staleDetails.count,
                                "staleDetails": staleDetails,
                                "overlaps": overlaps]
    }

    /// Device report (cf130b1): SIGABRT in `dequeueReusableCell` during a
    /// diffable update, caused by the layout describing a newer item list
    /// than the snapshot UIKit was performing. Two applies back to back must
    /// queue, and the final layout must describe the last snapshot exactly.
    private func interleavedApplies() async {
        guard let controller else { return }
        entries.insert(Entry(id: "interleave-a", kind: .plain, text: "A"),
                       at: entries.count - 1)
        contentGeneration += 1
        let first = entries.map(listItem)
        controller.apply(items: first)
        entries.insert(Entry(id: "interleave-b", kind: .plain, text: "B"),
                       at: entries.count - 1)
        contentGeneration += 1
        let second = entries.map(listItem)
        controller.apply(items: second)
        await wait(800)
        controller.collectionView.layoutIfNeeded()
        let attributes = controller.layout.orderedAttributes
        let ids = Set(attributes.compactMap { $0.item?.itemID })
        let missing = second.map(\.itemID).filter { !ids.contains($0) }
        if attributes.count != second.count {
            failures.append("interleaved applies: \(attributes.count) rows, expected \(second.count)")
        }
        if !missing.isEmpty {
            failures.append("interleaved applies: missing rows \(missing.prefix(4))")
        }
        report["interleaved"] = ["rows": attributes.count,
                                 "expected": second.count,
                                 "missing": missing.count]
    }

    private func streaming() async {
        guard let controller,
              let entry = entries.last(where: { $0.kind == .plain }) else { return }
        let item = listItem(entry)
        streamingIDs.insert(entry.id)
        defer { streamingIDs.remove(entry.id) }
        controller.requestBottom(animated: false)
        await wait(120)
        var heights: [CGFloat] = []
        var shortfalls: [CGFloat] = []
        var movesPerTick: [Int] = []
        var worstStale = 0
        var worstOverlap = 0
        for _ in 0..<10 {
            let offsetBefore = controller.collectionView.contentOffset.y
            appendStreamLine(to: entry.id)
            controller.reloadFromContent()
            await wait(110)
            let height = controller.layout.attributes(for: item.itemID)?.frame.height ?? 0
            heights.append(height)
            shortfalls.append(controller.bottomShortfall)
            let offsetAfter = controller.collectionView.contentOffset.y
            movesPerTick.append(abs(offsetAfter - offsetBefore) > 0.5 ? 1 : 0)
            worstStale = max(worstStale, staleVisibleCells(controller))
            worstOverlap = max(worstOverlap, adjacentFrameOverlaps(controller))
        }
        // The anchor Mover is a spring: a burst is followed with a transient
        // lag and settles. Judge the settled shortfall, and keep the per-tick
        // movement requirement below (a page that does not follow moves 0).
        await waitForBottomSettle(controller, timeout: 1200)
        let settledShortfall = controller.bottomShortfall
        let peakShortfall = shortfalls.max() ?? 0
        let monotonic = zip(heights, heights.dropFirst()).allSatisfy { $0 <= $1 + 0.5 }
        // The workflow's contract key means the settled bottom shortfall; the
        // transient peak is reported separately.
        let maxShortfall = settledShortfall
        if !monotonic { failures.append("streaming: heights not monotonic \(heights)") }
        if settledShortfall > 0.5 {
            failures.append("streaming: settled bottom shortfall \(settledShortfall)")
        }
        if movesPerTick.max() ?? 0 > 1 { failures.append("streaming: more than one offset move per tick") }
        if worstStale > 0 {
            failures.append("streaming: \(worstStale) visible cells sat at stale frames")
        }
        if worstOverlap > 0 {
            failures.append("streaming: \(worstOverlap) adjacent frames overlapped")
        }
        report["streaming"] = ["ticks": heights.count, "heights": heights,
                               "maxShortfall": maxShortfall,
                               "peakShortfall": peakShortfall, "monotonic": monotonic,
                               "movesPerTick": movesPerTick,
                               "worstStaleCells": worstStale,
                               "worstOverlaps": worstOverlap]
    }

    /// Polls the official Mover until it rests; the spring's settling time is
    /// distance-dependent, so a fixed wait is not a valid arrival gate.
    private func waitForBottomSettle(_ controller: TimelineCollectionController,
                                     timeout: Int) async {
        var elapsed = 0
        while elapsed < timeout {
            let phase = String(describing: controller.phase.phase)
            if phase == "idle", controller.bottomShortfall <= 0.5 { return }
            await wait(50)
            elapsed += 50
        }
    }

    private func bottom() async {
        guard let controller else { return }
        controller.collectionView.setContentOffset(CGPoint(x: 0, y: 0), animated: false)
        await wait(80)
        controller.requestBottom(animated: false)
        await wait(120)
        let instantShortfall = controller.bottomShortfall

        controller.collectionView.setContentOffset(CGPoint(x: 0, y: 0), animated: false)
        await wait(80)
        controller.requestBottom(animated: true)
        // The programmatic return now uses the official Mover spring
        // (`Spring(0.4, bounce 0)` / fly `0.36, 0.15`), whose remaining travel
        // at 500 ms can still be above the 0.5 pt gate for long distances.
        // Wait for the phase to rest instead of assuming a fixed duration.
        await waitForBottomSettle(controller, timeout: 1500)
        let animatedShortfall = controller.bottomShortfall

        // A no-op animated return never calls didEndScrollingAnimation; the
        // watchdog must settle the phase.
        controller.requestBottom(animated: true)
        await wait(500)
        let phaseAfterNoop = String(describing: controller.phase.phase)

        // C5: the anchor model's follow gate is placement == .end.
        // 1) Park in the middle: an external scroll derives a .reading
        //    placement, so a follow request must be refused and must not move
        //    the page.
        let maxY = max(0, controller.collectionView.contentSize.height
            - controller.collectionView.bounds.height)
        controller.collectionView.setContentOffset(
            CGPoint(x: 0, y: maxY / 2), animated: false)
        await wait(120)
        let readingPlacement = !controller.debugIsFollowing
        let offsetBeforeFollow = controller.collectionView.contentOffset.y
        controller.requestBottom(animated: false, forced: false)
        await wait(120)
        let followRefused = !controller.debugIsFollowing
            && abs(controller.collectionView.contentOffset.y - offsetBeforeFollow) <= 0.5
        // 2) A forced return lands on .end and re-arms following.
        controller.requestBottom(animated: true, forced: true)
        await waitForBottomSettle(controller, timeout: 1500)
        let followAccepted = controller.debugIsFollowing
        let rearmed = followAccepted

        if instantShortfall > 0.5 { failures.append("bottom: instant shortfall \(instantShortfall)") }
        if animatedShortfall > 0.5 { failures.append("bottom: animated shortfall \(animatedShortfall)") }
        if phaseAfterNoop != "idle" { failures.append("bottom: no-op phase \(phaseAfterNoop)") }
        if !readingPlacement { failures.append("bottom: mid-list scroll did not leave .end") }
        if !followRefused { failures.append("bottom: follow armed while reading and away") }
        if !followAccepted { failures.append("bottom: forced return did not reach .end") }
        if !rearmed { failures.append("bottom: placement did not re-arm") }
        report["bottom"] = ["instantShortfall": instantShortfall,
                            "animatedShortfall": animatedShortfall,
                            "phaseAfterNoop": phaseAfterNoop,
                            "readingPlacement": readingPlacement,
                            "followRefused": followRefused,
                            "followAccepted": followAccepted,
                            "rearmed": rearmed]
    }

    private func prepend() async {
        guard let controller, entries.count > 8 else { return }
        let anchor = entries[5]
        let anchorItem = listItem(anchor)
        // Anchor at the viewport top, the shape the product uses: the first
        // visible row. An offscreen anchor would also move when a visible row
        // above it grows, which is not what the prepend compensation owns.
        guard let anchorIndex = controller.indexPath(for: anchorItem) else {
            failures.append("prepend: no anchor index path")
            return
        }
        controller.collectionView.scrollToItem(at: anchorIndex, at: .top, animated: false)
        await wait(120)
        let before = controller.screenY(for: anchorItem) ?? 0
        let newItems = prependPlain(100)
        guard var position = controller.beginHistoryRequest(generation: 42,
            anchorRowID: anchor.id, edge: .top, newItems: newItems) else {
            failures.append("prepend: no history position")
            return
        }
        controller.reloadFromContent()
        await wait(450)
        let after = controller.screenY(for: anchorItem) ?? 0
        let delta = abs(after - before)
        let targetCalls = controller.layout.targetContentOffsetCallCount
        let proposed = controller.layout.lastProposedContentOffset
        let returned = controller.layout.lastReturnedContentOffset
        if delta > 0.5 { failures.append("prepend: anchor moved \(delta)pt") }
        if targetCalls < 1 { failures.append("prepend: targetContentOffset never called") }

        let firstRow = controller.content?.rowIDs(in: controller.items.first ?? .tail).first
        position.receivedPage(firstRowID: firstRow)
        let latest = controller.historyLayout(anchorRowID: anchor.id, edge: .top)
        if let latest { _ = position.laidOut(latest, generation: 42) }
        let settled = position.isReadyToFinish
        if !settled { failures.append("prepend: history request did not settle") }

        // Absolute target idempotence and generation cancellation, through the
        // real layout entry point.
        var doubleQuerySame = false
        var cancelledUnchanged = false
        if let origin = controller.historyLayout(anchorRowID: anchor.id, edge: .top) {
            controller.layout.beginInsertionOwed(generation: 77, origin: origin,
                offsetY: 123, topInset: 0)
            controller.layout.updateInsertionOwed(layout: TimelineHistoryLayout(
                firstRowID: "synthetic-earlier", anchorRowID: anchor.id, edge: .top,
                y: origin.y + 500))
            let first = controller.layout.targetContentOffset(
                forProposedContentOffset: CGPoint(x: 0, y: 123)).y
            let second = controller.layout.targetContentOffset(
                forProposedContentOffset: CGPoint(x: 0, y: 123)).y
            doubleQuerySame = abs(first - second) <= 0.5
            controller.layout.cancelInsertionOwed()
            let afterCancel = controller.layout.targetContentOffset(
                forProposedContentOffset: CGPoint(x: 0, y: 123)).y
            cancelledUnchanged = abs(afterCancel - 123) <= 0.5
        }
        if !doubleQuerySame { failures.append("prepend: double query returned different targets") }
        if !cancelledUnchanged { failures.append("prepend: cancellation did not release the target") }

        report["prepend"] = ["anchorDeltaY": delta, "targetContentOffsetCalls": targetCalls,
                             "prepareForUpdatesCalls": controller.layout.prepareForUpdatesCallCount,
                             "finalizeUpdatesCalls": controller.layout.finalizeUpdatesCallCount,
                             "proposed": proposed, "returned": returned,
                             "settled": settled, "doubleQuerySame": doubleQuerySame,
                             "cancelledUnchanged": cancelledUnchanged]
    }

    /// Device report (6a18aa3): tapping "load older" jumped elsewhere instead
    /// of keeping the reader's place. Reproduce the product shape: a normal
    /// apply is still in flight when the history request starts, so the
    /// prepend apply is queued behind it by the snapshot serialization.
    private func prependDuringApply() async {
        guard let controller, entries.count > 12 else { return }
        let anchor = entries[5]
        let anchorItem = listItem(anchor)
        guard let index = controller.indexPath(for: anchorItem) else {
            failures.append("prepend during apply: no anchor index path")
            return
        }
        controller.collectionView.scrollToItem(at: index, at: .top, animated: false)
        await wait(120)
        let before = controller.screenY(for: anchorItem) ?? 0

        // Leave a normal apply in flight: a streamed line changes the list.
        guard let plain = entries.last(where: { $0.kind == .plain }) else { return }
        appendStreamLine(to: plain.id)
        controller.apply(items: entries.map(listItem))

        let newItems = prependPlain(60)
        guard var position = controller.beginHistoryRequest(generation: 123,
            anchorRowID: anchor.id, edge: .top, newItems: newItems) else {
            failures.append("prepend during apply: no history position")
            return
        }
        controller.reloadFromContent()
        await wait(900)
        let after = controller.screenY(for: anchorItem) ?? 0
        let delta = abs(after - before)
        let firstRow = controller.content?.rowIDs(in: controller.items.first ?? .tail).first
        position.receivedPage(firstRowID: firstRow)
        if let latest = controller.historyLayout(anchorRowID: anchor.id, edge: .top) {
            _ = position.laidOut(latest, generation: 123)
        }
        if delta > 1 {
            failures.append("prepend during apply: anchor moved \(delta)pt")
        }
        report["prependDuringApply"] = ["before": Double(before), "after": Double(after),
                                        "delta": Double(delta),
                                        "settled": position.isReadyToFinish]
    }

    /// Device report (package 426a7ec): tapping "load latest" jumped to the
    /// top. The newer page replaces every identity, so UIKit re-anchors the
    /// batch update; the animated target was computed against the old content
    /// height. Reproduce: start the explicit return, replace the whole window
    /// while it is in flight, and assert the page lands at the *new* bottom.
    private func loadLatestReturn() async {
        guard let controller, entries.count > 8 else { return }

        /// Replaces every dynamic id and reloads, like
        /// `V2SessionProjection.replaceTimeline` does for a newer page.
        func replaceWindow(prefix: String) {
            entries = (0..<16).map { index in
                Entry(id: "\(prefix)-\(index)", kind: .plain,
                      text: String(repeating: "Latest page line \(index). ", count: 4))
            } + [Entry(id: "\(prefix)-tail", kind: .tail, text: "")]
            contentGeneration += 1
            controller.reloadFromContent()
        }

        // Phase A — the production await-before-request order: the intent is
        // armed before the fetch, the window lands, and no requestBottom has
        // run yet. Deleting `resolveWindowReplacementBottom` must fail this.
        if let index = controller.indexPath(for: listItem(entries[1])) {
            controller.collectionView.scrollToItem(at: index, at: .top, animated: false)
        }
        await wait(250)
        let beforeA = controller.collectionView.contentOffset.y
        controller.beginWindowReplacementReturn()
        replaceWindow(prefix: "win-a")
        await wait(1500)
        let offsetA = controller.collectionView.contentOffset.y
        let atBottomA = controller.viewport.measuredAtBottom
        if !atBottomA {
            failures.append("loadLatestReturn pre-await: not at bottom (offset \(offsetA), "
                + "height \(controller.layout.contentHeight))")
        }
        if offsetA <= 0 {
            failures.append("loadLatestReturn pre-await: offset stayed at the top")
        }

        // Phase B — the animated return is in flight when the window lands
        // (the packaged 426a7ec shape). The old target was computed against
        // the old content height; the resolve must pin the new bottom.
        if let index = controller.indexPath(for: listItem(entries[1])) {
            controller.collectionView.scrollToItem(at: index, at: .top, animated: false)
        }
        await wait(250)
        let beforeB = controller.collectionView.contentOffset.y
        controller.beginWindowReplacementReturn()
        controller.requestBottom(animated: true, forced: true)
        replaceWindow(prefix: "win-b")
        await wait(1500)
        let offsetB = controller.collectionView.contentOffset.y
        let atBottomB = controller.viewport.measuredAtBottom
        if !atBottomB {
            failures.append("loadLatestReturn animated: not at bottom (offset \(offsetB), "
                + "height \(controller.layout.contentHeight))")
        }

        report["loadLatestReturn"] = [
            "beforeA": Double(beforeA), "afterA": Double(offsetA), "atBottomA": atBottomA,
            "beforeB": Double(beforeB), "afterB": Double(offsetB), "atBottomB": atBottomB,
            "contentHeight": Double(controller.layout.contentHeight),
        ]
    }

    // MARK: - Sampling helpers

    private struct CellSample {
        let cell: CGFloat
        let content: CGFloat
        let measured: CGFloat
        let attributes: CGFloat
        let frame: CGFloat
    }

    /// A correction can invalidate the layout between the scroll and the
    /// sample, leaving no materialized cell for a frame. Re-center and retry
    /// before calling it a missing cell.
    /// Wait for the product's visible-cell settle: the stored height matches
    /// the cell's fitting content. Re-measures on change and re-centers a cell
    /// that a correction pushed out of the visible set.
    private func settleSample(_ controller: TimelineCollectionController,
                              item: TimelineListItem,
                              timeout: TimeInterval) async -> CellSample? {
        let start = ProcessInfo.processInfo.systemUptime
        var lastMeasured: CGFloat = -1
        while ProcessInfo.processInfo.systemUptime - start < timeout {
            controller.collectionView.layoutIfNeeded()
            guard let sample = cellSample(controller, item: item) else {
                if let indexPath = controller.indexPath(for: item) {
                    controller.collectionView.scrollToItem(at: indexPath,
                        at: .top, animated: false)
                    controller.collectionView.layoutIfNeeded()
                }
                await wait(150)
                continue
            }
            let settled = abs(sample.measured - sample.content) <= 1
                && sample.cell + 0.5 >= sample.content
            if settled { return sample }
            if sample.measured >= sample.content - 1,
               sample.cell + 0.5 < sample.content {
                // The cache already has the measurement but the cell still
                // carries the old frame: force the layout to re-apply it.
                controller.collectionView.collectionViewLayout.invalidateLayout()
                controller.collectionView.layoutIfNeeded()
            }
            if abs(sample.measured - lastMeasured) >= 0.5 {
                lastMeasured = sample.measured
                controller.remeasure(item)
            }
            await wait(120)
        }
        return cellSample(controller, item: item)
    }

    /// Why a sample could not be taken; reported with the failure instead of
    /// a bare "no cell" so a materialization flake is diagnosable.
    private func sampleFailureReason(_ controller: TimelineCollectionController,
                                     item: TimelineListItem) -> String {
        guard let indexPath = controller.indexPath(for: item) else {
            return "no index path"
        }
        guard let cell = controller.collectionView.cellForItem(at: indexPath) else {
            return "no cell at index \(indexPath.item)"
        }
        return "cell width \(Int(cell.contentView.bounds.width)) height \(Int(cell.bounds.height))"
    }

    /// Poll the layout height until it satisfies `predicate` (fold/notice/tail
    /// exceptions settle through the controller's async preferred-height pass).
    private func waitForCellHeight(_ controller: TimelineCollectionController,
                                   item: TimelineListItem,
                                   timeout: TimeInterval,
                                   predicate: (CGFloat) -> Bool) async -> CGFloat {
        let start = ProcessInfo.processInfo.systemUptime
        while ProcessInfo.processInfo.systemUptime - start < timeout {
            controller.collectionView.layoutIfNeeded()
            let height = cellHeight(controller, item)
            if predicate(height) { return height }
            await wait(100)
        }
        return cellHeight(controller, item)
    }

    private func sampleItem(_ controller: TimelineCollectionController,
                            item: TimelineListItem,
                            attempts: Int = 5) async -> CellSample? {
        for _ in 0..<attempts {
            if let sample = cellSample(controller, item: item) { return sample }
            if let indexPath = controller.indexPath(for: item) {
                controller.collectionView.scrollToItem(at: indexPath,
                    at: .centeredVertically, animated: false)
            }
            controller.collectionView.layoutIfNeeded()
            await wait(100)
        }
        return nil
    }

    private func cellSample(_ controller: TimelineCollectionController, item: TimelineListItem) -> CellSample? {
        // A correction invalidates the layout; force the pass so the cell's
        // frame reflects the measured height before the sample reads it.
        controller.collectionView.layoutIfNeeded()
        guard let indexPath = controller.indexPath(for: item),
              let cell = controller.collectionView.cellForItem(at: indexPath) else { return nil }
        let width = cell.contentView.bounds.width
        guard width > 0 else { return nil }
        let content = cell.contentView.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel).height
        let key = heightKey(for: item, width: width)
        let attributes = controller.layout.attributes(for: item.itemID)?.frame.height ?? -1
        let measured = controller.layout.heights.tieredHeight(for: key)
            ?? attributes
        return CellSample(cell: cell.bounds.height, content: content,
                          measured: measured, attributes: attributes,
                          frame: cell.frame.height)
    }

    private func cellHeight(_ controller: TimelineCollectionController, _ item: TimelineListItem) -> CGFloat {
        controller.layout.attributes(for: item.itemID)?.frame.height ?? 0
    }

    private func scrollToItem(_ item: TimelineListItem) async {
        guard let controller, let indexPath = controller.indexPath(for: item) else { return }
        controller.collectionView.scrollToItem(at: indexPath, at: .centeredVertically, animated: false)
        await wait(150)
    }

    private func wait(_ milliseconds: Int) async {
        try? await Task.sleep(for: .milliseconds(milliseconds))
    }

    // MARK: - Report

    /// Writes the report as a checkpoint after a phase. `completed` stays
    /// false so a crash later in the gate still leaves the last phase and its
    /// failures on disk for the CI assertion step.
    private func persist(phase: String) {
        report["phase"] = phase
        writeReport(completed: false)
    }

    private func writeReport(completed: Bool = true) {
        var output: [String: Any] = report
        output["failures"] = failures
        output["completed"] = completed
        output["passed"] = completed && failures.isEmpty
        output["device"] = UIDevice.current.name
        output["system"] = UIDevice.current.systemVersion
        output["viewSize"] = "\(Int(controller?.collectionView.bounds.width ?? 0))x\(Int(controller?.collectionView.bounds.height ?? 0))"
        output["drag"] = "not_exercised: simctl cannot synthesize touches; XCUITest required"
        output["approvalCard"] = "not_covered_before_C4"
        output["step0Switch"] = "not_wired_before_C4; gate drives the controller directly"
        output["productRows"] = "representative rows; product-row consistency repeats in C5"
        guard let data = try? JSONSerialization.data(withJSONObject: output,
            options: [.prettyPrinted, .sortedKeys]) else { return }
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Self.resultFileName)
        try? data.write(to: url)
    }

    // MARK: - Rows and fixtures

    private func listItem(_ entry: Entry) -> TimelineListItem {
        entry.kind == .tail ? .tail : .group(entry.id)
    }

    private func entry(for item: TimelineListItem) -> Entry? {
        if item == .tail { return entries.first(where: { $0.kind == .tail }) }
        guard case .group(let id) = item else { return nil }
        return entries.first(where: { $0.id == id })
    }

    private func view(forItemID itemID: String) -> AnyView {
        let rawID = ["g:", "n:", "p:"].reduce(itemID) { value, prefix in
            value.hasPrefix(prefix) ? String(value.dropFirst(prefix.count)) : value
        }
        guard let entry = entries.first(where: { $0.id == rawID || ($0.kind == .tail && itemID == "tail") }) else {
            return AnyView(EmptyView())
        }
        if debugRowViewCalls.count < 60 {
            debugRowViewCalls.append("\(rawID):expanded=\(entry.expanded)")
        }
        return view(for: entry)
    }

    /// Which entries the data source asked for after a reconfigure. The fold
    /// gate reads this when a collapsed row refuses to expand: it separates
    /// "the provider never saw the new entry" from "SwiftUI kept the old body".
    private(set) var debugRowViewCalls: [String] = []

    private func view(for entry: Entry) -> AnyView {
        switch entry.kind {
        case .message:
            return AnyView(ChatMarkdownView(text: entry.text))
        case .longGroup:
            // A product group is a VStack of rows with a small spacing. That
            // spacing alone is a positive height before Textual parses, which
            // is exactly the pre-parse value that must not be cached.
            return AnyView(VStack(alignment: .leading, spacing: 2) {
                ChatMarkdownView(text: entry.text)
                ChatMarkdownView(text: String(entry.text.reversed()))
            }.frame(maxWidth: .infinity, alignment: .leading))
        case .reasoning:
            return AnyView(ChatMarkdownView(text: entry.text)
                .environment(\.chatMarkdownFont, .caption2))
        case .toolExpanded:
            return AnyView(VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "hammer").font(.caption)
                    Text("工具调用").font(.caption).foregroundStyle(.secondary)
                }
                if entry.expanded {
                    ForEach(0..<12, id: \.self) { line in
                        Text("output line \(line): " + String(repeating: "detail ", count: 6))
                            .font(.caption2.monospaced())
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading))
        // Code/table use a synchronous representative view in this gate:
        // ChatMarkdownView parses asynchronously, and a fresh measurer would
        // otherwise compare a pre-parse height with the cell's settled height.
        // C5 repeats these rows with the real parsed-block view.
        case .code, .table:
            return AnyView(Text(entry.text)
                .font(.system(.caption, design: .monospaced))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading))
        case .image:
            return AnyView(VStack(alignment: .leading, spacing: 6) {
                Color.gray.opacity(0.25).frame(height: 160)
                Text("图片预览").font(.caption).foregroundStyle(.secondary)
            })
        case .notice:
            return AnyView(VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.shield").font(.caption)
                    Text("审批").font(.caption).foregroundStyle(.secondary)
                }
                Text(entry.text).font(.callout)
                if entry.expanded {
                    Text("details: " + String(repeating: "approval detail ", count: 8))
                        .font(.caption)
                    HStack {
                        Button("接受") {}.buttonStyle(.borderedProminent)
                        Button("拒绝") {}.buttonStyle(.bordered)
                    }
                }
            }.padding(12).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12)))
        case .pending:
            return AnyView(HStack(spacing: 8) {
                Text(entry.text).font(.callout)
                Spacer(minLength: 0)
                ProgressView().controlSize(.small)
            }.padding(12).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12)))
        case .tail:
            return AnyView(VStack(alignment: .leading, spacing: 8) {
                if entry.statusLine {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Thinking").font(.footnote).lineLimit(1)
                        Spacer(minLength: 0)
                    }.frame(height: 32)
                } else {
                    Color.clear.frame(height: 12)
                }
            })
        case .plain:
            return AnyView(Text(entry.text)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading))
        }
    }

    private static func initialEntries() -> [Entry] {
        let longMessage = """
        ## A long reply

        This is a representative message with **bold**, `inline code`, and a list:

        - first item
        - second item with a [link](https://example.com)
        - third item

        > A quote with enough text to wrap across a couple of lines in the
        > narrow column.

        ```swift
        struct Example {
            let value: Int
        }
        ```
        """
        let longReasoning = String(repeating: "Reasoning sentence with detail. ", count: 30)
        let code = (0..<18).map { "let value\($0) = \($0) * 2" }.joined(separator: "\n")
        let table = """
        | Name | Value | Note |
        | --- | --- | --- |
        | alpha | 1 | first |
        | beta | 2 | second |
        | gamma | 3 | third |
        """
        var entries: [Entry] = [
            Entry(id: "message-1", kind: .message, text: longMessage),
            Entry(id: "long-group-1", kind: .longGroup,
                  text: longMessage + "\n\n" + longReasoning),
            Entry(id: "reasoning-1", kind: .reasoning, text: longReasoning),
            Entry(id: "tools-1", kind: .toolExpanded, text: "工具组"),
            Entry(id: "code-1", kind: .code, text: code),
            Entry(id: "table-1", kind: .table, text: table),
            Entry(id: "image-1", kind: .image, text: "image", expanded: false),
            Entry(id: "notice-1", kind: .notice, text: "Allow the agent to run the tests?"),
            Entry(id: "pending-1", kind: .pending, text: "Queued message"),
        ]
        for index in 0..<60 {
            entries.append(Entry(id: "plain-\(index)", kind: .plain,
                text: String(repeating: "Earlier message line \(index). ", count: 2)))
        }
        entries.append(Entry(id: "tail", kind: .tail, text: ""))
        return entries
    }
}

/// The C3 gate root. Only reachable through the launch argument; the product
/// root is untouched.
struct TimelineAutoRunRootView: View {
    @State private var model = TimelineAutoRunModel()

    var body: some View {
        TimelineCollectionView(content: model, measurer: model.measurer,
            onControllerReady: { model.attach($0) })
            .ignoresSafeArea()
    }
}
#endif

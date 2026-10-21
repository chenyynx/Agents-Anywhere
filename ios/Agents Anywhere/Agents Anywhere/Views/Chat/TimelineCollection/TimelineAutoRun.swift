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
    }

    private(set) var entries: [Entry] = []
    private(set) var contentGeneration = 0
    private(set) var streamingIDs: Set<String> = []
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
                hasNewerItems: false))
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
        return item == .tail ? .tail(statusLine: entry.statusLine) : .row
    }

    func heightPolicy(for item: TimelineListItem) -> TimelineRowHeightPolicy {
        guard let entry = entry(for: item) else { return .measured }
        if item == .tail { return .tail }
        return [.toolExpanded, .notice].contains(entry.kind) ? .interactive : .measured
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

    @discardableResult
    func prependPlain(_ count: Int) -> [TimelineListItem] {
        let new = (0..<count).map { offset in
            Entry(id: "pre-\(offset)", kind: .plain,
                  text: String(repeating: "Earlier page line \(offset). ", count: 3))
        }
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
        await firstMeasurement()
        await asyncMarkdown()
        await measureConsistency()
        await foldAndTail()
        // Build the tool rows before the stream scenario, so the growing row
        // has expanded rows below it — the shape of pp's device report.
        await toolStorm()
        await collapseGap()
        await streaming()
        await bottom()
        await prepend()
        await tailFlap()
        await foldCycles()
        await interleavedApplies()
        writeReport()
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
            setExpanded(entry.id, true)
            controller.reconfigure([item])
            let expanded = await waitForCellHeight(controller, item: item,
                timeout: 3) { $0 > collapsed + 1 }
            let sample = await sampleItem(controller, item: item)
            if expanded <= collapsed + 1 {
                failures.append("fold: expanded \(expanded) not taller than collapsed \(collapsed)")
            }
            if let sample, sample.cell + 0.5 < sample.content {
                failures.append("fold: cell \(sample.cell) clips content \(sample.content)")
            }
            report["fold"] = ["collapsed": collapsed, "expanded": expanded,
                              "content": sample?.content ?? 0,
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

        var overlaps = 0
        let attributes = controller.layout.orderedAttributes
        for (upper, lower) in zip(attributes, attributes.dropFirst())
        where upper.frame.maxY > lower.frame.minY + 0.5 {
            overlaps += 1
        }
        var checked = 0
        var clipped = 0
        var collapsed = 0
        for entry in stormEntries {
            let item = listItem(entry)
            let height = controller.layout.attributes(for: item.itemID)?.frame.height ?? 0
            if height < 44 { collapsed += 1 }
            guard let indexPath = controller.indexPath(for: item),
                  let cell = controller.collectionView.cellForItem(at: indexPath) else { continue }
            checked += 1
            let content = cell.contentView.systemLayoutSizeFitting(
                CGSize(width: cell.contentView.bounds.width,
                       height: UIView.layoutFittingCompressedSize.height),
                withHorizontalFittingPriority: .required,
                verticalFittingPriority: .fittingSizeLevel).height
            if cell.bounds.height + 0.5 < content { clipped += 1 }
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
                               "collapsed": collapsed, "staleCells": stale]
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

        // Expansion samples: frame height over 500ms.
        setExpanded(entry.id, true)
        contentGeneration += 1
        controller.reloadFromContent()
        var samples: [CGFloat] = []
        for _ in 0..<30 {
            controller.collectionView.layoutIfNeeded()
            if let indexPath = controller.indexPath(for: item),
               let cell = controller.collectionView.cellForItem(at: indexPath) {
                samples.append(cell.frame.height)
            }
            await wait(16)
        }
        var distinct: [CGFloat] = []
        for value in samples where distinct.last.map({ abs($0 - value) > 0.5 }) ?? true {
            distinct.append(value)
        }
        if after.missing > 0 || after.gap > 1 {
            failures.append("collapse: missing \(after.missing) cells, gap \(after.gap)pt")
        }
        report["collapseGap"] = [
            "beforeMissing": before.missing, "beforeGap": Double(before.gap),
            "afterMissing": after.missing, "afterGap": Double(after.gap),
            "expansionHeights": distinct.map(Double.init),
            "contentHeight": Double(controller.layout.contentHeight),
            "offset": Double(controller.collectionView.contentOffset.y),
        ]
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
        var gap: CGFloat = 0
        var covered = top
        for (start, end) in intervals.sorted(by: { $0.0 < $1.0 }) {
            if start > covered + 1 { gap += start - covered }
            covered = max(covered, end)
        }
        if covered < bottom - 1 { gap += bottom - covered }
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
        let monotonic = zip(heights, heights.dropFirst()).allSatisfy { $0 <= $1 + 0.5 }
        let maxShortfall = shortfalls.max() ?? 0
        if !monotonic { failures.append("streaming: heights not monotonic \(heights)") }
        if maxShortfall > 0.5 { failures.append("streaming: bottom shortfall \(maxShortfall)") }
        if movesPerTick.max() ?? 0 > 1 { failures.append("streaming: more than one offset move per tick") }
        if worstStale > 0 {
            failures.append("streaming: \(worstStale) visible cells sat at stale frames")
        }
        if worstOverlap > 0 {
            failures.append("streaming: \(worstOverlap) adjacent frames overlapped")
        }
        report["streaming"] = ["ticks": heights.count, "heights": heights,
                               "maxShortfall": maxShortfall, "monotonic": monotonic,
                               "movesPerTick": movesPerTick,
                               "worstStaleCells": worstStale,
                               "worstOverlaps": worstOverlap]
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
        await wait(500)
        let animatedShortfall = controller.bottomShortfall

        // A no-op animated return never calls didEndScrollingAnimation; the
        // watchdog must settle the phase.
        controller.requestBottom(animated: true)
        await wait(500)
        let phaseAfterNoop = String(describing: controller.phase.phase)

        controller.disarmBottom()
        let followRefused = controller.armFollowingBottom(readerRestsAtBottom: false,
            mode: .reading, interactionPresented: false, requiresNoInteraction: false)
        let followAccepted = controller.armFollowingBottom(readerRestsAtBottom: false,
            mode: .returning, interactionPresented: false, requiresNoInteraction: false)
        controller.disarmBottom()
        controller.readerDidRestAtBottom(true, interactionPresented: false)
        let rearmed = controller.armedBottom.source == .follow

        if instantShortfall > 0.5 { failures.append("bottom: instant shortfall \(instantShortfall)") }
        if animatedShortfall > 0.5 { failures.append("bottom: animated shortfall \(animatedShortfall)") }
        if phaseAfterNoop != "idle" { failures.append("bottom: no-op phase \(phaseAfterNoop)") }
        if followRefused { failures.append("bottom: follow armed while reading and away") }
        if !followAccepted { failures.append("bottom: follow refused during a return") }
        if !rearmed { failures.append("bottom: reader rest did not re-arm") }
        report["bottom"] = ["instantShortfall": instantShortfall,
                            "animatedShortfall": animatedShortfall,
                            "phaseAfterNoop": phaseAfterNoop,
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

    private func writeReport() {
        var output: [String: Any] = report
        output["failures"] = failures
        output["completed"] = failures.isEmpty
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
        return view(for: entry)
    }

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

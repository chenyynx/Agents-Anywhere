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
        await streaming()
        await bottom()
        await prepend()
        writeReport()
    }

    private func measureConsistency() async {
        var samples: [[String: Any]] = []
        for kind in Kind.allCases {
            guard let entry = entries.first(where: { $0.kind == kind }) else { continue }
            let item = listItem(entry)
            await scrollToItem(item)
            // The visible cell is the measurement source for every kind now
            // that async Markdown is never pre-measured offscreen. Give the
            // async kinds time to parse, then read the same fitting source
            // the product uses.
            await wait([.message, .longGroup, .reasoning].contains(kind) ? 900 : 200)
            controller?.remeasure(item)
            await wait(150)
            // A correction can move the cell out of the visible set before the
            // sample; re-center it so the sample always reads a materialized
            // cell rather than a transient invalidation hole.
            await scrollToItem(item)
            guard let controller, let sample = cellSample(controller, item: item) else {
                failures.append("measurement: no cell for \(kind.rawValue)")
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
                            "content": sample.content, "cell": sample.cell, "error": error])
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
        await wait(1200)
        controller.remeasure(item)
        await wait(250)
        if let sample = cellSample(controller, item: item) {
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
            await wait(700)
            let expanded = cellHeight(controller, item)
            let sample = cellSample(controller, item: item)
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
            await wait(500)
            let expanded = cellHeight(controller, item)
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
            await wait(500)
            let active = cellHeight(controller, item)
            if abs(resting - 12) > 1 { failures.append("tail: resting height \(resting) != 12") }
            if abs(active - 32) > 1 { failures.append("tail: status height \(active) != 32") }
            report["tail"] = ["resting": resting, "statusLine": active]
        }
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
        }
        let monotonic = zip(heights, heights.dropFirst()).allSatisfy { $0 <= $1 + 0.5 }
        let maxShortfall = shortfalls.max() ?? 0
        if !monotonic { failures.append("streaming: heights not monotonic \(heights)") }
        if maxShortfall > 0.5 { failures.append("streaming: bottom shortfall \(maxShortfall)") }
        if movesPerTick.max() ?? 0 > 1 { failures.append("streaming: more than one offset move per tick") }
        report["streaming"] = ["ticks": heights.count, "heights": heights,
                               "maxShortfall": maxShortfall, "monotonic": monotonic,
                               "movesPerTick": movesPerTick]
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
        let measured = controller.layout.heights.tieredHeight(for: key)
            ?? controller.layout.attributes(for: item.itemID)?.frame.height ?? 0
        return CellSample(cell: cell.bounds.height, content: content, measured: measured)
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

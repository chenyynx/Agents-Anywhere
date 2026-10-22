#if AA_TIMELINE_PROBE
import Combine
import SwiftUI
import UIKit

/// On-device diagnostics for the collection timeline.
///
/// This file is compiled only into probe builds (`-DAA_TIMELINE_PROBE`); the
/// shipping app never carries the display link, the sampling pass, or the
/// overlay. The probe answers three device questions the simulator gates
/// cannot:
///
/// 1. **Which row moved?** Every height change is recorded with its source,
///    the scroll state at that instant, and whether the row was on screen.
///    A correction that lands while the reader is looking at the row is what
///    reads as "the tool rows move while I scroll".
/// 2. **Is the cell still where the layout says?** Each sample compares every
///    visible cell's frame with the layout attributes. A mismatch is the
///    stale-frame family (content drawn at the previous position → overlap).
/// 3. **How far is the estimate from the rendered row?** A visible cell's
///    fitting height is compared with its frame once a second. A large
///    positive delta means the row will grow later (a gap); a large negative
///    one means it will shrink and pull the rows below it up.
///
/// The report is plain text; `复制报告` puts it on the pasteboard and also
/// writes `Documents/timeline-probe.txt` inside the app container.
@MainActor
final class TimelineProbeStore: NSObject, ObservableObject {
    static let shared = TimelineProbeStore()

    struct HeightChange {
        let at: TimeInterval
        let itemID: String
        let itemDescription: String
        let old: CGFloat
        let new: CGFloat
        let source: String
        let estimate: CGFloat
        let tracking: Bool
        let decelerating: Bool
        let offset: CGFloat
        let visible: Bool
        var repeatCount: Int
    }

    struct Issue {
        let at: TimeInterval
        let kind: String
        let detail: String
        var count: Int
        var lastAt: TimeInterval
    }

    struct ApplyRecord {
        let at: TimeInterval
        let itemCount: Int
        let changedCount: Int
        let animating: Bool
        let contentHeight: CGFloat
        let offset: CGFloat
        let visibleCount: Int
        let estimateRows: Int
    }

    @Published private(set) var revision = 0
    private(set) var counters: [String: Int] = [:]
    private(set) var changes: [HeightChange] = []
    private(set) var issues: [Issue] = []
    private(set) var applies: [ApplyRecord] = []

    private weak var controller: TimelineCollectionController?
    private weak var adapter: TimelineChatContentAdapter?
    private var link: CADisplayLink?
    private var runStartedAt = CACurrentMediaTime()
    private var lastSampleAt: TimeInterval = 0
    private var lastFitCheckAt: TimeInterval = 0
    private var lastHeights: [String: CGFloat] = [:]
    private var lastOffset: CGFloat?
    /// The controller records a fit before handing it to the layout, and the
    /// layout records the applied height again. Keep one line for the pair.
    private var lastRecorded: [String: (at: TimeInterval, new: CGFloat)] = [:]

    private static let maxChanges = 160
    private static let maxIssues = 100
    private static let maxApplies = 24

    // MARK: - Lifecycle

    func attach(controller: TimelineCollectionController?,
                adapter: TimelineChatContentAdapter?) {
        guard let controller else { return }
        if self.controller === controller {
            self.adapter = adapter
            return
        }
        self.controller = controller
        self.adapter = adapter
        if link == nil {
            runStartedAt = CACurrentMediaTime()
            lastHeights.removeAll()
            let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
            link.add(to: .main, forMode: .common)
            self.link = link
        }
    }

    func detach() {
        link?.invalidate()
        link = nil
        controller = nil
        adapter = nil
        lastHeights.removeAll()
        lastRecorded.removeAll()
        lastOffset = nil
    }

    func reset() {
        counters.removeAll()
        changes.removeAll()
        issues.removeAll()
        applies.removeAll()
        lastHeights.removeAll()
        lastRecorded.removeAll()
        lastOffset = nil
        runStartedAt = CACurrentMediaTime()
        revision &+= 1
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        guard now - lastSampleAt >= 0.1 else { return }
        lastSampleAt = now
        sample(now: now)
    }

    /// A scroll callback is the finest-grained moment the layout can be read;
    /// the display link alone (10 Hz) would miss corrections that land between
    /// two ticks.
    func scrollTick() {
        let now = CACurrentMediaTime()
        guard now - lastSampleAt >= 0.04 else { return }
        lastSampleAt = now
        sample(now: now)
    }

    // MARK: - Recording

    func noteApply(items: [TimelineListItem], changedCount: Int, animating: Bool,
                   contentHeight: CGFloat, pendingMeasurements: Int) {
        guard let controller, let view = controller.collectionView else { return }
        counters["applies", default: 0] += 1
        let record = ApplyRecord(at: CACurrentMediaTime(), itemCount: items.count,
                                 changedCount: changedCount, animating: animating,
                                 contentHeight: contentHeight,
                                 offset: view.contentOffset.y,
                                 visibleCount: view.indexPathsForVisibleItems.count,
                                 estimateRows: pendingMeasurements)
        applies.append(record)
        if applies.count > Self.maxApplies { applies.removeFirst(applies.count - Self.maxApplies) }
        revision &+= 1
    }

    func noteHeightChange(itemID: String, item: TimelineListItem?,
                          old: CGFloat, new: CGFloat, source: String) {
        lastHeights[itemID] = new
        guard abs(new - old) > 0.5 else { return }
        let now = CACurrentMediaTime()
        if let last = lastRecorded[itemID], now - last.at < 0.15,
           abs(last.new - new) < 0.5 {
            return
        }
        lastRecorded[itemID] = (now, new)
        counters["heightChanges", default: 0] += 1
        guard let controller, let view = controller.collectionView else {
            appendChange(HeightChange(at: CACurrentMediaTime(), itemID: itemID,
                                      itemDescription: describe(item), old: old, new: new,
                                      source: source, estimate: estimate(of: item),
                                      tracking: false, decelerating: false, offset: 0,
                                      visible: false, repeatCount: 1))
            return
        }
        if view.isTracking { counters["changesTracking", default: 0] += 1 }
        if view.isDecelerating { counters["changesDecelerating", default: 0] += 1 }
        let attributes = controller.layout.attributes(for: itemID)
        let visible = attributes.map { view.indexPathsForVisibleItems.contains($0.indexPath) } ?? false
        let change = HeightChange(at: CACurrentMediaTime(), itemID: itemID,
                                  itemDescription: describe(item), old: old, new: new,
                                  source: source, estimate: estimate(of: item),
                                  tracking: view.isTracking, decelerating: view.isDecelerating,
                                  offset: view.contentOffset.y, visible: visible,
                                  repeatCount: 1)
        appendChange(change)
    }

    private func appendChange(_ change: HeightChange) {
        // A row-height animation produces a value per display frame. Keep one
        // record per gesture: same item within 0.45 s updates the record's
        // target instead of flooding the buffer.
        if let last = changes.last,
           last.itemID == change.itemID,
           change.at - last.at <= 0.45,
           last.source == change.source || change.source == "animating" {
            changes[changes.count - 1] = HeightChange(
                at: change.at, itemID: last.itemID,
                itemDescription: last.itemDescription,
                old: last.old, new: change.new, source: last.source,
                estimate: last.estimate, tracking: change.tracking,
                decelerating: change.decelerating, offset: change.offset,
                visible: change.visible, repeatCount: last.repeatCount + 1)
        } else {
            changes.append(change)
            if changes.count > Self.maxChanges {
                changes.removeFirst(changes.count - Self.maxChanges)
            }
        }
        revision &+= 1
    }

    private func recordIssue(kind: String, detail: String) {
        let now = CACurrentMediaTime()
        let key = "\(kind)|\(detail)"
        if let index = issues.lastIndex(where: { $0.kind == kind && $0.detail == detail
            && now - $0.lastAt <= 2.0 }) {
            issues[index].count += 1
            issues[index].lastAt = now
        } else {
            // Coalesce by item when the detail carries a changing value.
            if let index = issues.lastIndex(where: { $0.kind == kind
                && now - $0.lastAt <= 1.0 && sameItem($0.detail, detail) }) {
                issues[index].count += 1
                issues[index].lastAt = now
                issues[index] = Issue(at: issues[index].at, kind: kind, detail: detail,
                                      count: issues[index].count, lastAt: now)
            } else {
                issues.append(Issue(at: now, kind: kind, detail: detail,
                                    count: 1, lastAt: now))
                if issues.count > Self.maxIssues {
                    issues.removeFirst(issues.count - Self.maxIssues)
                }
            }
        }
        counters["issues", default: 0] += 1
        revision &+= 1
    }

    private func sameItem(_ a: String, _ b: String) -> Bool {
        let left = a.split(separator: " ").first.map(String.init) ?? a
        let right = b.split(separator: " ").first.map(String.init) ?? b
        return !left.isEmpty && left == right
    }

    // MARK: - Sampling

    private func sample(now: TimeInterval) {
        guard let controller, let view = controller.collectionView else { return }
        counters["samples", default: 0] += 1
        if view.isTracking { counters["samplesTracking", default: 0] += 1 }
        if view.isDecelerating { counters["samplesDecelerating", default: 0] += 1 }

        // A programmatic offset change with no gesture is the other way rows
        // appear to move on their own (bottom pin, history return).
        let offset = view.contentOffset.y
        if let lastOffset, !view.isTracking, !view.isDecelerating {
            let delta = offset - lastOffset
            if abs(delta) > 2 {
                counters["offsetJumps", default: 0] += 1
                recordIssue(kind: "offsetJump",
                            detail: "delta=\(f(delta)) \(f(lastOffset))->\(f(offset)) "
                                + "contentH=\(f(controller.layout.contentHeight))")
            }
        }
        lastOffset = offset

        let visiblePaths = Set(view.indexPathsForVisibleItems)
        let attributes = controller.layout.orderedAttributes
        var visibleAttributes: [TimelineListLayoutAttributes] = []
        visibleAttributes.reserveCapacity(visiblePaths.count)

        for attribute in attributes {
            guard let item = attribute.item else { continue }
            let id = item.itemID
            let height = attribute.frame.height
            if let old = lastHeights[id], abs(old - height) > 0.5 {
                // Only reached when a path recorded a height without going
                // through one of the explicit hooks (typically `prepare`
                // resolving a new key).
                noteHeightChange(itemID: id, item: item, old: old, new: height,
                                 source: "layout")
            }
            lastHeights[id] = height
            if visiblePaths.contains(attribute.indexPath) {
                visibleAttributes.append(attribute)
            }
        }

        var staleCount = 0
        var maxDelta: CGFloat = 0
        for attribute in visibleAttributes {
            guard let item = attribute.item,
                  let cell = view.cellForItem(at: attribute.indexPath) else { continue }
            let dy = abs(cell.frame.minY - attribute.frame.minY)
            let dh = abs(cell.frame.height - attribute.frame.height)
            if dy > 0.5 || dh > 0.5 {
                staleCount += 1
                maxDelta = max(maxDelta, max(dy, dh))
                recordIssue(kind: "staleCell",
                            detail: "\(item.itemID) cell=(y \(f(cell.frame.minY)) h \(f(cell.frame.height))) "
                                + "attr=(y \(f(attribute.frame.minY)) h \(f(attribute.frame.height))) "
                                + "dy=\(f(dy)) dh=\(f(dh)) off=\(f(view.contentOffset.y))")
            }
        }
        if staleCount > 0 { counters["staleSamples", default: 0] += 1 }
        counters["maxStaleDelta", default: 0] = max(counters["maxStaleDelta"] ?? 0,
                                                    Int(maxDelta.rounded()))

        // The layout's own frames: an overlap here is a model bug, unlike a
        // cell left at a previous frame (checked above).
        var previous: TimelineListLayoutAttributes?
        for attribute in visibleAttributes {
            if let upper = previous,
               upper.frame.maxY > attribute.frame.minY + 0.5 {
                counters["modelOverlaps", default: 0] += 1
                recordIssue(kind: "modelOverlap",
                            detail: "\(upper.item?.itemID ?? "?")/\(attribute.item?.itemID ?? "?") "
                                + "by \(f(upper.frame.maxY - attribute.frame.minY))")
            }
            previous = attribute
        }

        // UIKit-level overlap: two visible cells covering the same band.
        var cells: [(String, CGRect)] = []
        for attribute in visibleAttributes {
            guard let item = attribute.item,
                  let cell = view.cellForItem(at: attribute.indexPath) else { continue }
            cells.append((item.itemID, cell.frame))
        }
        cells.sort { $0.1.minY < $1.1.minY }
        if cells.count > 1 {
            for index in 1..<cells.count {
                let upper = cells[index - 1]
                let lower = cells[index]
                let overlap = upper.1.maxY - lower.1.minY
                if overlap > 0.5 {
                    counters["cellOverlaps", default: 0] += 1
                    recordIssue(kind: "cellOverlap",
                                detail: "\(upper.0)/\(lower.0) by \(f(overlap)) "
                                    + "upperH=\(f(upper.1.height)) lowerY=\(f(lower.1.minY)) "
                                    + "off=\(f(view.contentOffset.y))")
                }
            }
        }

        // A fitting pass is a SwiftUI layout pass. Run it only when the reader
        // is not scrolling: measuring during a scroll would change the very
        // behaviour this probe is observing.
        if now - lastFitCheckAt >= 1.0, !view.isTracking, !view.isDecelerating {
            lastFitCheckAt = now
            checkFits(controller: controller, view: view, attributes: visibleAttributes)
        }

        if !visibleAttributes.isEmpty {
            counters["visibleRows", default: 0] = visibleAttributes.count
        }
    }

    /// The visible cell is the only exact source for a hosting row. Comparing
    /// its fitting height with the frame predicts the next correction: the
    /// row is currently at the wrong height and will move when the settle
    /// pass runs.
    private func checkFits(controller: TimelineCollectionController,
                           view: UICollectionView,
                           attributes: [TimelineListLayoutAttributes]) {
        for attribute in attributes {
            guard let item = attribute.item,
                  controller.documentHeights[item.itemID] == nil,
                  let cell = view.cellForItem(at: attribute.indexPath) else { continue }
            // A reconfigure swaps the hosted SwiftUI tree. Two hosting views
            // inside one cell at the same time draw over each other; that is
            // the in-cell "text overlap" a frame comparison cannot see.
            let hosting = cell.contentView.subviews.filter {
                String(describing: type(of: $0)).contains("HostingView")
            }
            if hosting.count > 1 {
                counters["doubleHosting", default: 0] += 1
                recordIssue(kind: "doubleHosting",
                            detail: "\(item.itemID) n=\(hosting.count) "
                                + hosting.map { "(\(f($0.frame.minY)),\(f($0.frame.height)))" }
                                    .joined(separator: " "))
            }
            if let tallest = hosting.map(\.frame.height).max(),
               tallest > cell.bounds.height + 0.5 {
                counters["hostingOverflow", default: 0] += 1
                recordIssue(kind: "hostingOverflow",
                            detail: "\(item.itemID) hostingH=\(f(tallest)) "
                                + "cellH=\(f(cell.bounds.height)) "
                                + "attrH=\(f(attribute.frame.height))")
            }
            let width = cell.contentView.bounds.width
            guard width > 0 else { continue }
            let raw = cell.contentView.systemLayoutSizeFitting(
                CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
                withHorizontalFittingPriority: .required,
                verticalFittingPriority: .fittingSizeLevel).height
            guard raw.isFinite, raw > 8 else { continue }
            counters["fitChecks", default: 0] += 1
            let fit = ceil(raw)
            let delta = fit - attribute.frame.height
            guard abs(delta) > 1 else { continue }
            counters["fitMismatch", default: 0] += 1
            recordIssue(kind: "fitMismatch",
                        detail: "\(item.itemID) frameH=\(f(attribute.frame.height)) fit=\(f(fit)) "
                            + "delta=\(f(delta)) est=\(f(estimate(of: item))) "
                            + "policy=\(attribute.policy) visible=1 off=\(f(view.contentOffset.y)) "
                            + "\(describe(item))")
        }
    }

    // MARK: - Lookups

    private func estimate(of item: TimelineListItem?) -> CGFloat {
        guard let item, let controller, let content = controller.content else { return 0 }
        return content.estimateKind(for: item).height
    }

    private func describe(_ item: TimelineListItem?) -> String {
        guard let item else { return "?" }
        return adapter?.probeDescribe(item) ?? item.itemID
    }

    private func f(_ value: CGFloat) -> String { String(format: "%.1f", value) }

    private func elapsed(_ at: TimeInterval) -> String {
        String(format: "%.2f", max(0, at - runStartedAt))
    }

    // MARK: - Report

    func report() -> String {
        var lines: [String] = []
        let bundle = Bundle.main.infoDictionary
        let version = bundle?["CFBundleShortVersionString"] as? String ?? "?"
        let build = bundle?["CFBundleVersion"] as? String ?? "?"
        let device = UIDevice.current
        let screen = controller?.view.window?.screen.bounds ?? UIScreen.main.bounds
        let scale = controller?.view.window?.screen.scale ?? UIScreen.main.scale
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        lines.append("AA TIMELINE PROBE \(formatter.string(from: Date())) CST")
        lines.append("app \(version)(\(build)) · \(device.model) · iOS \(device.systemVersion) · "
            + "\(Int(screen.width))x\(Int(screen.height))@\(Int(scale))x")
        lines.append("legend: V=visible row B=estimate breakdown C=height change "
            + "A=apply I=issue; flags T=tracking D=decelerating; t=seconds since clear")

        if let controller, let view = controller.collectionView {
            let contentHeight = controller.layout.contentHeight
            lines.append("view offset=\(f(view.contentOffset.y)) contentH=\(f(contentHeight)) "
                + "boundsH=\(f(view.bounds.height)) insetTop=\(f(view.adjustedContentInset.top)) "
                + "insetBottom=\(f(view.adjustedContentInset.bottom))")
            lines.append("items=\(controller.layout.orderedAttributes.count) "
                + "visible=\(view.indexPathsForVisibleItems.count) "
                + "tracking=\(view.isTracking ? 1 : 0) decelerating=\(view.isDecelerating ? 1 : 0)")
        } else {
            lines.append("view: not attached")
        }

        let counterLine = counters.keys.sorted().map { "\($0)=\(counters[$0]!)" }.joined(separator: " ")
        lines.append("counters: \(counterLine.isEmpty ? "-" : counterLine)")

        if let controller, let view = controller.collectionView {
            lines.append("--- VISIBLE (top to bottom) ---")
            let visiblePaths = Set(view.indexPathsForVisibleItems)
            for attribute in controller.layout.orderedAttributes
            where visiblePaths.contains(attribute.indexPath) {
                guard let item = attribute.item else { continue }
                let cell = view.cellForItem(at: attribute.indexPath)
                let cellY = cell.map { f($0.frame.minY) } ?? "-"
                let cellH = cell.map { f($0.frame.height) } ?? "-"
                let key = attribute.heightKey
                let tier = key.map {
                    controller.layout.heights.hasMeasuredOrPrecalcHeight(for: $0)
                        ? "measured" : "estimate"
                } ?? "?"
                let revision = key.map { "\($0.contentRevision)" } ?? "?"
                lines.append("V \(item.itemID) y=\(f(attribute.frame.minY)) h=\(f(attribute.frame.height)) "
                    + "cell=(\(cellY),\(cellH)) est=\(f(estimate(of: item))) tier=\(tier) rev=\(revision) "
                    + "policy=\(attribute.policy) \(describe(item))")
                if let breakdown = adapter?.probeBreakdown(item) {
                    lines.append("  B \(breakdown)")
                }
            }
        }

        lines.append("--- HEIGHT CHANGES (newest first) ---")
        for change in changes.suffix(90).reversed() {
            let flags = "\(change.tracking ? "T" : "-")\(change.decelerating ? "D" : "-")"
            lines.append("C t=\(elapsed(change.at)) src=\(change.source) \(change.itemID) "
                + "\(f(change.old))->\(f(change.new)) d=\(f(change.new - change.old)) "
                + "est=\(f(change.estimate)) flags=\(flags) off=\(f(change.offset)) "
                + "vis=\(change.visible ? 1 : 0) n=\(change.repeatCount) \(change.itemDescription)")
        }

        lines.append("--- APPLIES (newest first) ---")
        for apply in applies.suffix(14).reversed() {
            lines.append("A t=\(elapsed(apply.at)) items=\(apply.itemCount) changed=\(apply.changedCount) "
                + "anim=\(apply.animating ? 1 : 0) contentH=\(f(apply.contentHeight)) "
                + "off=\(f(apply.offset)) visible=\(apply.visibleCount) estimates=\(apply.estimateRows)")
        }

        lines.append("--- ISSUES (newest last) ---")
        for issue in issues.suffix(60) {
            lines.append("I t=\(elapsed(issue.at)) [\(issue.kind)] x\(issue.count) \(issue.detail)")
        }
        return lines.joined(separator: "\n")
    }

    func copyReport() {
        let text = report()
        UIPasteboard.general.string = text
        if let directory = FileManager.default.urls(for: .documentDirectory,
                                                    in: .userDomainMask).first {
            try? text.write(to: directory.appendingPathComponent("timeline-probe.txt"),
                            atomically: true, encoding: .utf8)
        }
    }
}

// MARK: - Overlay

@MainActor
struct TimelineProbeOverlay: View {
    let controller: TimelineCollectionController?
    let adapter: TimelineChatContentAdapter?
    let controllerReady: Bool

    @ObservedObject private var store = TimelineProbeStore.shared
    @State private var presenting = false

    var body: some View {
        Button {
            presenting = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "waveform.path.ecg")
                Text("探针")
                if !store.issues.isEmpty {
                    Text("\(store.issues.count)")
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(.orange))
                        .foregroundStyle(.white)
                }
            }
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.orange.opacity(0.55)))
        }
        .buttonStyle(.plain)
        .padding(.top, 6)
        .padding(.trailing, 10)
        .onChange(of: controllerReady, initial: true) { _, _ in
            store.attach(controller: controller, adapter: adapter)
        }
        .onChange(of: controller.map { ObjectIdentifier($0) }) { _, _ in
            store.attach(controller: controller, adapter: adapter)
        }
        .onDisappear { store.detach() }
        .sheet(isPresented: $presenting) { TimelineProbePanel() }
    }
}

@MainActor
private struct TimelineProbePanel: View {
    @ObservedObject private var store = TimelineProbeStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        NavigationStack {
            ScrollView([.vertical, .horizontal]) {
                Text(store.report())
                    .font(.system(size: 9.5, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .safeAreaInset(edge: .bottom) {
                Text("复现后点『复制报告』，把整段文本发回来。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(.bar)
            }
            .navigationTitle("时间线探针")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("清空") {
                        store.reset()
                        copied = false
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(copied ? "已复制" : "复制报告") {
                        store.copyReport()
                        copied = true
                    }
                }
                ToolbarItem(placement: .bottomBar) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

@MainActor
extension View {
    /// Probe builds mount the overlay from the page that owns the timeline.
    @ViewBuilder
    func timelineProbeOverlay(controller: TimelineCollectionController?,
                              adapter: TimelineChatContentAdapter?,
                              ready: Bool) -> some View {
        overlay(alignment: .topTrailing) {
            TimelineProbeOverlay(controller: controller, adapter: adapter,
                                 controllerReady: ready)
        }
    }
}
#else
import SwiftUI

@MainActor
extension View {
    /// Shipping builds carry no probe; the call site stays identical.
    @ViewBuilder
    func timelineProbeOverlay(controller: TimelineCollectionController?,
                              adapter: TimelineChatContentAdapter?,
                              ready: Bool) -> some View { self }
}
#endif

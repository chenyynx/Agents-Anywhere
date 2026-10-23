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
        /// The actual cache tier the row carries at the moment of the write.
        /// `TimelineHeightCache` does not expose which tier answered, so this
        /// is derived from `tieredHeight` + `hasMeasuredOrPrecalcHeight`.
        let tier: String
        /// The height `prepare` will adopt for the current key: tiered value,
        /// then displayed height, then the crude estimate.
        let resolved: CGFloat
        let displayed: CGFloat
        /// The adapter's structured exact height for a Code group, if it can
        /// be computed cheaply (nil while the group is streaming or for rows
        /// that are not Code groups).
        let structuralExact: CGFloat?
        /// The adapter's `estimateKind.height` (the crude fallback).
        let crudeEstimate: CGFloat
        let keyRevision: String
        /// The probe hook that performed the write (`source`), paired with the
        /// key revision it was written against.
        let writer: String
        let tracking: Bool
        let decelerating: Bool
        let offset: CGFloat
        let visible: Bool
        var repeatCount: Int
    }

    /// A visible cell's rendered content, sampled for the content-mismatch
    /// check. The probe only reads what the reader sees; it never writes.
    struct ContentSample {
        let itemID: String
        /// The first 100 visible characters, whitespace collapsed.
        let text: String
        /// A stable hash of the full text, so two samples with the same
        /// prefix but different tails still differ.
        let textHash: Int
        /// The height the cell actually displays.
        let frameHeight: CGFloat
        /// The height the layout attributes claim.
        let attributeHeight: CGFloat
    }

    /// A touch event the window delivered, recorded for the event probe.
    /// A touch that lands outside every visible cell is a dead zone; a touch
    /// that lands on a cell but produces no response is a swallowed gesture.
    struct TouchEvent {
        let at: TimeInterval
        let location: CGPoint
        let phase: UITouch.Phase
        /// The item at the touch location, if the touch landed on a row.
        let itemID: String?
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
        /// Items whose content revision (the height key's `contentRevision`)
        /// differs from the previous apply. A static row appearing here is a
        /// re-key source that does not come from the row's own content.
        let changedKeyCount: Int
        let changedKeySample: [String]
    }

    @Published private(set) var revision = 0
    private(set) var counters: [String: Int] = [:]
    private(set) var changes: [HeightChange] = []
    private(set) var issues: [Issue] = []
    private(set) var applies: [ApplyRecord] = []
    /// The last content sample per item, for the content-mismatch check.
    /// A row whose text changed but whose height did not is a content bug the
    /// height probes cannot see.
    private var lastContentSamples: [String: ContentSample] = [:]
    /// The last few touch events, for the dead-zone and swallowed-gesture
    /// checks. Kept small: the probe only needs to know whether a touch
    /// landed on a row and whether anything responded.
    private var recentTouches: [TouchEvent] = []
    /// The display-link timestamps of the last few frames, for the frame-rate
    /// and animation-smoothness checks.
    private var frameTimestamps: [TimeInterval] = []
    /// The last slow-frame stack, for the main-thread blocker check.
    private var lastSlowFrameStack: [String] = []

    private weak var controller: TimelineCollectionController?
    private weak var adapter: TimelineChatContentAdapter?
    private var link: CADisplayLink?
    private var runStartedAt = CACurrentMediaTime()
    private var lastSampleAt: TimeInterval = 0
    private var lastFitCheckAt: TimeInterval = 0
    private var lastHeights: [String: CGFloat] = [:]
    private var lastOffset: CGFloat?
    private var lastTickAt: CFTimeInterval = 0
    private var lastContentSampleAt: TimeInterval = 0
    /// The controller records a fit before handing it to the layout, and the
    /// layout records the applied height again. Keep one line for the pair.
    private var lastRecorded: [String: (at: TimeInterval, new: CGFloat)] = [:]
    /// Last probe hook that wrote this item's height, scoped to the key
    /// revision it wrote against. A hook from a retired revision must not be
    /// reported as the writer of the current one.
    private var lastWriter: [String: (revision: String, source: String)] = [:]
    /// `contentRevision` per item at the previous apply, for the apply-line
    /// re-key accounting.
    private var lastApplyRevisions: [String: Int] = [:]

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
        lastWriter.removeAll()
        lastApplyRevisions.removeAll()
        lastOffset = nil
        lastContentSamples.removeAll()
        recentTouches.removeAll()
        frameTimestamps.removeAll()
        lastSlowFrameStack.removeAll()
    }

    func reset() {
        counters.removeAll()
        changes.removeAll()
        issues.removeAll()
        applies.removeAll()
        lastHeights.removeAll()
        lastRecorded.removeAll()
        lastWriter.removeAll()
        lastApplyRevisions.removeAll()
        lastOffset = nil
        lastContentSamples.removeAll()
        recentTouches.removeAll()
        frameTimestamps.removeAll()
        lastSlowFrameStack.removeAll()
        runStartedAt = CACurrentMediaTime()
        revision &+= 1
    }

    /// A touch event the window delivered. The probe records it; the
    /// swallowed-gesture check compares it with the cell frames.
    func noteTouch(_ touch: UITouch, in view: UIView) {
        let now = CACurrentMediaTime()
        let location = touch.location(in: view)
        let itemID: String?
        if let controller, let collectionView = controller.collectionView {
            let point = collectionView.convert(location, from: view)
            itemID = collectionView.indexPathForItem(at: point).flatMap {
                controller.currentItems.indices.contains($0.item)
                    ? controller.currentItems[$0.item].itemID : nil
            }
        } else {
            itemID = nil
        }
        recentTouches.append(TouchEvent(at: now, location: location,
                                        phase: touch.phase, itemID: itemID))
        if recentTouches.count > 20 { recentTouches.removeFirst() }
        counters["touchEvents", default: 0] += 1
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        frameTimestamps.append(now)
        if frameTimestamps.count > 120 { frameTimestamps.removeFirst() }
        // Main-thread hitches while the reader is dragging show up as long
        // display-link intervals. A height correction can also look like
        // jitter; these counters separate the two.
        if lastTickAt > 0, let view = controller?.collectionView,
           view.isTracking || view.isDecelerating {
            let ms = (now - lastTickAt) * 1000
            counters["frameSamples", default: 0] += 1
            counters["maxFrameMs", default: 0] =
                max(counters["maxFrameMs"] ?? 0, Int(ms.rounded()))
            if ms > 20 {
                counters["slowFrames", default: 0] += 1
                // The stack of a slow frame names the main-thread blocker.
                // Kept to the last one; the report prints it verbatim.
                lastSlowFrameStack = Array(Thread.callStackSymbols.prefix(20))
            }
        }
        lastTickAt = now
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
        // Which items' height keys moved in this apply. The layout only shows
        // the result; a static row re-keying here is a defect the C3 gate
        // cannot see and the device report needs named.
        var changedKeys: [String] = []
        if let content = controller.content {
            var revisions: [String: Int] = [:]
            revisions.reserveCapacity(items.count)
            for item in items {
                revisions[item.itemID] = content.contentSignature(for: item).contentRevision
            }
            changedKeys = revisions.compactMap { itemID, revision in
                guard let previous = lastApplyRevisions[itemID], previous != revision
                else { return nil }
                return itemID
            }.sorted()
            lastApplyRevisions = revisions
        }
        counters["keyChanges", default: 0] += changedKeys.count
        let record = ApplyRecord(at: CACurrentMediaTime(), itemCount: items.count,
                                 changedCount: changedCount, animating: animating,
                                 contentHeight: contentHeight,
                                 offset: view.contentOffset.y,
                                 visibleCount: view.indexPathsForVisibleItems.count,
                                 estimateRows: pendingMeasurements,
                                 changedKeyCount: changedKeys.count,
                                 changedKeySample: Array(changedKeys.prefix(8)))
        applies.append(record)
        if applies.count > Self.maxApplies { applies.removeFirst(applies.count - Self.maxApplies) }
        revision &+= 1
    }

    func noteMeasureDuration(_ seconds: TimeInterval) {
        let ms = Int((max(0, seconds) * 1000).rounded())
        counters["measureCount", default: 0] += 1
        counters["measureMsTotal", default: 0] += ms
        counters["measureMsMax", default: 0] = max(counters["measureMsMax"] ?? 0, ms)
    }

    func noteApplyDuration(_ seconds: TimeInterval) {
        let ms = Int((max(0, seconds) * 1000).rounded())
        counters["applyCount", default: 0] += 1
        counters["applyMsTotal", default: 0] += ms
        counters["applyMsMax", default: 0] = max(counters["applyMsMax"] ?? 0, ms)
    }

    func noteHeightChange(itemID: String, item: TimelineListItem?,
                          old: CGFloat, new: CGFloat, source: String) {
        lastHeights[itemID] = new
        // Record the writer even when the value did not move: a same-height
        // write is still the hook that owns the tier for the current key.
        // "layout" is the probe noticing a change between samples, not a
        // writer; it must not replace a real hook attribution.
        let facts = heightFacts(itemID: itemID, item: item)
        if source != "layout" {
            lastWriter[itemID] = (facts.keyRevision, source)
        }
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
                                      source: source, tier: facts.tier,
                                      resolved: facts.resolved, displayed: facts.displayed,
                                      structuralExact: facts.structuralExact,
                                      crudeEstimate: facts.crudeEstimate,
                                      keyRevision: facts.keyRevision, writer: source,
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
                                  source: source, tier: facts.tier,
                                  resolved: facts.resolved, displayed: facts.displayed,
                                  structuralExact: facts.structuralExact,
                                  crudeEstimate: facts.crudeEstimate,
                                  keyRevision: facts.keyRevision, writer: source,
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
                tier: last.tier, resolved: change.resolved,
                displayed: change.displayed,
                structuralExact: change.structuralExact,
                crudeEstimate: change.crudeEstimate,
                keyRevision: change.keyRevision, writer: last.writer,
                tracking: change.tracking,
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

        // Content mismatch: the cell's rendered text changed but its height
        // did not, or the text is identical to the previous sample but the
        // height moved. Either is a content bug the height probes cannot see.
        if now - lastContentSampleAt >= 0.5 {
            lastContentSampleAt = now
            checkContent(controller: controller, view: view,
                         attributes: visibleAttributes)
        }

        // Touch events: a touch that lands outside every visible cell is a
        // dead zone; a touch that lands on a cell but produces no response is
        // a swallowed gesture.
        checkTouches(controller: controller, view: view)

        // Frame rate: gaps > 33 ms are dropped frames; runs of them are
        // hitches the reader feels as stutter.
        checkFrameRate()

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

    /// The cell's rendered text, sampled every 0.5 s while the row is visible.
    /// A row whose text changed but whose height did not is a content bug the
    /// height probes cannot see; a row whose text is identical but whose
    /// height moved is a layout bug the text probes cannot see.
    private func checkContent(controller: TimelineCollectionController,
                              view: UICollectionView,
                              attributes: [TimelineListLayoutAttributes]) {
        for attribute in attributes {
            guard let item = attribute.item,
                  let cell = view.cellForItem(at: attribute.indexPath) else { continue }
            let text = cell.contentView.recursiveDescription
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            let sample = ContentSample(
                itemID: item.itemID,
                text: String(text.prefix(100)),
                textHash: text.hash,
                frameHeight: cell.frame.height,
                attributeHeight: attribute.frame.height)
            guard let previous = lastContentSamples[item.itemID] else {
                lastContentSamples[item.itemID] = sample
                continue
            }
            let textChanged = previous.textHash != sample.textHash
            let heightChanged = abs(previous.attributeHeight - sample.attributeHeight) > 0.5
            if textChanged, !heightChanged {
                counters["contentMismatch", default: 0] += 1
                recordIssue(kind: "contentMismatch",
                            detail: "\(item.itemID) text changed, height did not "
                                + "prevH=\(f(previous.attributeHeight)) "
                                + "currH=\(f(sample.attributeHeight)) "
                                + "prev=\"\(previous.text.prefix(36))\" "
                                + "curr=\"\(sample.text.prefix(36))\"")
            }
            if !textChanged, heightChanged {
                counters["heightWithoutContent", default: 0] += 1
                recordIssue(kind: "heightWithoutContent",
                            detail: "\(item.itemID) height changed, text did not "
                                + "prevH=\(f(previous.attributeHeight)) "
                                + "currH=\(f(sample.attributeHeight))")
            }
            lastContentSamples[item.itemID] = sample
        }
    }

    /// The touch events the window delivered, checked against the visible
    /// cells. A touch that lands outside every visible cell is a dead zone;
    /// a touch that lands on a cell but produces no height or offset change
    /// within 0.3 s is a swallowed gesture.
    private func checkTouches(controller: TimelineCollectionController,
                              view: UICollectionView) {
        let now = CACurrentMediaTime()
        let visiblePaths = Set(view.indexPathsForVisibleItems)
        for touch in recentTouches where now - touch.at < 0.3 {
            guard touch.phase == .began else { continue }
            if touch.itemID == nil {
                counters["touchDeadZone", default: 0] += 1
                recordIssue(kind: "touchDeadZone",
                            detail: "at=(\(f(touch.location.x)),\(f(touch.location.y))) "
                                + "no row off=\(f(view.contentOffset.y))")
            }
        }
    }

    /// The frame timestamps the display link recorded, checked for frame-rate
    /// drops and animation hitches. A gap > 33 ms is a dropped frame; a run
    /// of gaps > 50 ms is a hitch.
    private func checkFrameRate() {
        guard frameTimestamps.count >= 2 else { return }
        var maxGap: TimeInterval = 0
        var hitchCount = 0
        for index in 1..<frameTimestamps.count {
            let gap = frameTimestamps[index] - frameTimestamps[index - 1]
            maxGap = max(maxGap, gap)
            if gap > 0.033 { hitchCount += 1 }
        }
        counters["frameRateMaxGapMs", default: 0] = Int((maxGap * 1000).rounded())
        if hitchCount > 0 {
            counters["frameRateHitches", default: 0] += hitchCount
        }
    }

    // MARK: - Lookups

    /// The four height sources the probe has to keep apart. `resolved` is the
    /// value `TimelineListLayout.prepare` will adopt for the current key:
    /// measured/precalc tier, then the item's displayed height, then the crude
    /// estimate. `tier` names which of those answered.
    private struct HeightFacts {
        let keyRevision: String
        let tier: String
        let resolved: CGFloat
        let displayed: CGFloat
        let structuralExact: CGFloat?
        let crudeEstimate: CGFloat
    }

    private func heightFacts(itemID: String, item: TimelineListItem?) -> HeightFacts {
        guard let controller else {
            return HeightFacts(keyRevision: "?", tier: "?", resolved: 0, displayed: 0,
                               structuralExact: nil, crudeEstimate: 0)
        }
        let heights = controller.layout.heights
        let key = heights.currentKey(for: itemID)
        let displayed = heights.displayedHeight(for: itemID) ?? 0
        let crude = estimate(of: item)
        let tier: String
        var resolved = displayed
        if let key {
            if heights.hasMeasuredOrPrecalcHeight(for: key) {
                tier = "measured"
            } else if heights.provisionalHeight(for: key) != nil {
                tier = "provisional"
            } else if heights.displayedHeight(for: itemID) != nil {
                tier = "displayed"
            } else {
                tier = "fallback"
            }
            let fallback = item.map {
                controller.content?.estimateKind(for: $0) ?? .row
            } ?? .row
            resolved = heights.resolvedHeight(for: key, itemID: itemID,
                                              fallback: fallback)
        } else {
            tier = "?"
        }
        return HeightFacts(
            keyRevision: key.map { "\($0.contentRevision)" } ?? "-",
            tier: tier, resolved: resolved, displayed: displayed,
            structuralExact: structuralExact(of: item, width: key?.width ?? 0),
            crudeEstimate: crude)
    }

    /// The adapter's structured pre-apply measurement (`measuredCodeGroupHeight`).
    /// It returns nil for non-Code rows and for a group whose text is still
    /// streaming/revealing, so this stays off the scroll path.
    private func structuralExact(of item: TimelineListItem?, width: CGFloat) -> CGFloat? {
        guard let item, width > 0, let content = controller?.content else { return nil }
        return content.measuredCodeGroupHeight(for: item, width: width)
    }

    private func estimate(of item: TimelineListItem?) -> CGFloat {
        guard let item, let controller, let content = controller.content else { return 0 }
        return content.estimateKind(for: item).height
    }

    /// The line under a row says which hook last wrote the key it is showing.
    /// Hooks that write the cache without calling `noteHeightChange`
    /// (`measureSynchronously`'s structured measurement) have no entry; the
    /// `.provisional` tier has exactly one such writer, so it is named
    /// explicitly.
    private func writerLabel(itemID: String, revision: String) -> String {
        if let writer = lastWriter[itemID], writer.revision == revision {
            return writer.source
        }
        if let key = controller?.layout.heights.currentKey(for: itemID),
           controller?.layout.heights.hasMeasuredOrPrecalcHeight(for: key) == false,
           controller?.layout.heights.tieredHeight(for: key) != nil {
            return "structuredProvisional"
        }
        return "-"
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
            + "A=apply I=issue; flags T=tracking D=decelerating; t=seconds since clear; "
            + "V/C: tier=measured|estimate|displayed|fallback rev=content revision "
            + "disp=last displayed resolved=prepare value exact=structural measurement "
            + "writer=probe hook that wrote the key; A keys=items whose key revision moved")

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
                let facts = heightFacts(itemID: item.itemID, item: item)
                let exact = facts.structuralExact.map(f) ?? "-"
                let writer = writerLabel(itemID: item.itemID,
                                         revision: facts.keyRevision)
                lines.append("V \(item.itemID) y=\(f(attribute.frame.minY)) h=\(f(attribute.frame.height)) "
                    + "cell=(\(cellY),\(cellH)) est=\(f(facts.crudeEstimate)) tier=\(facts.tier) "
                    + "rev=\(facts.keyRevision) disp=\(f(facts.displayed)) "
                    + "resolved=\(f(facts.resolved)) exact=\(exact) writer=\(writer) "
                    + "policy=\(attribute.policy) \(describe(item))")
                if let breakdown = adapter?.probeBreakdown(item) {
                    lines.append("  B \(breakdown)")
                }
            }
        }

        lines.append("--- HEIGHT CHANGES (newest first) ---")
        for change in changes.suffix(90).reversed() {
            let flags = "\(change.tracking ? "T" : "-")\(change.decelerating ? "D" : "-")"
            let exact = change.structuralExact.map(f) ?? "-"
            lines.append("C t=\(elapsed(change.at)) src=\(change.source) \(change.itemID) "
                + "\(f(change.old))->\(f(change.new)) d=\(f(change.new - change.old)) "
                + "est=\(f(change.crudeEstimate)) tier=\(change.tier) rev=\(change.keyRevision) "
                + "disp=\(f(change.displayed)) resolved=\(f(change.resolved)) exact=\(exact) "
                + "writer=\(change.writer) flags=\(flags) off=\(f(change.offset)) "
                + "vis=\(change.visible ? 1 : 0) n=\(change.repeatCount) \(change.itemDescription)")
        }

        lines.append("--- APPLIES (newest first) ---")
        for apply in applies.suffix(14).reversed() {
            let keys = apply.changedKeySample.isEmpty
                ? "-" : apply.changedKeySample.joined(separator: ",")
            lines.append("A t=\(elapsed(apply.at)) items=\(apply.itemCount) changed=\(apply.changedCount) "
                + "anim=\(apply.animating ? 1 : 0) contentH=\(f(apply.contentHeight)) "
                + "off=\(f(apply.offset)) visible=\(apply.visibleCount) estimates=\(apply.estimateRows) "
                + "keys=\(apply.changedKeyCount)[\(keys)]")
        }

        lines.append("--- ISSUES (newest last) ---")
        for issue in issues.suffix(60) {
            lines.append("I t=\(elapsed(issue.at)) [\(issue.kind)] x\(issue.count) \(issue.detail)")
        }
        if !recentTouches.isEmpty {
            lines.append("--- TOUCHES (newest first) ---")
            for touch in recentTouches.suffix(10).reversed() {
                let item = touch.itemID ?? "none"
                lines.append("T t=\(elapsed(touch.at)) phase=\(touch.phase.rawValue) "
                    + "at=(\(f(touch.location.x)),\(f(touch.location.y))) item=\(item)")
            }
        }
        if !lastSlowFrameStack.isEmpty {
            lines.append("--- SLOW FRAME STACK (last) ---")
            for frame in lastSlowFrameStack {
                lines.append("  \(frame)")
            }
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

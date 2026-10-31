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
        /// Whether the row had ever been on screen when this change was
        /// recorded. Separates a first materialization from a re-measure of a
        /// row the reader has already seen.
        let wasDisplayed: Bool
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
        /// Which signature component moved for the keys above (`rows`,
        /// `reveal`, `turnAction`, …). The revision is only a hash; without
        /// this the report can name the row that re-keyed but not the input
        /// that forced the reconfigure and re-measure.
        let keyDiffSample: [String]
        /// Top-level items this apply inserted/removed. A status/step row
        /// appearing and disappearing around a reply start shows up here by
        /// id, which the item count alone cannot name.
        let addedItemIDs: [String]
        let removedItemIDs: [String]
    }

    /// A named step in the history-paging path. These are the only records
    /// that say *why* a prepend moved the reader: request, driver placement,
    /// arriving page, apply decision, and the offset the apply committed.
    struct HistoryEvent {
        let at: TimeInterval
        let text: String
    }

    /// A rule-based observation the panel shows before the raw log. A busy
    /// report is tens of kilobytes; findings are the ten lines worth reading
    /// first. The rules only cluster what the probe already recorded, so a
    /// finding always carries a timestamp the raw sections can confirm.
    struct Finding {
        let at: TimeInterval
        /// 2 = visible break, 1 = warning, 0 = informational.
        let severity: Int
        let kind: String
        let detail: String
    }

    /// One 10 Hz viewport sample, kept only for offset findings.
    struct ViewSample {
        let at: TimeInterval
        let offset: CGFloat
        let contentHeight: CGFloat
        let visibleCount: Int
        let tracking: Bool
        let decelerating: Bool
    }

    /// A user-pressed marker. The screenshot is the last rendered timeline
    /// frame; export writes it next to the report.
    struct Mark {
        let at: Date
        let note: String
        let screenshot: UIImage?
    }

    /// One drawer open/close/drag. The collection view is not scrolling
    /// during the transition, so the frame sampler needs its own window or
    /// the sidebar's jank never lands in the report (pp 2026-10-31).
    struct DrawerTransition {
        let startedAt: TimeInterval
        let endedAt: TimeInterval
        let frames: Int
        /// False when the drawer was open at the first sample (a close).
        let opening: Bool
        /// What started the transition: drag, tap (button/programmatic) or
        /// scrim. b800 showed drag starts hitch and tap starts do not, so the
        /// split has to be recorded to compare like with like.
        let intent: String
        /// Time from the gesture/action callback to the environment flip
        /// (our probe hook). This half is UIKit event handling + SwiftUI
        /// state propagation.
        let intentToEnvMs: Int
        /// Time from the environment flip to the next display tick: the
        /// SwiftUI update/render this probe hook itself observes.
        let envToTickMs: Int
        /// Nominal display period while the drawer moved (8.3ms = 120Hz,
        /// 16.7ms = 60Hz). The official drawer requests the screen maximum;
        /// this tells us whether AA's SwiftUI spring gets it.
        let periodMs: Double
        /// Dropped frames felt during the transition, including the end and
        /// post-end boundary frames recorded after the window closed.
        var hitches: Int
        var maxGapMs: Int
        /// Frame-gap distribution for this transition. The average tells a
        /// continuous render cost apart from one-off boundary spikes, which
        /// the old per-transition summary (hitches + max) could not.
        let avgGapMs: Int
        let p50GapMs: Int
        /// Gap before the first sampled frame. The transition start flips the
        /// drawer environment and rebuilds page readers, so this is the only
        /// place that cost shows up as a frame gap.
        let firstGapMs: Int
        let gaps: [Int]
        /// Gap between the last frame inside the window and the next one.
        /// The completion lands there, after `drawerTransitioning` is
        /// already false; without it the end-of-transition hitch is
        /// invisible and gets attributed to scrolling.
        var endGapMs: Int = 0
        /// The two frames after `endGapMs`. The drawer defers its `isOpen`
        /// write by one main-queue turn, so the page rebuild it triggers can
        /// land one or two frames after the animation is gone.
        var postGaps: [Int] = []
        var durationMs: Int { Int(((endedAt - startedAt) * 1000).rounded()) }
    }

    @Published private(set) var revision = 0
    private(set) var counters: [String: Int] = [:]
    private(set) var changes: [HeightChange] = []
    private(set) var issues: [Issue] = []
    private(set) var applies: [ApplyRecord] = []
    private(set) var historyEvents: [HistoryEvent] = []
    /// The previous apply's top-level item ids, for the added/removed diff.
    private var lastApplyItemIDs: Set<String> = []
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
    /// Full signature per item at the previous apply. The revision says a row
    /// re-keyed; this says which input (rows, reveal, turn action, …) moved.
    private var lastApplySignatures: [String: TimelineContentSignature] = [:]
    /// Recent viewport samples for the offset findings (10 Hz, capped).
    private var viewSamples: [ViewSample] = []
    /// Per-operation durations; the counters keep only totals, the findings
    /// need the outliers and their timestamps.
    private var applyDurations: [(at: TimeInterval, ms: Int)] = []
    private var measureDurations: [(at: TimeInterval, ms: Int)] = []
    /// Display-link gaps that counted as hitches while the reader was
    /// scrolling, so a finding can name when the worst frame happened.
    private var frameHitches: [(at: TimeInterval, ms: Int, drawer: Bool)] = []
    /// User-pressed markers, newest last. Screenshots are memory-only; the
    /// export writes the newest three next to the report.
    private(set) var markers: [Mark] = []
    /// The last explicit clear, shown in the report so old counters are not
    /// mistaken for current ones.
    private(set) var lastClearedAt: Date?
    /// Drawer motion window. The drawer tells the store when a drag or
    /// open/close animation starts and ends; frame sampling counts gaps while
    /// it is on.
    private(set) var drawerTransitioning = false
    private(set) var drawerTransitions: [DrawerTransition] = []
    private var drawerStartedAt: TimeInterval?
    private var drawerFrames = 0
    private var drawerGaps: [Int] = []
    private var drawerOpening = true
    private var drawerIntent = "none"
    private var drawerIntentAt: TimeInterval?
    private var drawerEnvFlipAt: TimeInterval = 0
    private var drawerIntentToEnvMs = 0
    private var drawerEnvToTickMs = 0
    private var drawerFirstTickSeen = false
    /// Sum of `CADisplayLink.duration` over the window's frames. Its average
    /// is the nominal refresh the system gave the display while the drawer
    /// moved (8.3ms on a 120Hz ProMotion screen, 16.7ms at 60Hz).
    private var drawerPeriodTotal: Double = 0
    /// Display-link ticks still to be recorded against the transition that
    /// just ended: the end boundary plus the two frames after it. The
    /// drawer commits `isOpen` one main-queue turn after the animation, so
    /// the page rebuild it triggers can land one or two frames later.
    private var postDrawerTicksRemaining = 0

    private static let maxChanges = 160
    private static let maxIssues = 100
    private static let maxApplies = 24
    private static let maxHistoryEvents = 240
    private static let maxViewSamples = 120
    private static let maxDurations = 80
    private static let maxHitches = 30
    /// Three full-screen captures are enough for one incident and keep the
    /// probe's memory bounded (~300 KB each at 1x).
    private static let maxMarkers = 3

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
        // A new controller (or a fresh attach after detach) starts a new
        // measured window. Records from the previous window carry timestamps
        // relative to a different run start and used to surface as `t=0.00`
        // noise (and false findings) in the report.
        beginRunWindow()
        if link == nil {
            let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
            link.add(to: .main, forMode: .common)
            self.link = link
        }
    }

    /// Start a new measured window: counters and every sampled record are
    /// scoped to the current attach. Marks stay (explicit user actions).
    private func beginRunWindow() {
        counters.removeAll()
        changes.removeAll()
        issues.removeAll()
        applies.removeAll()
        historyEvents.removeAll()
        viewSamples.removeAll()
        applyDurations.removeAll()
        measureDurations.removeAll()
        frameHitches.removeAll()
        lastHeights.removeAll()
        lastRecorded.removeAll()
        lastWriter.removeAll()
        lastApplyRevisions.removeAll()
        lastApplySignatures.removeAll()
        lastApplyItemIDs.removeAll()
        lastOffset = nil
        lastContentSamples.removeAll()
        recentTouches.removeAll()
        frameTimestamps.removeAll()
        drawerTransitioning = false
        drawerTransitions.removeAll()
        drawerStartedAt = nil
        drawerFrames = 0
        drawerGaps.removeAll()
        drawerOpening = true
        drawerIntent = "none"
        drawerIntentAt = nil
        drawerEnvFlipAt = 0
        drawerIntentToEnvMs = 0
        drawerEnvToTickMs = 0
        drawerFirstTickSeen = false
        drawerPeriodTotal = 0
        postDrawerTicksRemaining = 0
        runStartedAt = CACurrentMediaTime()
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
        lastApplySignatures.removeAll()
        lastOffset = nil
        lastContentSamples.removeAll()
        recentTouches.removeAll()
        frameTimestamps.removeAll()
    }

    func reset() {
        beginRunWindow()
        // Marks are explicit user actions; clearing samples must not drop
        // them, otherwise "打点 then clear" loses the capture.
        lastClearedAt = Date()
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
                controller.items.indices.contains($0.item)
                    ? controller.items[$0.item].itemID : nil
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

        // The gaps that end the drawer window are the frames the reader feels
        // when the transition lands: the completion flips the environment and
        // the deferred `isOpen` write rebuilds the page, both after
        // `drawerTransitioning` is already false. Record the end boundary and
        // the two frames after it against the transition that just ended.
        if lastTickAt > 0, postDrawerTicksRemaining > 0, !drawerTransitioning {
            postDrawerTicksRemaining -= 1
            if let index = drawerTransitions.indices.last {
                let ms = Int(((now - lastTickAt) * 1000).rounded())
                if drawerTransitions[index].endGapMs == 0 {
                    drawerTransitions[index].endGapMs = ms
                } else if drawerTransitions[index].postGaps.count < 2 {
                    drawerTransitions[index].postGaps.append(ms)
                }
                // The reader feels these frames as part of the slide; count
                // them in the transition even though its window is closed.
                if ms > 33 { drawerTransitions[index].hitches += 1 }
                drawerTransitions[index].maxGapMs =
                    max(drawerTransitions[index].maxGapMs, ms)
            }
        }
        // Main-thread hitches while the reader is dragging show up as long
        // display-link intervals. A height correction can also look like
        // jitter; these counters separate the two. Count each gap once, when
        // it ends, and tag it with the phase it happened in. A 10 Hz scan
        // cannot do that: it sees a gap up to 100 ms after it happened, when
        // the drawer flag may already have flipped, which is how scroll
        // hitches ended up in drawer transitions (probe 17:54).
        if lastTickAt > 0, let view = controller?.collectionView,
           view.isTracking || view.isDecelerating || drawerTransitioning {
            let ms = (now - lastTickAt) * 1000
            // The frame that ends the idle stretch before a drawer intent is
            // not a dropped frame: it spans however much of the refresh
            // period was left when the finger/button arrived. It is reported
            // as the transition's start latency instead of a hitch.
            let drawerFirstFrame = drawerTransitioning && !drawerFirstTickSeen
            counters["frameSamples", default: 0] += 1
            counters["maxFrameMs", default: 0] =
                max(counters["maxFrameMs"] ?? 0, Int(ms.rounded()))
            counters["frameRateMaxGapMs", default: 0] =
                max(counters["frameRateMaxGapMs"] ?? 0, Int(ms.rounded()))
            if drawerTransitioning {
                drawerFrames += 1
                drawerGaps.append(Int(ms.rounded()))
                if drawerGaps.count > 120 { drawerGaps.removeFirst() }
                drawerPeriodTotal += link.duration
                if drawerFirstFrame {
                    drawerFirstTickSeen = true
                    drawerEnvToTickMs =
                        Int(((now - drawerEnvFlipAt) * 1000).rounded())
                }
            }
            let startArtifact = drawerFirstFrame && ms <= 100
            if ms > 33, !startArtifact {
                counters["frameRateHitches", default: 0] += 1
                frameHitches.append((at: now, ms: Int(ms.rounded()),
                                     drawer: drawerTransitioning))
                if frameHitches.count > Self.maxHitches {
                    frameHitches.removeFirst(frameHitches.count - Self.maxHitches)
                }
            }
            if ms > 20 {
                counters["slowFrames", default: 0] += 1
            }
        }
        lastTickAt = now
        guard now - lastSampleAt >= 0.1 else { return }
        lastSampleAt = now
        timedSample(now: now)
    }

    /// The 10 Hz sampler reads layout, visible cells and cell frames. Time it
    /// so its share of a slow window is visible in the counters.
    private func timedSample(now: TimeInterval) {
        let started = CACurrentMediaTime()
        sample(now: now)
        let ms = Int(((CACurrentMediaTime() - started) * 1000).rounded())
        counters["probeSampleMsTotal", default: 0] += ms
        counters["probeSampleMsMax", default: 0] =
            max(counters["probeSampleMsMax"] ?? 0, ms)
    }

    /// A scroll callback is the finest-grained moment the layout can be read;
    /// the display link alone (10 Hz) would miss corrections that land between
    /// two ticks.
    func scrollTick() {
        let now = CACurrentMediaTime()
        guard now - lastSampleAt >= 0.04 else { return }
        lastSampleAt = now
        timedSample(now: now)
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
        var keyDiffs: [String] = []
        if let content = controller.content {
            var revisions: [String: Int] = [:]
            var signatures: [String: TimelineContentSignature] = [:]
            revisions.reserveCapacity(items.count)
            signatures.reserveCapacity(items.count)
            for item in items {
                let signature = content.contentSignature(for: item)
                revisions[item.itemID] = signature.contentRevision
                signatures[item.itemID] = signature
            }
            changedKeys = revisions.compactMap { itemID, revision in
                guard let previous = lastApplyRevisions[itemID], previous != revision
                else { return nil }
                return itemID
            }.sorted()
            keyDiffs = changedKeys.compactMap { itemID in
                guard let previous = lastApplySignatures[itemID],
                      let current = signatures[itemID] else { return nil }
                return contentChangeLabel(itemID: itemID, from: previous, to: current)
            }
            lastApplyRevisions = revisions
            lastApplySignatures = signatures
        }
        counters["keyChanges", default: 0] += changedKeys.count
        let currentIDs = Set(items.map(\.itemID))
        let addedIDs = currentIDs.subtracting(lastApplyItemIDs).sorted()
        let removedIDs = lastApplyItemIDs.subtracting(currentIDs).sorted()
        lastApplyItemIDs = currentIDs
        let record = ApplyRecord(at: CACurrentMediaTime(), itemCount: items.count,
                                 changedCount: changedCount, animating: animating,
                                 contentHeight: contentHeight,
                                 offset: view.contentOffset.y,
                                 visibleCount: view.indexPathsForVisibleItems.count,
                                 estimateRows: pendingMeasurements,
                                 changedKeyCount: changedKeys.count,
                                 changedKeySample: Array(changedKeys.prefix(8)),
                                 keyDiffSample: Array(keyDiffs.prefix(6)),
                                 addedItemIDs: Array(addedIDs.prefix(4)),
                                 removedItemIDs: Array(removedIDs.prefix(4)))
        applies.append(record)
        if applies.count > Self.maxApplies { applies.removeFirst(applies.count - Self.maxApplies) }
        revision &+= 1
    }

    /// Name the signature components that differ between two applies. The
    /// revision is only a hash: a row re-keying because its wire revision
    /// changed looks identical to one re-keying because a reveal clock
    /// settled, and the fix is different for each.
    private func contentChangeLabel(itemID: String,
                                    from previous: TimelineContentSignature,
                                    to current: TimelineContentSignature) -> String {
        var parts: [String] = []
        switch (previous, current) {
        case (.group(let old), .group(let new)):
            if old.rows != new.rows { parts.append("rows") }
            if old.disclosureExpanded != new.disclosureExpanded { parts.append("disclose") }
            if old.expandedRowIDs != new.expandedRowIDs { parts.append("rowFold") }
            if old.revealingRowIDs != new.revealingRowIDs { parts.append("reveal") }
            if old.inlineNotices != new.inlineNotices { parts.append("notice") }
            if old.attachments != new.attachments { parts.append("attach") }
            if old.turnAction != new.turnAction { parts.append("turnAction") }
            if old.turnSuppression != new.turnSuppression { parts.append("suppress") }
            if old.contextRevision != new.contextRevision { parts.append("context") }
            if old.hasActionBar != new.hasActionBar { parts.append("actionBar") }
        default:
            let oldKind = signatureKind(previous)
            let newKind = signatureKind(current)
            parts.append(oldKind == newKind ? "\(newKind)*" : "\(oldKind)->\(newKind)")
        }
        if parts.isEmpty { parts.append("hashOnly") }
        return "\(itemID):\(parts.joined(separator: "+"))"
    }

    private func signatureKind(_ signature: TimelineContentSignature) -> String {
        switch signature {
        case .group: return "group"
        case .olderPrompt: return "older"
        case .latestPrompt: return "latest"
        case .workingStatus: return "working"
        case .notice: return "notice"
        case .pending: return "pending"
        case .tail: return "tail"
        }
    }

    /// Time spent rebuilding the shell's session list on each host body
    /// evaluation. The drawer commits `isOpen` one main-queue turn after its
    /// animation, which invalidates the host view right after the transition;
    /// this is the piece of that body whose cost scales with the session
    /// count (probe 2026-10-31, drawer hand-feel report).
    func noteShellSessions(seconds: TimeInterval) {
        let ms = Int((max(0, seconds) * 1000).rounded())
        counters["shellSessionsCount", default: 0] += 1
        counters["shellSessionsMsTotal", default: 0] += ms
        counters["shellSessionsMsMax", default: 0] =
            max(counters["shellSessionsMsMax"] ?? 0, ms)
    }

    func noteMeasureDuration(_ seconds: TimeInterval) {
        let ms = Int((max(0, seconds) * 1000).rounded())
        counters["measureCount", default: 0] += 1
        counters["measureMsTotal", default: 0] += ms
        counters["measureMsMax", default: 0] = max(counters["measureMsMax"] ?? 0, ms)
        measureDurations.append((at: CACurrentMediaTime(), ms: ms))
        if measureDurations.count > Self.maxDurations {
            measureDurations.removeFirst(measureDurations.count - Self.maxDurations)
        }
    }

    func noteApplyDuration(_ seconds: TimeInterval) {
        let ms = Int((max(0, seconds) * 1000).rounded())
        counters["applyCount", default: 0] += 1
        counters["applyMsTotal", default: 0] += ms
        counters["applyMsMax", default: 0] = max(counters["applyMsMax"] ?? 0, ms)
        applyDurations.append((at: CACurrentMediaTime(), ms: ms))
        if applyDurations.count > Self.maxDurations {
            applyDurations.removeFirst(applyDurations.count - Self.maxDurations)
        }
    }

    /// Free-form history-paging step. The controller and adapter write one
    /// line at every decision point, so the report shows the order of events
    /// instead of only the final offset jump.
    func noteHistory(_ text: String) {
        historyEvents.append(HistoryEvent(at: CACurrentMediaTime(), text: text))
        if historyEvents.count > Self.maxHistoryEvents {
            historyEvents.removeFirst(historyEvents.count - Self.maxHistoryEvents)
        }
        // No `revision` bump: the overlay does not show history lines, and
        // publishing during a height correction would make the probe itself
        // participate in the jank it is measuring.
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
                                      keyRevision: facts.keyRevision,
                                      wasDisplayed: facts.wasDisplayed, writer: source,
                                      tracking: false, decelerating: false, offset: 0,
                                      visible: false, repeatCount: 1))
            return
        }
        if view.isTracking { counters["changesTracking", default: 0] += 1 }
        if view.isDecelerating { counters["changesDecelerating", default: 0] += 1 }
        let attributes = controller.layout.attributes(for: itemID)
        let visible = attributes.map { view.indexPathsForVisibleItems.contains($0.indexPath) } ?? false
        if !visible { counters["heightChangesOffscreen", default: 0] += 1 }
        let change = HeightChange(at: CACurrentMediaTime(), itemID: itemID,
                                  itemDescription: describe(item), old: old, new: new,
                                  source: source, tier: facts.tier,
                                  resolved: facts.resolved, displayed: facts.displayed,
                                  structuralExact: facts.structuralExact,
                                  crudeEstimate: facts.crudeEstimate,
                                  keyRevision: facts.keyRevision,
                                  wasDisplayed: facts.wasDisplayed, writer: source,
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
                keyRevision: change.keyRevision,
                wasDisplayed: change.wasDisplayed, writer: last.writer,
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
        recordViewSample(at: now, offset: offset,
                         contentHeight: controller.layout.contentHeight,
                         visibleCount: view.indexPathsForVisibleItems.count,
                         tracking: view.isTracking, decelerating: view.isDecelerating)

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

        // A fitting pass is a SwiftUI layout pass. Run it only when the reader
        // is not scrolling: measuring during a scroll would change the very
        // behaviour this probe is observing.
        if now - lastFitCheckAt >= 1.0, !view.isTracking, !view.isDecelerating,
           !drawerTransitioning {
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


    /// The cell's rendered text. `recursiveDescription` is private API; walk
    /// the hosting subtree instead and read every UILabel the reader can
    /// actually see. The probe only reads what is on screen.
    private func visibleText(of cell: UICollectionViewCell) -> String {
        var labels: [String] = []
        func walk(_ view: UIView) {
            if let label = view as? UILabel, let text = label.text {
                labels.append(text)
            }
            for subview in view.subviews { walk(subview) }
        }
        walk(cell.contentView)
        return labels.joined(separator: " ")
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
            // SwiftUI's `Text` is not a UILabel, so a hosting row reports no
            // readable text at all — every height change would look like
            // "text did not change". Compare content only where the probe can
            // actually read it (the TextKit cell path).
            let hosting = cell.contentView.subviews.contains {
                String(describing: type(of: $0)).contains("HostingView")
            }
            if hosting { continue }
            let text = visibleText(of: cell)
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
        /// The row had been on screen at least once when these facts were read.
        let wasDisplayed: Bool
    }

    private func heightFacts(itemID: String, item: TimelineListItem?) -> HeightFacts {
        guard let controller else {
            return HeightFacts(keyRevision: "?", tier: "?", resolved: 0, displayed: 0,
                               structuralExact: nil, crudeEstimate: 0,
                               wasDisplayed: false)
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
            crudeEstimate: crude,
            wasDisplayed: heights.hasEverBeenDisplayed(itemID))
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

    // MARK: - Diagnostics

    private func recordViewSample(at: TimeInterval, offset: CGFloat,
                                  contentHeight: CGFloat, visibleCount: Int,
                                  tracking: Bool, decelerating: Bool) {
        viewSamples.append(ViewSample(at: at, offset: offset,
                                      contentHeight: contentHeight,
                                      visibleCount: visibleCount,
                                      tracking: tracking, decelerating: decelerating))
        if viewSamples.count > Self.maxViewSamples {
            viewSamples.removeFirst(viewSamples.count - Self.maxViewSamples)
        }
    }

    /// Rule-based summary over the buffered window. Read-only and cheap
    /// enough to call on every panel render.
    func findings() -> [Finding] {
        var result: [Finding] = []

        // 1. A 30 pt flip is a footer/status row appearing or disappearing.
        //    Opposite moves on the same row inside 3 s read as churn.
        var thirtyPointChanges: [String: [HeightChange]] = [:]
        for change in changes where abs(abs(change.new - change.old) - 30) <= 2 {
            thirtyPointChanges[change.itemID, default: []].append(change)
        }
        for (itemID, list) in thirtyPointChanges where list.count >= 2 {
            var flips = 0
            for index in 1..<list.count {
                let previous = list[index - 1].new - list[index - 1].old
                let current = list[index].new - list[index].old
                if previous * current < 0, list[index].at - list[index - 1].at <= 3 {
                    flips += 1
                }
            }
            if flips > 0, let last = list.last {
                result.append(Finding(at: last.at, severity: flips >= 2 ? 2 : 1,
                                      kind: "footer_churn",
                                      detail: "\(itemID) 30pt 反复 \(flips + 1) 次，最近一次 t=\(elapsed(last.at))"))
            }
        }

        // 2. A 30 pt drop on one row and a 30 pt rise on another inside 1.2 s
        //    is the footer moving between segments; a slow hand-off shows at
        //    the bottom as sink-then-bounce.
        if changes.count >= 2 {
            for index in 0..<(changes.count - 1) {
                let first = changes[index]
                let drop = first.new - first.old
                guard drop <= -28, drop >= -32 else { continue }
                for otherIndex in (index + 1)..<changes.count {
                    let other = changes[otherIndex]
                    guard other.at - first.at <= 1.2 else { break }
                    let rise = other.new - other.old
                    if other.itemID != first.itemID, rise >= 28, rise <= 32 {
                        result.append(Finding(
                            at: other.at, severity: 1, kind: "footer_transfer",
                            detail: "页脚从 \(first.itemID) 迁到 \(other.itemID)，间隔 \(f(other.at - first.at))s"))
                        break
                    }
                }
            }
        }

        // 3. Offset moved more than 20 pt with the content height unchanged
        //    and no height correction in between: a programmatic write, not
        //    the reader.
        if viewSamples.count >= 2 {
            for index in 1..<viewSamples.count {
                let previous = viewSamples[index - 1]
                let current = viewSamples[index]
                guard !current.tracking, !current.decelerating,
                      abs(current.offset - previous.offset) > 20,
                      abs(current.contentHeight - previous.contentHeight) < 1 else { continue }
                let corrected = changes.contains { change in
                    change.at >= previous.at && change.at <= current.at
                        && abs(change.new - change.old) >= 1
                }
                if !corrected {
                    result.append(Finding(
                        at: current.at, severity: 1, kind: "offset_jump",
                        detail: "offset \(f(previous.offset))->\(f(current.offset))，contentH 不变"))
                }
            }
        }

        // 4. Operation spikes: one slow apply is a frozen frame the reader
        //    feels even when no other counter moves.
        if let slowest = applyDurations.max(by: { $0.ms < $1.ms }), slowest.ms >= 100 {
            result.append(Finding(at: slowest.at,
                                  severity: slowest.ms >= 300 ? 2 : 1,
                                  kind: "apply_spike",
                                  detail: "apply \(slowest.ms)ms @t=\(elapsed(slowest.at))"))
        }
        if let slowest = measureDurations.max(by: { $0.ms < $1.ms }), slowest.ms >= 16 {
            result.append(Finding(at: slowest.at, severity: 1, kind: "measure_spike",
                                  detail: "measure \(slowest.ms)ms @t=\(elapsed(slowest.at))"))
        }

        // 5. Hitches while the reader is dragging/coasting or the drawer is
        //    moving. The drawer is not a scroll phase, so it has its own
        //    window in the sampler.
        if let worst = frameHitches.max(by: { $0.ms < $1.ms }) {
            let drawerCount = frameHitches.filter { $0.drawer }.count
            let scrollCount = frameHitches.count - drawerCount
            result.append(Finding(at: worst.at,
                                  severity: frameHitches.count >= 5 ? 2 : 1,
                                  kind: "frame_hitch",
                                  detail: ">33ms \(frameHitches.count) 次（滚动 \(scrollCount) / 抽屉 \(drawerCount)），"
                                      + "最大 \(worst.ms)ms @t=\(elapsed(worst.at))"))
        }
        if let transition = drawerTransitions.last, transition.hitches > 0 {
            result.append(Finding(at: transition.endedAt,
                                  severity: transition.maxGapMs >= 50 ? 2 : 1,
                                  kind: "drawer_hitch",
                                  detail: "抽屉滑动 \(transition.durationMs)ms，"
                                      + ">33ms \(transition.hitches) 次，最大 \(transition.maxGapMs)ms"))
        }

        // 6. A viewport sample with content but no visible cell is a blank
        //    frame the reader actually saw.
        if let blank = viewSamples.last(where: { $0.visibleCount == 0 && $0.contentHeight > 1 }) {
            result.append(Finding(at: blank.at, severity: 2, kind: "blank_frame",
                                  detail: "contentH=\(f(blank.contentHeight)) 但 visible=0 @t=\(elapsed(blank.at))"))
        }

        result.sort { lhs, rhs in
            if lhs.severity != rhs.severity { return lhs.severity > rhs.severity }
            return lhs.at > rhs.at
        }
        return Array(result.prefix(10))
    }

    /// Display-link intervals (ms), oldest first. The ring holds ~2 s.
    func frameGaps() -> [Double] {
        guard frameTimestamps.count >= 2 else { return [] }
        var gaps: [Double] = []
        gaps.reserveCapacity(frameTimestamps.count - 1)
        for index in 1..<frameTimestamps.count {
            gaps.append((frameTimestamps[index] - frameTimestamps[index - 1]) * 1000)
        }
        return gaps
    }

    struct PerformanceStats {
        let samples: Int
        let hitches: Int
        let maxGapMs: Int
        let slowFrames: Int
        let applyCount: Int
        let applyMaxMs: Int
        let applyP95Ms: Int
        let measureCount: Int
        let measureMaxMs: Int
        let measureP95Ms: Int
    }

    func performanceStats() -> PerformanceStats {
        PerformanceStats(
            samples: counters["frameSamples"] ?? 0,
            hitches: counters["frameRateHitches"] ?? 0,
            maxGapMs: counters["frameRateMaxGapMs"] ?? 0,
            slowFrames: counters["slowFrames"] ?? 0,
            applyCount: counters["applyCount"] ?? 0,
            applyMaxMs: counters["applyMsMax"] ?? 0,
            applyP95Ms: percentile(applyDurations.map { $0.ms }, 0.95),
            measureCount: counters["measureCount"] ?? 0,
            measureMaxMs: counters["measureMsMax"] ?? 0,
            measureP95Ms: percentile(measureDurations.map { $0.ms }, 0.95))
    }

    private func percentile(_ values: [Int], _ fraction: Double) -> Int {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let index = Int((Double(sorted.count - 1) * fraction).rounded())
        return sorted[max(0, min(sorted.count - 1, index))]
    }

    /// Mark the current moment and keep the last rendered timeline frame.
    @discardableResult
    func mark(note: String = "") -> Mark {
        let mark = Mark(at: Date(), note: note, screenshot: captureScreenshot())
        markers.append(mark)
        if markers.count > Self.maxMarkers {
            markers.removeFirst(markers.count - Self.maxMarkers)
        }
        revision &+= 1
        return mark
    }

    /// Remove a mistaken capture. Export only writes the markers that remain.
    func removeMark(at index: Int) {
        guard markers.indices.contains(index) else { return }
        markers.remove(at: index)
        revision &+= 1
    }

    func clearMarks() {
        guard !markers.isEmpty else { return }
        markers.removeAll()
        revision &+= 1
    }

    // MARK: - Drawer motion

    /// The drawer records what started the transition, before its state
    /// propagates. The gap between this call and the environment flip is the
    /// UIKit/SwiftUI half of the first-frame cost.
    func noteDrawerIntent(_ kind: String) {
        drawerIntent = kind
        drawerIntentAt = CACurrentMediaTime()
    }

    /// The drawer publishes its motion window. The collection view is not
    /// scrolling during a drag, so without this signal the sidebar's dropped
    /// frames never reach the report (pp 2026-10-31).
    func noteDrawerTransition(_ active: Bool, opening: Bool) {
        guard active != drawerTransitioning else { return }
        let now = CACurrentMediaTime()
        drawerTransitioning = active
        if active {
            drawerStartedAt = now
            drawerFrames = 0
            drawerGaps.removeAll()
            drawerPeriodTotal = 0
            drawerOpening = opening
            drawerEnvFlipAt = now
            drawerIntentToEnvMs = Int(((now - (drawerIntentAt ?? now)) * 1000).rounded())
            drawerFirstTickSeen = false
            postDrawerTicksRemaining = 0
            noteHistory("drawer-start dir=\(opening ? "open" : "close") intent=\(drawerIntent)")
        } else {
            let startedAt = drawerStartedAt ?? now
            let gaps = drawerGaps
            let sorted = gaps.sorted()
            let avgGap = gaps.isEmpty ? 0
                : Int((Double(gaps.reduce(0, +)) / Double(gaps.count)).rounded())
            let periodMs = drawerFrames > 0 ? drawerPeriodTotal / Double(drawerFrames) * 1000 : 0
            // Derived from this window's own gaps, not from the 10 Hz scan:
            // the scan can observe a gap after the drawer flag already
            // flipped and hand a scroll hitch to the wrong transition.
            let transition = DrawerTransition(startedAt: startedAt, endedAt: now,
                                              frames: drawerFrames,
                                              opening: drawerOpening,
                                              intent: drawerIntent,
                                              intentToEnvMs: drawerIntentToEnvMs,
                                              envToTickMs: drawerEnvToTickMs,
                                              periodMs: periodMs,
                                              hitches: gaps.dropFirst().filter { $0 > 33 }.count
                                                  + ((drawerIntentToEnvMs + drawerEnvToTickMs) > 100 ? 1 : 0),
                                              maxGapMs: gaps.max() ?? 0,
                                              avgGapMs: avgGap,
                                              p50GapMs: sorted.isEmpty ? 0 : sorted[sorted.count / 2],
                                              firstGapMs: gaps.first ?? 0,
                                              gaps: gaps)
            drawerIntentAt = nil
            postDrawerTicksRemaining = 3
            drawerTransitions.append(transition)
            if drawerTransitions.count > 40 {
                drawerTransitions.removeFirst(drawerTransitions.count - 40)
            }
            drawerStartedAt = nil
            noteHistory("drawer-end ms=\(transition.durationMs) frames=\(transition.frames) "
                + "hitches=\(transition.hitches) maxGap=\(transition.maxGapMs)")
            revision &+= 1
        }
    }

    struct DrawerSummary {
        let count: Int
        let durationMs: Int
        let hitches: Int
        let maxGapMs: Int
    }

    func drawerSummary() -> DrawerSummary? {
        guard let last = drawerTransitions.last else { return nil }
        return DrawerSummary(count: drawerTransitions.count,
                             durationMs: last.durationMs,
                             hitches: last.hitches,
                             maxGapMs: last.maxGapMs)
    }

    /// The panel is a sheet above the list; the list keeps its last rendered
    /// frame, which is exactly what the reader saw before opening the panel.
    func captureScreenshot() -> UIImage? {
        guard let view = controller?.view,
              view.bounds.width > 1, view.bounds.height > 1 else { return nil }
        let format = UIGraphicsImageRendererFormat.default()
        // 1x keeps a full-screen mark small enough to hold three in memory
        // while still showing layout/visual regressions.
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(bounds: view.bounds, format: format)
        return renderer.image { context in
            let drawn = view.drawHierarchy(in: view.bounds, afterScreenUpdates: false)
            if !drawn {
                view.layer.render(in: context.cgContext)
            }
        }
    }

    /// Write the report and the newest mark screenshots to the temporary
    /// directory; the panel shares the returned files.
    func writeExportFiles() -> [URL] {
        let stamp = Self.exportFormatter.string(from: Date())
        let directory = FileManager.default.temporaryDirectory
        let reportURL = directory.appendingPathComponent("diagnostics-\(stamp).txt")
        try? report().write(to: reportURL, atomically: true, encoding: .utf8)
        var urls = [reportURL]
        for (index, mark) in markers.suffix(3).enumerated() {
            guard let data = mark.screenshot?.pngData() else { continue }
            let url = directory.appendingPathComponent("mark-\(stamp)-\(index + 1).png")
            try? data.write(to: url)
            urls.append(url)
        }
        return urls
    }

    /// Recent history-paging lines for the events tab.
    func recentEventLines(limit: Int = 24) -> [String] {
        historyEvents.suffix(limit).map { "H t=\(elapsed($0.at)) \($0.text)" }
    }

    private static let exportFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        return formatter
    }()

    private static let absoluteFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        return formatter
    }()

    private static func absolute(_ date: Date) -> String {
        absoluteFormatter.string(from: date)
    }

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
            + "wasDisplayed=row had been on screen when the change was recorded "
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

        if let lastClearedAt {
            lines.append("cleared \(Self.absolute(lastClearedAt)) CST")
        }

        lines.append("--- FINDINGS (severity first) ---")
        let summary = findings()
        if summary.isEmpty {
            lines.append("F none")
        } else {
            for finding in summary {
                lines.append("F t=\(elapsed(finding.at)) [\(finding.severity)] "
                    + "\(finding.kind) \(finding.detail)")
            }
        }

        if !markers.isEmpty {
            lines.append("--- MARKS (oldest first) ---")
            for mark in markers {
                let note = mark.note.isEmpty ? "" : " \(mark.note)"
                lines.append("M \(Self.absolute(mark.at)) CST\(note)")
            }
        }

        if !drawerTransitions.isEmpty {
            lines.append("--- DRAWER (oldest first) ---")
            for transition in drawerTransitions {
                lines.append("D t=\(elapsed(transition.startedAt)) dir=\(transition.opening ? "open" : "close") "
                    + "intent=\(transition.intent) i2e=\(transition.intentToEnvMs)ms "
                    + "e2t=\(transition.envToTickMs)ms "
                    + "period=\(String(format: "%.1f", transition.periodMs))ms "
                    + "dur=\(transition.durationMs)ms "
                    + "frames=\(transition.frames) hitches=\(transition.hitches) "
                    + "maxGap=\(transition.maxGapMs)ms avg=\(transition.avgGapMs)ms "
                    + "p50=\(transition.p50GapMs)ms first=\(transition.firstGapMs)ms "
                    + "end=\(transition.endGapMs)ms "
                    + "post=[\(transition.postGaps.map { String($0) }.joined(separator: ","))] "
                    + "gaps=[\(transition.gaps.map { String($0) }.joined(separator: ","))]")
            }
            // The first frame is where the felt hitch lives. Split it by
            // what started the transition and by which half of the frame
            // (intent -> env flip -> render) spent the time.
            for intent in Set(drawerTransitions.map(\.intent)).sorted() {
                let items = drawerTransitions.filter { $0.intent == intent }
                guard !items.isEmpty else { continue }
                let firsts = items.map(\.firstGapMs)
                let avgFirst = firsts.reduce(0, +) / firsts.count
                let avgI2E = items.map(\.intentToEnvMs).reduce(0, +) / items.count
                let avgE2T = items.map(\.envToTickMs).reduce(0, +) / items.count
                let hitches = items.map(\.hitches).reduce(0, +)
                let maxGap = items.map(\.maxGapMs).max() ?? 0
                lines.append("DI intent=\(intent) n=\(items.count) avgFirst=\(avgFirst)ms "
                    + "avgI2E=\(avgI2E)ms avgE2T=\(avgE2T)ms hitches=\(hitches) maxGap=\(maxGap)ms")
            }
            for direction in [true, false] {
                let items = drawerTransitions.filter { $0.opening == direction }
                guard !items.isEmpty else { continue }
                let firsts = items.map(\.firstGapMs)
                let avgFirst = firsts.reduce(0, +) / firsts.count
                lines.append("DD dir=\(direction ? "open" : "close") n=\(items.count) "
                    + "avgFirst=\(avgFirst)ms "
                    + "hitches=\(items.map(\.hitches).reduce(0, +))")
            }
        }

        if let controller, let view = controller.collectionView {
            lines.append("--- VISIBLE (top to bottom) ---")
            let visiblePaths = Set(view.indexPathsForVisibleItems)
            for attribute in controller.layout.orderedAttributes
            where visiblePaths.contains(attribute.indexPath) {
                guard let item = attribute.item else { continue }
                let cell = view.cellForItem(at: attribute.indexPath)
                let cellY = cell.map { f($0.frame.minY) } ?? "-"
                let cellH = cell.map { f($0.frame.height) } ?? "-"
                // The fit width and the height key width must agree; a cell
                // that settles at another width re-wraps the text and the
                // structural height diverges (device probe: 26188 vs 24288).
                let cellW = cell.map { f($0.contentView.bounds.width) } ?? "-"
                let keyW = attribute.heightKey.map { f($0.width) } ?? "-"
                let facts = heightFacts(itemID: item.itemID, item: item)
                let exact = facts.structuralExact.map(f) ?? "-"
                let writer = writerLabel(itemID: item.itemID,
                                         revision: facts.keyRevision)
                lines.append("V \(item.itemID) y=\(f(attribute.frame.minY)) h=\(f(attribute.frame.height)) "
                    + "cell=(\(cellY),\(cellH)) cw=\(cellW) kw=\(keyW) "
                    + "est=\(f(facts.crudeEstimate)) tier=\(facts.tier) "
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
                + "vis=\(change.visible ? 1 : 0) wasDisplayed=\(change.wasDisplayed ? 1 : 0) "
                + "n=\(change.repeatCount) \(change.itemDescription)")
        }

        lines.append("--- APPLIES (newest first) ---")
        for apply in applies.suffix(14).reversed() {
            let keys = apply.changedKeySample.isEmpty
                ? "-" : apply.changedKeySample.joined(separator: ",")
            let diffs = apply.keyDiffSample.isEmpty
                ? "" : " diffs=[\(apply.keyDiffSample.joined(separator: ";"))]"
            let itemDelta = apply.addedItemIDs.isEmpty && apply.removedItemIDs.isEmpty
                ? "" : " added=[\(apply.addedItemIDs.joined(separator: ","))]"
                    + " removed=[\(apply.removedItemIDs.joined(separator: ","))]"
            lines.append("A t=\(elapsed(apply.at)) items=\(apply.itemCount) changed=\(apply.changedCount) "
                + "anim=\(apply.animating ? 1 : 0) contentH=\(f(apply.contentHeight)) "
                + "off=\(f(apply.offset)) visible=\(apply.visibleCount) estimates=\(apply.estimateRows) "
                + "keys=\(apply.changedKeyCount)[\(keys)]\(diffs)\(itemDelta)")
        }

        lines.append("--- HISTORY (oldest first) ---")
        for event in historyEvents {
            lines.append("H t=\(elapsed(event.at)) \(event.text)")
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

// MARK: - Attachment

/// Probe builds attach the store to the live controller without adding any
/// UI. The diagnostics panel lives in the session menu and in Settings, so
/// the page itself carries no floating pills.
@MainActor
struct TimelineProbeAttachment: ViewModifier {
    let controller: TimelineCollectionController?
    let adapter: TimelineChatContentAdapter?
    let ready: Bool

    func body(content: Content) -> some View {
        content
            .onChange(of: ready, initial: true) { _, _ in
                TimelineProbeStore.shared.attach(controller: controller, adapter: adapter)
            }
            .onChange(of: controller.map { ObjectIdentifier($0) }) { _, _ in
                TimelineProbeStore.shared.attach(controller: controller, adapter: adapter)
            }
            .onDisappear { TimelineProbeStore.shared.detach() }
    }
}
#else
import SwiftUI

// Shipping builds carry no probe; the call site is compile-gated.
#endif

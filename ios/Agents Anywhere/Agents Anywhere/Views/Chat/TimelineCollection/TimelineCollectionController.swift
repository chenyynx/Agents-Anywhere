import SwiftUI
import UIKit
import OSLog

/// Rollback switch for the official-style history anchor. The old
/// `TimelineInsertionOwed` path stays available when this is false; the
/// product path uses the anchor driver's persistent reading placement.
nonisolated enum TimelineHistoryAnchorMode {
    static let defaultsKey = "TimelineHistoryAnchorV2.enabled"
    static var enabled: Bool {
        if let value = UserDefaults.standard.object(forKey: defaultsKey) as? Bool {
            return value
        }
        return true
    }
}

/// File-scope so the diffable data source's `Sendable` section identifier is
/// not inferred as main-actor isolated from the controller class.
nonisolated enum TimelineCollectionSection: Hashable, Sendable {
    case main
}

/// Owns the collection timeline's UIKit side: data source, measurement
/// scheduling, scroll phases, pull state, and the persistent bottom target.
///
/// The layout never measures; this controller measures changed/new items
/// before the snapshot applies, then keeps measuring pending rows off the
/// scroll path and hands each result to the layout. C4/C5 replace the
/// synthetic C3 provider with the chat model and wire the remaining
/// interactions.
@MainActor
final class TimelineCollectionController: UIViewController {
    let layout = TimelineListLayout()
    private(set) var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<TimelineCollectionSection, TimelineListItem>!
    weak var content: TimelineCollectionContentProviding?
    private(set) var measurer: (any TimelineHeightMeasuring)?

    private var currentItems: [TimelineListItem] = []
    /// Anchor of the history page whose prepend target is installed. The
    /// projection is recomputed after the apply's measurement pass, because
    /// the budgeted pass at request time can leave rows on estimates.
    private var insertionProjection: (anchorRowID: String,
                                      edge: TimelineHistoryLayout.Edge)?
    /// Official-style history paging: the anchor driver owns the offset while
    /// this is true. `historyPageArriving` marks the apply that actually
    /// carries the prepended page, so an unrelated streaming apply cannot end
    /// the mode early.
    private(set) var historyPaging = false
    /// The item the driver pinned for the in-flight history page. The probe
    /// re-reads its screen position before/after each apply so a jump is
    /// attributed to the row the reader was actually looking at.
    private var historyAnchorItemID: String?
    /// The stable reading key. A history page can regroup the whole window,
    /// which changes the anchor item's id even though its rows are still
    /// present; the row id is what survives that regrouping.
    private var historyAnchorRowID: String?
    private var historyAnchorOffsetIntoRow: CGFloat = 0
    /// The page's layout can keep correcting heights after the snapshot
    /// commits. During that short quiet window the reading anchor is still
    /// re-resolved on every content-height change; without it a correction
    /// above the anchor moves the visible row (device: 115.7 pt).
    private var historyAnchorSettling = false
    private var historySettleTask: Task<Void, Never>?
    private var historyPageArriving = false
    private var historyInitialFirstRowID: String?
    private var historyPageFirstRowID: String?
    private var historyPagingTimeout: Task<Void, Never>?
    /// At most one snapshot may be in flight. The diffable data source
    /// performs its batch updates asynchronously, while SwiftUI can hand us a
    /// newer item list on a later runloop turn. The layout reads its items
    /// through `currentItems`, so advancing that list before the in-flight
    /// update finishes makes the layout describe a different snapshot than
    /// UIKit is performing: a missing attribute for the reconfigured index
    /// path aborts `dequeueReusableCell` (SIGABRT), and with equal counts it
    /// silently places cells at another snapshot's frames, which is the
    /// overlapping-rows report. Queue the newest request instead.
    private var isPerformingSnapshot = false
    private enum PendingSnapshotUpdate {
        case apply(items: [TimelineListItem], animating: Bool)
        case reconfigure(items: [TimelineListItem])
    }
    private var pendingSnapshotUpdate: PendingSnapshotUpdate?
    /// Items whose assistant body was measured synchronously with TextKit 2.
    /// The same set decides which cell the data source returns, so a row can
    /// never render in the TextKit cell with an estimate height.
    private(set) var documentHeights: [String: CGFloat] = [:]
    private var lastReloadGeneration = Int.min
    private var signatures = TimelineContentSignatures()
    private var measurementPipeline = TimelineMeasurementPipeline(budgetMilliseconds: .max)
    private var pendingApply: (items: [TimelineListItem], animating: Bool)?
    private var pendingMeasurementTask: Task<Void, Never>?
    private var visibleCellSettleTask: Task<Void, Never>?
    /// Keys whose hosting geometry has already reported a height. The official
    /// contract has no re-measure loop: the geometry value is the measurement
    /// (`CANONICAL/05-layout-scroll.md` §2.2). Tracked so the visible-cell
    /// pass only fits a row whose SwiftUI content has not reported yet.
    private var hostedGeometryKeys: [String: TimelineHeightKey] = [:]
    /// The width at which the one-shot first-materialization fit ran for a
    /// hosted row. Official `0x101a39244` self-measures only while
    /// `isMeasured == false`; with the geometry report as the primary path
    /// this fit is only the fallback for a cell whose SwiftUI content has not
    /// completed its first layout pass. At most one per row per width, never
    /// once per snapshot.
    private var hostedFallbackFitWidths: [String: CGFloat] = [:]
    /// A geometry report that arrived while a programmatic return owned the
    /// offset. The old settle path skipped `.animating` for the same reason
    /// (a row correction inside the animation adds a second offset change);
    /// the animation-end pass flushes these in `settleVisibleCellHeightsOnce`.
    private struct PendingHostedReport {
        let key: TimelineHeightKey
        let height: CGFloat
    }
    private var pendingHostedReports: [String: PendingHostedReport] = [:]
    /// When a hosted row was first seen by a settle pass without a geometry
    /// report. The single first-materialization fit waits for one more layout
    /// opportunity; the cell can still be measuring its pre-layout skeleton on
    /// the first pass (458 probe: 598 → 54 → 598) and there is no second fit
    /// to reject that value.
    private var hostedFallbackFirstSeenAt: [String: TimeInterval] = [:]
    private var cellFrameSyncScheduled = false
    private var visibleCellSettleGeneration = 0
    /// A settle request that arrived while the ladder was between passes. The
    /// running ladder wakes early instead of being cancelled and restarted
    /// (restarting at the streaming frame rate starved every later read).
    private var visibleCellSettleNudged = false
    private var lastPublishedViewport = TimelineViewport()

    private(set) var phase = TimelinePhaseMapping()
    /// C4: the single content-offset writer (placement state + Mover + inset).
    private var anchorDriver: TimelineAnchorDriver?
    private var didStartAnchorDriver = false
    /// A "load latest" return may span a full-window replacement. UIKit
    /// re-anchors a snapshot that replaces every id, and the animated target
    /// was computed against the old content height; the return must be
    /// re-resolved once the new window has laid out (device report 2026-10-23).
    private var windowReplacementReturn = false
    /// Bounds the flag's lifetime when the requested page turns out to be the
    /// same window: an unrelated replacement minutes later must not inherit
    /// the return.
    private var windowReturnToken = 0
    private(set) var olderPull = TimelineHistoryPull(edge: .older)
    private(set) var latestPull = TimelineHistoryPull(edge: .latest)
    private(set) var streamingItemIDs: Set<String> = []

    private(set) var interactionPresented = false
    private var navigationSuspended = false
#if DEBUG
    /// Set by `TimelineAutoRun` only. Never reachable from the product UI.
    private(set) var testGestureState: (tracking: Bool, decelerating: Bool)?
    /// Call sites of offset changes that land while the test gesture is
    /// active. The gate reads this to name the writer when a height
    /// application moves the reader's scroll (gestureFreeze).
    private(set) var debugScrollCallSites: [String] = []
    private var debugScrollLastOffset: CGFloat?
    /// C5 gate counters: reveal frames and whether they were eligible for the
    /// follow, plus the driver's Mover starts.
    private(set) var debugStreamingFrameCalls = 0
    private(set) var debugStreamingFollowEligibleFrames = 0
    var debugStreamingFollowStarts: Int { anchorDriver?.debugMoveStarts ?? 0 }
    var debugIsFollowing: Bool { anchorDriver?.state.placement == .end }
    /// Gate probe for the offset-sensitive scenarios: which placement/motion
    /// the driver holds and whether its Mover is travelling right now.
    var debugAnchorState: String {
        guard let driver = anchorDriver else { return "no-driver" }
        return String(describing: driver.state)
    }
    var debugMoverRunning: Bool { anchorDriver?.debugMoverRunning ?? false }
    func clearDebugScrollCallSites() {
        debugScrollCallSites.removeAll()
        debugScrollLastOffset = nil
    }
#endif
    /// Commands that arrive while the drawer owns navigation. The old state
    /// machine refused the native command but kept the intent; resume replays
    /// it exactly once instead of silently dropping a pending/approval return.
    private var suspendedBottomRequest: (animated: Bool, forced: Bool)?
    /// A bottom request that arrived with the reader's finger on the list.
    /// Official `askedForEnd` is ignored while dragging (part-ag §1.7);
    /// replay it when the gesture ends instead of starting a spring that
    /// would fight the finger.
    private var pendingGestureBottomRequest: (animated: Bool, forced: Bool)?
    private var suspendedOpeningRequest = false
    private var lastContainerHeight: CGFloat = 0
    /// The old path passed `nil` to `withAnimation` under Reduce Motion, so a
    /// return landed immediately. The wrapper forwards the environment value.
    private var reduceMotion = false
    private var didMarkActivation = false
    private static let log = Logger(subsystem: "agents.anywhere", category: "timeline")

    /// Probe-only timeline history trace. The parameter is an autoclosure so
    /// shipping builds do not pay for string interpolation, and the probe
    /// store is never referenced outside `AA_TIMELINE_PROBE`.
    private func probeHistory(_ text: @autoclosure () -> String) {
#if AA_TIMELINE_PROBE
        TimelineProbeStore.shared.noteHistory(text())
#endif
    }

    /// Pull inputs. C5 sets these from the real prompt visibility and session
    /// flags; the C3 gate drives them directly.
    var olderPromptVisible = false
    var latestPromptVisible = false
    var canLoadOlder = false
    var canLoadLatest = false
    var onLoadOlder: (() -> Void)?
    var onLoadLatest: (() -> Void)?
    /// Viewport-driven paging. Reaching the top edge starts one older page;
    /// reaching the bottom of a history window starts one latest page. Both
    /// are one-shot per edge so a failed page cannot spin on every frame.
    var onNeedsOlder: (() -> Void)? {
        didSet { if onNeedsOlder != nil { olderAutoLoadArmed = true } }
    }
    var onNeedsLatest: (() -> Void)? {
        didSet { if onNeedsLatest != nil { latestAutoLoadArmed = true } }
    }

    var onPhaseChanged: ((TimelinePhaseMapping.Transition) -> Void)?
    var onViewportChanged: ((TimelineViewport) -> Void)?
    var onContentHeightChanged: ((CGFloat) -> Void)?
    /// Fires whenever the measured viewport reaches the bottom. The product
    /// wrapper uses it to release the cold-load mask on a real arrival instead
    /// of on the apply completion (which can precede the first layout).
    var onBottomArrived: (() -> Void)?
    /// Fires after a snapshot apply, before pending measurements start. The
    /// C3 gate uses it to capture the first displayed height for the async
    /// Markdown probe.
    var onApplyCompleted: (() -> Void)?
    /// The Code page's `ScrollDownIndicator` visibility. The official view has
    /// no threshold of its own — the host passes `hidden` (part-u §5.1) — and
    /// the host-side predicate is the shared `_canScrollDown` judgement:
    /// `target − visibleBottom > 1 physical pixel` (part-ag §1.3, `0x1019ddbf0`).
    /// The product owns this callback directly: the representable reassigns
    /// its own callback parameters on every update, which would clear one
    /// installed there (TimelineCollectionView.updateUIViewController).
    var onScrollDownIndicatorChanged: ((Bool) -> Void)?
    private var lastScrollDownIndicator: Bool?
    /// One auto-page request per edge episode. Scrolling away re-arms it; a
    /// failed load does not retry on every viewport tick.
    private var latestAutoLoadArmed = true
    /// Set after a local-first latest page keeps `hasNewerItems` for its
    /// background reconcile. Without a latch, a content-height change makes
    /// the viewport dip out of bottom and re-arms the trigger, so the same
    /// read (and its spinner) starts again before the reconcile lands.
    private var latestAutoLoadSuppressed = false
    /// A history page can leave the window shorter than the viewport, which
    /// reads as "at bottom" immediately after the prepend. Do not turn that
    /// into an automatic latest read; require the reader to leave bottom and
    /// come back (or tap the latest prompt) first.
    private var latestAutoLoadNeedsNewBottomVisit = false
    private var olderAutoLoadArmed = true
    /// How close to the top edge starts an automatic older page. This is a
    /// reading threshold, not a pull threshold: a full screen of history is
    /// still reachable before the next page starts.
    private static let olderAutoLoadThreshold: CGFloat = 320
    /// The page's SwiftUI safe area: composer bar + home indicator + keyboard.
    /// The list is a full-bleed representable, so this is its only inset
    /// source. The probe (run 40353074977) measured the proxy inside the
    /// `safeAreaBar` at exactly those three parts, delivered once per change
    /// inside the system animation transaction.
    var safeAreaInsets: UIEdgeInsets = .zero {
        didSet {
            guard oldValue != safeAreaInsets else { return }
            anchorDriver?.updateSafeAreaInsets(safeAreaInsets)
        }
    }

    // MARK: - Lifecycle

    override func loadView() {
        let root = UIView()
        root.backgroundColor = .clear
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.backgroundColor = .clear
        // The SwiftUI timeline asked for `.scrollEdgeEffectStyle(.soft, for:
        // .top)`. A bare UICollectionView keeps the system's default (hard)
        // edge effect, which reads as a solid bar over the transparent page;
        // match the old page on both edges.
        collectionView.topEdgeEffect.style = .soft
        // [E] R21 chrome-verify.md — the official Code session neither hides
        // the bottom edge effect nor draws a custom gradient on iOS 26. The
        // system effect is what fades rows passing under the composer's
        // `safeAreaBar`; hiding it removed that fade and left the composer on
        // a flat strip. A bare collection view defaults to the hard style, so
        // ask for the same soft edge the top uses.
        collectionView.bottomEdgeEffect.style = .soft
        collectionView.alwaysBounceVertical = true
        // Keep the system's vertical indicator. The page is full-bleed and the
        // collection owns the whole right edge; hiding it left long timelines
        // with no scroll-position affordance (pp 2026-10-30).
        collectionView.showsVerticalScrollIndicator = true
        collectionView.indicatorStyle = .default
        // [E] CANONICAL/05-layout-scroll.md §5 — the official surface uses
        // `keyboardDismissMode = .interactiveWithAccessory` (raw 4,
        // `0x101a3b344`), not the plain interactive mode.
        collectionView.keyboardDismissMode = .interactiveWithAccessory
        // Kept at the system default, exactly like the official surface (the
        // evidence never finds a write to this property). The official formula
        // subtracts the scroll view's own safe-area insets, so whether UIKit
        // contributes them or not the net inset is the page proxy.
        collectionView.contentInsetAdjustmentBehavior = .automatic
        // The official surface disables UIKit's automatic self-sizing
        // invalidation; the layout owns every height. AA's controlled
        // exceptions are driven explicitly by `applyPreferredHeights` after a
        // reconfigure, so automatic invalidation would only add layout passes.
        collectionView.selfSizingInvalidation = .disabled
        collectionView.delegate = self
        anchorDriver = TimelineAnchorDriver(scrollView: collectionView, inputs: .init(
            contentHeight: { [weak self] in self?.layout.contentHeight ?? 0 },
            rowStart: { [weak self] in self?.layout.attributes(for: $0)?.frame.minY },
            readingAnchor: { [weak self] in self?.anchor(at: $0) },
            firstRowID: { [weak self] in self?.currentItems.first?.itemID },
            onBottomArrived: { [weak self] in self?.onBottomArrived?() }))
        anchorDriver?.setSuspended(navigationSuspended)
        anchorDriver?.updateSafeAreaInsets(safeAreaInsets)
#if AA_TIMELINE_PROBE
        AnchorDeviceProbe.shared.attach { [weak self] in
            guard let self else { return (false, false, "?") }
            return (self.anchorDriver?.state.placement == .end, false,
                    String(describing: self.phase.phase))
        }
#endif
        collectionView.register(TimelineHostingCell.self,
                                forCellWithReuseIdentifier: TimelineHostingCell.reuseIdentifier)
        collectionView.register(AssistantMarkdownCell.self,
                                forCellWithReuseIdentifier: AssistantMarkdownCell.reuseIdentifier)
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        layout.host = self
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { [weak self] collectionView, indexPath, item in
            if let self, let content = self.content {
                if let streaming = content.assistantStreamingDocument(for: item),
                   self.documentHeights[item.itemID] != nil {
                    let cell = collectionView.dequeueReusableCell(
                        withReuseIdentifier: AssistantMarkdownCell.reuseIdentifier,
                        for: indexPath) as! AssistantMarkdownCell
                    cell.configure(streaming: streaming,
                                   reveal: content.assistantStreamingReveal(for: item))
                    cell.onStreamingRevealFrame = { [weak self] height in
                        self?.streamingRevealFrame(height, for: item)
                    }
                    cell.onStreamingRevealCaughtUp = { [weak self] in
                        DispatchQueue.main.async {
                            guard let self else { return }
                            self.content?.streamingRevealDidFinish(for: item)
                            self.reloadFromContent()
                        }
                    }
                    return cell
                }
                if let document = content.assistantMarkdown(for: item),
                   self.documentHeights[item.itemID] != nil {
                    let cell = collectionView.dequeueReusableCell(
                        withReuseIdentifier: AssistantMarkdownCell.reuseIdentifier,
                        for: indexPath) as! AssistantMarkdownCell
                    cell.configure(document,
                                   footer: content.assistantFooter(for: item))
                    // The reveal's per-frame override belongs to the previous
                    // streaming configuration; hand the row back to the
                    // measured height.
                    self.layout.clearStreamingHeight(for: item.itemID)
                    return cell
                }
            }
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: TimelineHostingCell.reuseIdentifier,
                                                          for: indexPath) as! TimelineHostingCell
            if let self, let content = self.content {
                // Official 0x101a3ff20: `isMeasured` is item-level and only a
                // width change clears it. A same-width content revision keeps
                // the row measured instead of reopening its one self-measure;
                // the hosting geometry report supplies the new height.
                let isMeasured = self.layout.heights.isMeasured(
                    itemID: item.itemID, width: self.columnWidth)
                // Seed an unmeasured cell-reported row's one self-measure.
                // Official Part V §2.5: a placeholder row's height is the last
                // measured value (`__height`/`__headerHeight` are
                // `LazyState<CGFloat>`), and 05-layout-scroll.md:93 gives a
                // never-measured row only the estimate tier until the cell
                // materializes. Code has no reveal and re-lays out as data
                // arrives (11-motion-haptics.md:314, 10-chat-page.md:154), so
                // the provider's structural height is the real value when it
                // exists. Without one (streaming or pre-layout content) the row
                // keeps the height `prepare()` already recorded for it — the
                // estimate for a never-shown row, the displayed height
                // otherwise. Letting UIKit fit the pre-layout body instead
                // collapsed a streaming row 44→18 (461 probe); the content's
                // later geometry change supersedes the seed through the
                // changed-only `onContentHeightReport` path.
                let reportsContentHeight = content.usesCellReportedHeight(for: item)
                let seed: CGFloat?
                if !isMeasured, reportsContentHeight {
                    if let structural = content.measuredCodeGroupHeight(
                        for: item, width: self.columnWidth) {
                        seed = structural
                    } else if let displayed = self.layout.heights.displayedHeight(
                        for: item.itemID), displayed > 1 {
                        seed = displayed
                    } else {
                        seed = nil
                    }
                } else {
                    seed = nil
                }
                // A hosted row's geometry value is its measurement (official
                // `_GeometryActionModifier` → `rowMeasured`,
                // `CANONICAL/05-layout-scroll.md` §2.2). Capture the key and
                // signature this configuration's content belongs to; a
                // width/typography re-key of the same content (rotation does
                // not reconfigure the cell) is still accepted. The Chat rows
                // keep the controller polling path.
                if reportsContentHeight {
                    let reportKey = content.heightKey(for: item, width: self.columnWidth)
                    let reportSignature = content.contentSignature(for: item)
                    cell.onContentHeightReport = { [weak self] height in
                        self?.hostedContentHeightReported(
                            height, for: item,
                            reportedKey: reportKey, reportedSignature: reportSignature)
                    }
                } else {
                    cell.onContentHeightReport = nil
                }
                cell.configure(content.rowView(for: item),
                               policy: content.heightPolicy(for: item),
                               isMeasured: isMeasured,
                               reportsContentHeight: reportsContentHeight,
                               seededHeight: seed)
            }
            return cell
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if let hosted = measurer as? TimelineHostingHeightMeasurer {
            hosted.updateTraitOverrides(from: traitCollection)
        }
        if let pending = pendingApply, columnWidth > 0 {
            pendingApply = nil
            apply(items: pending.items, animating: pending.animating)
        }
        handleContainerHeightChange()
        startAnchorDriverIfNeeded()
        scheduleVisibleCellFrameSync()
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        // The formula subtracts the scroll view's own safe area. It is zero
        // before the view joins the window and becomes the home indicator
        // afterwards, so the inset must be re-derived here or the page keeps
        // an extra 34 pt below the composer. `applyInsets` is idempotent.
        anchorDriver?.updateSafeAreaInsets(safeAreaInsets)
        handleContainerHeightChange()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !didMarkActivation else { return }
        didMarkActivation = true
        UserDefaults.standard.set(Date(), forKey: TimelineCollectionSwitch.lastActiveKey)
        Self.log.notice("aa.timeline.collectionView active")
    }

    func configure(measurer: any TimelineHeightMeasuring, content: TimelineCollectionContentProviding) {
        self.measurer = measurer
        self.content = content
        if isViewLoaded { reloadFromContent() }
    }

    func setMeasurementBudget(milliseconds: Int) {
        measurementPipeline = TimelineMeasurementPipeline(budgetMilliseconds: milliseconds)
    }

    // MARK: - Snapshot

    func reloadFromContent(animating: Bool = false) {
        guard let content else { return }
        guard content.contentGeneration != lastReloadGeneration else { return }
        lastReloadGeneration = content.contentGeneration
        let items = (0..<content.itemCount).map { content.item(at: $0) }
        apply(items: items, animating: animating)
    }

    /// Measures changed/new items before the snapshot applies, then applies.
    /// The layout resolves fixed heights from the cache in `prepare`.
    func apply(items: [TimelineListItem], animating: Bool = false) {
        guard isViewLoaded, let content, columnWidth > 0 else {
            pendingApply = (items: items, animating: animating)
            return
        }
        guard !isPerformingSnapshot else {
            pendingSnapshotUpdate = .apply(items: items, animating: animating)
            return
        }
        isPerformingSnapshot = true
#if AA_TIMELINE_PROBE
        let probeApplyStart = CACurrentMediaTime()
#endif
        let oldItems = currentItems
        let oldIDs = Set(oldItems)
        // A window replacement drops the old dynamic rows; a prepend/append
        // keeps them. Compare the first *dynamic* item because `.olderPrompt`
        // / `.latestPrompt` / `.tail` have static identities and both windows
        // can start with `.olderPrompt` (device report 2026-10-23).
        let oldFirstDynamic = oldItems.first(where: Self.isDynamicItem)
        let currentFirstRowID = items.first.flatMap { content.rowIDs(in: $0).first }
        let isHistoryPage: Bool
        if historyPageArriving {
            isHistoryPage = historyPageFirstRowID.map { currentFirstRowID == $0 }
                ?? (currentFirstRowID != nil)
        } else {
            isHistoryPage = currentFirstRowID != nil
                && currentFirstRowID != historyInitialFirstRowID
        }
        let applyingHistoryPage = historyPaging && isHistoryPage
#if AA_TIMELINE_PROBE
        let probeAnchorID = historyAnchorItemID
        let probeOffsetBefore = collectionView.contentOffset.y
        let probeAnchorYBefore = probeAnchorID
            .flatMap { layout.attributes(for: $0) }
            .map { $0.frame.minY - probeOffsetBefore } ?? -1
        TimelineProbeStore.shared.noteHistory(
            "apply-begin hist=\(historyPaging ? 1 : 0) arriving=\(historyPageArriving ? 1 : 0) "
            + "pageFirst=\(historyPageFirstRowID ?? "-") initialFirst=\(historyInitialFirstRowID ?? "-") "
            + "firstRow=\(currentFirstRowID ?? "-") "
            + "oldFirstRow=\(oldItems.first.flatMap { content.rowIDs(in: $0).first } ?? "-") "
            + "oldN=\(oldItems.count) newN=\(items.count) applying=\(applyingHistoryPage ? 1 : 0) "
            + "pending=\(layout.pendingMeasurements.count) "
            + "off=\(probeOffsetBefore) contentH=\(layout.contentHeight) "
            + "anchor=\(probeAnchorID ?? "-") anchorY=\(probeAnchorYBefore)")
#endif
        let windowReplaced = !items.isEmpty
            && (oldFirstDynamic.map { !items.contains($0) } ?? true)
        // Parked heights belong to the window that is leaving; their rows and
        // the parked offset must not land on the replacement's snapshot.
        if windowReplaced { layout.discardParkedHeights() }
        let resolveWindowBottom = windowReplaced && windowReplacementReturn
            && insertionProjection == nil
        let entries: [TimelineContentEntry] = items.map { item in
            TimelineContentEntry(item: item, signature: content.contentSignature(for: item))
        }
        let change = signatures.update(entries)
        let changed = Set(change.changed)
#if AA_TIMELINE_PROBE
        TimelineProbeStore.shared.noteApply(items: items, changedCount: change.changed.count,
                                            animating: animating,
                                            contentHeight: layout.contentHeight,
                                            pendingMeasurements: layout.pendingMeasurements.count)
#endif
        // A diffable reconfigure can let UIKit apply the new preferred height
        // before our animation starts; remember where the row was so the
        // animation can start there instead of from the already-final frame.
        //
        // Only rows whose content just changed may animate. Recording every
        // interactive row made a first measurement (estimate → measured while
        // scrolling) animate too, which visibly changed the tool/body gaps
        // under the reader's finger (device report 2026-10-22/23). A row with
        // no recorded height applies its new height directly.
        var beforeHeights: [String: CGFloat] = [:]
        for item in items where changed.contains(item)
            && content.heightPolicy(for: item) == .interactive {
            if let height = layout.attributes(for: item.itemID)?.frame.height {
                beforeHeights[item.itemID] = height
            }
        }
        let recordedAt = CACurrentMediaTime()
        previousInteractiveHeights = beforeHeights.mapValues {
            PreChangeHeight(height: $0, recordedAt: recordedAt)
        }
        // A content change and a key change are not the same set: rotation,
        // Dynamic Type and a typography setting produce a new width/key with
        // an unchanged signature. Measure anything the cache has no real
        // height for, and reconfigure every cell whose key moved: the cell's
        // SwiftUI text reads the type scale from UserDefaults, which is not
        // observable, so a new height without a reconfigure would pair the
        // new frame with the old font.
        var toMeasure: [TimelineListItem] = []
        var reconfigure = changed
        // Same offscreen rule as the async settle pass: a row far above the
        // reader keeps its estimate until it can be seen. Without this, the
        // next ordinary apply (a stream tick) synchronously measures every
        // unmeasured row of the history page it just prepended.
        let measurementTop = viewport.offsetY + viewport.topInset
        let measurementSkipAbove = measurementTop
            - max(Self.pendingMeasurementPrefetchMargin, viewport.visibleHeight * 1.5)
        for item in items {
            let key = content.heightKey(for: item, width: columnWidth)
            if layout.heights.currentKey(for: item.itemID) != key {
                // Install the key before the snapshot applies. A hosted cell
                // can report its new content height during the update, and
                // that report must land on the key this apply established,
                // not on the revision it replaced.
                layout.heights.setCurrentKey(key)
                // A new revision gets its own first-layout window before the
                // one-shot fallback fit; the cell was just reconfigured.
                hostedFallbackFirstSeenAt[item.itemID] = nil
                reconfigure.insert(item)
            }
            if changed.contains(item) || !layout.heights.hasMeasuredOrPrecalcHeight(for: key) {
                if let attributes = layout.attributes(for: item.itemID),
                   attributes.frame.maxY < measurementSkipAbove {
                    continue
                }
                toMeasure.append(item)
            }
        }
#if AA_TIMELINE_PROBE
        let probeMeasureStart = CACurrentMediaTime()
#endif
        if !applyingHistoryPage {
            // The history page's new rows are offscreen above the reading
            // anchor; let the layout's estimates place them and let cells
            // measure when they become visible (official arriving/guessed).
            // Other applies while the request is in flight still measure.
            measureSynchronously(toMeasure, width: columnWidth)
        }
#if AA_TIMELINE_PROBE
        TimelineProbeStore.shared.noteMeasureDuration(CACurrentMediaTime() - probeApplyStart)
        TimelineProbeStore.shared.noteHistory(
            "apply-measure skipped=\(applyingHistoryPage ? 1 : 0) n=\(toMeasure.count) "
            + "ms=\(Int(((CACurrentMediaTime() - probeMeasureStart) * 1000).rounded()))")
#endif
        // Recompute the prepend target from the heights this apply will use.
        if let projection = insertionProjection,
           let projected = projectedHistoryLayout(items: items,
                                                  anchorRowID: projection.anchorRowID,
                                                  edge: projection.edge) {
            layout.updateInsertionOwed(layout: projected)
        }
        let liveIDs = Set(items.map(\.itemID))
        documentHeights = documentHeights.filter { liveIDs.contains($0.key) }
        hostedGeometryKeys = hostedGeometryKeys.filter { liveIDs.contains($0.key) }
        hostedFallbackFitWidths = hostedFallbackFitWidths.filter { liveIDs.contains($0.key) }
        hostedFallbackFirstSeenAt = hostedFallbackFirstSeenAt.filter { liveIDs.contains($0.key) }
        pendingHostedReports = pendingHostedReports.filter { liveIDs.contains($0.key) }

        var snapshot = NSDiffableDataSourceSnapshot<TimelineCollectionSection, TimelineListItem>()
        snapshot.appendSections([.main])
        snapshot.appendItems(items)
        let existingChanges = items.filter { oldIDs.contains($0) && reconfigure.contains($0) }
        if !existingChanges.isEmpty { snapshot.reconfigureItems(existingChanges) }
        // The height a row displayed under the content this apply replaces. A
        // cell fit equal to it is the previous content, not the new height:
        // the hosting body updates on a later layout pass.
        var staleFits: [String: CGFloat] = [:]
        for item in existingChanges where changed.contains(item) {
            if let height = beforeHeights[item.itemID] { staleFits[item.itemID] = height }
        }
        currentItems = items
        dataSource.apply(snapshot, animatingDifferences: animating) { [weak self] in
            guard let self else { return }
#if AA_TIMELINE_PROBE
            TimelineProbeStore.shared.noteApplyDuration(CACurrentMediaTime() - probeApplyStart)
#endif
            self.isPerformingSnapshot = false
#if AA_TIMELINE_PROBE
            let probeOffsetAfter = self.collectionView.contentOffset.y
            let probeAnchorYAfter = probeAnchorID
                .flatMap { self.layout.attributes(for: $0) }
                .map { $0.frame.minY - probeOffsetAfter } ?? -1
            TimelineProbeStore.shared.noteHistory(
                "apply-end applying=\(applyingHistoryPage ? 1 : 0) "
                + "off=\(probeOffsetBefore)->\(probeOffsetAfter) "
                + "d=\(probeOffsetAfter - probeOffsetBefore) "
                + "anchor=\(probeAnchorID ?? "-") anchorY=\(probeAnchorYBefore)->\(probeAnchorYAfter) "
                + "contentH=\(self.layout.contentHeight)")
#endif
            if resolveWindowBottom { self.resolveWindowReplacementBottom() }
            self.onApplyCompleted?()
            self.schedulePendingMeasurements()
            // A reconfigured interactive row (fold, notice) changes height in
            // SwiftUI after the apply; the single visible-cell pass can see
            // the old content, stop early, and leave the row at its previous
            // height — the blank band under a collapsed tool. Poll the
            // reconfigured rows like the explicit reconfigure path does, on
            // the same one-turn deferral: the hosted body updates on the next
            // layout pass, and reading it inside this completion measures the
            // content the apply replaced.
            if let content = self.content {
                let interactive = existingChanges.filter {
                    content.heightPolicy(for: $0).acceptsPreferredHeight
                }
                if !interactive.isEmpty {
                    DispatchQueue.main.async { [weak self] in
                        // The local copy is this apply's truth; a queued next
                        // apply may have replaced the shared dictionary.
                        self?.applyPreferredHeights(for: interactive,
                                                    staleFits: staleFits,
                                                    beforeHeights: beforeHeights)
                    }
                }
            }
            self.scheduleVisibleCellSettle()
            self.scheduleVisibleCellFrameSync()
            if applyingHistoryPage {
                // Commit the page's layout before resolving the row: the old
                // anchor item has already left the window, and the new item's
                // frame only exists after this pass.
                self.collectionView.layoutIfNeeded()
                self.reanchorHistoryPageIfNeeded()
                self.anchorDriver?.enforceReadingPlacement()
                // The first pass can still park a correction; resolve once
                // more against the settled frames.
                self.collectionView.layoutIfNeeded()
                self.anchorDriver?.enforceReadingPlacement()
                self.endHistoryPaging()
                self.beginHistoryAnchorSettling()
            }
            self.publishViewport()
            if self.layout.insertionOwedIsSettled {
                self.insertionProjection = nil
            }
            self.performPendingSnapshotUpdate()
        }
    }

    /// Run the newest snapshot request once the in-flight one has finished.
    private func performPendingSnapshotUpdate() {
        guard let pending = pendingSnapshotUpdate else { return }
        pendingSnapshotUpdate = nil
        switch pending {
        case .apply(let items, let animating):
            apply(items: items, animating: animating)
        case .reconfigure(let items):
            reconfigure(items)
        }
    }

    /// Re-renders existing cells without touching signatures or measurement.
    /// This is the C3 gate's fold/tail path: the cell's preferred height is
    /// the correction signal, exactly as a disclosure toggle behaves.
    func reconfigure(_ items: [TimelineListItem]) {
        guard dataSource != nil else { return }
        guard !isPerformingSnapshot else {
            pendingSnapshotUpdate = .reconfigure(items: items)
            return
        }
        var snapshot = dataSource.snapshot()
        let present = items.filter { snapshot.itemIdentifiers.contains($0) }
        guard !present.isEmpty else { return }
        // Explicit reconfigure (a fold toggle, a notice card) changes the
        // hosted content without a signature change. Record the visible
        // heights so only these rows animate from where the reader saw them;
        // every other row's fit applies directly.
        var beforeHeights: [String: CGFloat] = [:]
        if let content {
            for item in present where content.heightPolicy(for: item) == .interactive {
                if let height = layout.attributes(for: item.itemID)?.frame.height {
                    beforeHeights[item.itemID] = height
                }
            }
        }
        let recordedAt = CACurrentMediaTime()
        previousInteractiveHeights = beforeHeights.mapValues {
            PreChangeHeight(height: $0, recordedAt: recordedAt)
        }
        // A reconfigure changes content (fold state, notice card), and the
        // content revision is part of the height key. Install the new key
        // before the snapshot applies: the settled fit this path reports
        // through `applyPreferredHeight` must land on the key the layout
        // carries, or the `staleKey` gate drops the row's only correction.
        if let content {
            for item in present {
                let key = content.heightKey(for: item, width: columnWidth)
                if layout.heights.currentKey(for: item.itemID) != key {
                    layout.heights.setCurrentKey(key)
                }
            }
        }
        isPerformingSnapshot = true
        snapshot.reconfigureItems(present)
        dataSource.apply(snapshot, animatingDifferences: false) { [weak self] in
            guard let self else { return }
            self.isPerformingSnapshot = false
            // The controlled-exception rows keep the legacy path and have no
            // heightDidChange channel; ask the visible rows for their fitting
            // height after the new content has laid out.
            DispatchQueue.main.async { [weak self] in
                self?.applyPreferredHeights(for: present, beforeHeights: beforeHeights)
            }
            self.performPendingSnapshotUpdate()
        }
    }

    /// An item whose identity changes when the timeline window is replaced.
    /// The prompts and the tail are fixed cases and survive every window.
    private static func isDynamicItem(_ item: TimelineListItem) -> Bool {
        switch item {
        case .group, .notice, .pending: return true
        case .olderPrompt, .latestPrompt, .workingStatus, .tail: return false
        }
    }

    /// The reveal's per-frame clamped height. `nil` means the reveal ended and
    /// the row returns to its measured height.
    private func streamingRevealFrame(_ height: CGFloat?, for item: TimelineListItem) {
        // A not-yet-laid-out block can report its origin; never collapse a row.
        if let height, height < 8 { return }
        let state = layoutInteractionState()
        // While the reader is pinned to the bottom the follower owns the
        // offset; the layout only invalidates the item height.
        // A programmatic return (pill/send/keyboard) owns the offset until
        // its animation ends; the reveal follower must not cancel it.
        let animating = phase.phase == .animating
        let following = height != nil
            && (anchorDriver?.state.placement == .end) && !animating
        if let height {
#if DEBUG
            debugStreamingFrameCalls += 1
            if following { debugStreamingFollowEligibleFrames += 1 }
#endif
            layout.applyStreamingHeight(height, for: item.itemID,
                                        adjustOffset: !(following || animating))
        } else {
            layout.clearStreamingHeight(for: item.itemID)
        }
    }

    private func resolveWindowReplacementBottom() {
        guard collectionView != nil, !navigationSuspended else { return }
        // A gesture that began after the request always wins.
        guard windowReplacementReturn,
              !phase.userIsScrolling,
              collectionView?.isTracking != true,
              collectionView?.isDecelerating != true else {
            windowReplacementReturn = false
            return
        }
        windowReplacementReturn = false
        anchorDriver?.windowReplaced(readerTookOver: false)
    }

    private func replayPendingGestureBottomRequest() {
        guard let request = pendingGestureBottomRequest else { return }
        guard !phase.userIsScrolling,
              !collectionView.isTracking,
              !collectionView.isDecelerating else { return }
        pendingGestureBottomRequest = nil
        requestBottom(animated: request.animated, forced: request.forced)
    }

    private func applyPreferredHeights(for items: [TimelineListItem],
                                       staleFits: [String: CGFloat] = [:],
                                       beforeHeights: [String: CGFloat] = [:]) {
        settlePreferredHeights(for: items, attempt: 0, staleFits: staleFits,
                               beforeHeights: beforeHeights)
    }

    /// The hosting content of a reconfigured exception row updates on a later
    /// layout pass. The first gate run read the old collapsed fitting height
    /// (248.7) while the content had already expanded (404.3); a single
    /// immediate read is racy. Poll the cell's content fitting for a few
    /// frames and apply when it changes. This is the legacy path for the
    /// exception rows, which have no `heightDidChange` channel.
    private(set) var preferredDiagnostics: [String: Int] = [:]
#if DEBUG
    /// The last few fitting requests of the legacy exception path, for the gate.
    private(set) var debugPreferredFitProbe: [String] = []
#endif

    private func notePreferred(_ key: String) {
        preferredDiagnostics[key, default: 0] += 1
    }

    private static let rowHeightAnimationDuration: TimeInterval = 0.18
    /// How long a pre-change height may still start an animation. The apply's
    /// own settle window is under 0.5 s; a record older than this is a stale
    /// measurement, not a content change the reader is watching.
    private static let preChangeRecordLifetime: TimeInterval = 1.0

    /// One host-driven row-height animation. A custom layout cannot rely on
    /// `UIView.animate` to move cell frames, so a display link walks the
    /// height from the current frame to the measured target and the layout's
    /// display override repositions the cells each frame.
    private struct RowHeightAnimation {
        let item: TimelineListItem
        let key: TimelineHeightKey
        let from: CGFloat
        let to: CGFloat
        let start: TimeInterval
        let duration: TimeInterval
    }
    private var rowHeightAnimations: [ObjectIdentifier: (RowHeightAnimation, CADisplayLink)] = [:]
    #if DEBUG
    private(set) var debugRowHeightAnimationsStarted = 0
    var debugActiveRowHeightAnimations: Int { rowHeightAnimations.count }
    #endif
    /// A pre-change height recorded by the apply that is about to change a
    /// row's content. The timestamp bounds its lifetime: a scroll-driven
    /// first measurement a second later must not animate from it.
    private struct PreChangeHeight {
        let height: CGFloat
        let recordedAt: TimeInterval
    }

    /// Displayed heights of the rows whose content changed in the latest
    /// apply, so a fold animation starts where the reader saw the row. The
    /// apply-completion settle gets its own copy passed in: a queued next
    /// apply must not overwrite the records its predecessor still needs.
    private var previousInteractiveHeights: [String: PreChangeHeight] = [:]

    private func animateRowHeight(to target: CGFloat, for item: TimelineListItem,
                                  key: TimelineHeightKey, from: CGFloat) {
        stopRowHeightAnimation(for: item.itemID)
        guard abs(target - from) >= 1 else {
            layout.applyMeasuredHeight(target, for: item.itemID, key: key)
            layout.clearStreamingHeight(for: item.itemID)
            return
        }
        // Pin the display to the old height first; the layout may already
        // carry the fitted one.
        layout.applyStreamingHeight(from, for: item.itemID)
        let animation = RowHeightAnimation(item: item, key: key, from: from,
                                           to: target,
                                           start: CACurrentMediaTime(),
                                           duration: Self.rowHeightAnimationDuration)
        #if DEBUG
        debugRowHeightAnimationsStarted += 1
        #endif
        let link = CADisplayLink(target: self, selector: #selector(stepRowHeight(_:)))
        link.add(to: .main, forMode: .common)
        rowHeightAnimations[ObjectIdentifier(link)] = (animation, link)
    }

    func isAnimatingRowHeight(_ itemID: String) -> Bool {
        rowHeightAnimations.values.contains { $0.0.item.itemID == itemID }
    }

    private func stopRowHeightAnimation(for itemID: String) {
        for (id, entry) in rowHeightAnimations where entry.0.item.itemID == itemID {
            entry.1.invalidate()
            rowHeightAnimations.removeValue(forKey: id)
        }
    }

    @objc private func stepRowHeight(_ link: CADisplayLink) {
        guard let entry = rowHeightAnimations[ObjectIdentifier(link)] else {
            link.invalidate()
            return
        }
        let (animation, _) = entry
        let progress = min(1, max(0, (CACurrentMediaTime() - animation.start) / animation.duration))
        // Smoothstep, the same shape as ease-in-out.
        let eased = progress * progress * (3 - 2 * progress)
        let height = animation.from + (animation.to - animation.from) * eased
        if progress >= 1 {
            link.invalidate()
            rowHeightAnimations.removeValue(forKey: ObjectIdentifier(link))
            // The animation's final frame is already on screen. Committing it
            // keeps the row at this height when the display override is
            // cleared right after; parking it under the finger would collapse
            // the row to the pre-animation height.
            layout.applyMeasuredHeight(animation.to, for: animation.item.itemID,
                                       key: animation.key, commit: true)
            layout.clearStreamingHeight(for: animation.item.itemID)
        } else {
            layout.applyStreamingHeight(height, for: animation.item.itemID)
        }
    }

    private func settlePreferredHeights(for items: [TimelineListItem], attempt: Int,
                                        staleFits: [String: CGFloat],
                                        beforeHeights: [String: CGFloat]) {
        guard let content, attempt <= 9 else { return }
        // Same reason as the visible-cell settle: no layout work under the
        // finger; the scroll-end settle takes over. `isUserScrolling` also
        // covers the gate's test gesture, which has no native tracking.
        if isUserScrolling {
            return
        }
        notePreferred("pass")
        for item in items {
            notePreferred("item")
            // The official contract rows report their own height changes; the
            // controller's polling path must not race that write.
            guard !content.usesCellReportedHeight(for: item) else {
                notePreferred("cellReported"); continue
            }
            guard content.heightPolicy(for: item).acceptsPreferredHeight else {
                notePreferred("notInteractive"); continue
            }
            if isAnimatingRowHeight(item.itemID) { continue }
            guard let indexPath = indexPath(for: item) else {
                notePreferred("noIndexPath"); continue
            }
            guard let cell = collectionView.cellForItem(at: indexPath) else {
                notePreferred("noCell"); continue
            }
            let width = cell.contentView.bounds.width
            guard width > 0 else { notePreferred("zeroWidth"); continue }
            let fitting = cell.contentView.systemLayoutSizeFitting(
                CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
                withHorizontalFittingPriority: .required,
                verticalFittingPriority: .fittingSizeLevel).height
            guard fitting > 0 else { notePreferred("zeroFitting"); continue }
            // Right after a content change the cell still hosts the previous
            // body; a fit that is exactly the height that body displayed is
            // that stale read, not the new height. Ignore it for the first
            // few passes and later take whatever the cell reports, so a row
            // that genuinely keeps its height cannot get stuck here.
            if attempt <= 6, let stale = staleFits[item.itemID],
               abs(fitting - stale) <= 0.5 {
                notePreferred("staleFit"); continue
            }
            let current = layout.attributes(for: item.itemID)?.frame.height ?? 0
            // Compare the height this pass would apply, not the raw fit: a
            // 16.33 pt fit rounds to the 17 pt frame, and comparing the raw
            // value kept requesting an apply that `applyPreferredHeight`
            // then rejected as "no delta" on every pass.
            let target = ceil(fitting)
            if abs(target - current) > 0.5 {
                notePreferred("applyRequested")
                let policy = content.heightPolicy(for: item)
#if DEBUG
                debugPreferredFitProbe.append("fit=\(fitting) target=\(target)"
                    + " current=\(current)")
                if debugPreferredFitProbe.count > 12 { debugPreferredFitProbe.removeFirst() }
#endif
#if AA_TIMELINE_PROBE
                TimelineProbeStore.shared.noteHeightChange(
                    itemID: item.itemID, item: item, old: current, new: target,
                    source: "preferredFit")
#endif
                if policy == .interactive,
                   let before = beforeHeights[item.itemID],
                   abs(target - before) >= 8 {
                    animateRowHeight(to: target, for: item,
                                     key: content.heightKey(for: item, width: columnWidth),
                                     from: before)
                } else {
                    layout.applyPreferredHeight(
                        target, for: item.itemID,
                        key: content.heightKey(for: item, width: columnWidth))
                    // The controller owns this correction path; force the
                    // layout pass so the new value is observable in the same
                    // turn.
                    collectionView.layoutIfNeeded()
                }
            } else {
                notePreferred("alreadyEqual")
            }
        }
        // Poll several frames: the hosting content can report its old size on
        // the first pass and the new size only after SwiftUI lays out.
        guard attempt < 9 else {
            // The correction window is over. Drop only this pass's records;
            // a queued apply may already have stored a newer height for the
            // same item, and that one belongs to its own settle.
            for (id, height) in beforeHeights
            where previousInteractiveHeights[id]?.height == height {
                previousInteractiveHeights.removeValue(forKey: id)
            }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.settlePreferredHeights(for: items, attempt: attempt + 1,
                                         staleFits: staleFits,
                                         beforeHeights: beforeHeights)
        }
    }

    /// No legitimate timeline row is shorter than a text line. A value below
    /// this is the hosting probe or a pre-parse stack spacing, never a row.
    private static let minimumPlausibleHeight: CGFloat = 8
    private static let pendingMeasurementAttempts = 6
    private static let pendingMeasurementInterval = Duration.milliseconds(150)
    /// Rows farther than this above the viewport are left on their estimates.
    /// A history page inserts hundreds of unmeasured rows above the reading
    /// anchor; measuring each one offscreen rewrites the page's total height
    /// (one full layout pass per row) although none of them can be seen. The
    /// official transcript keeps such rows guessed until they enter the
    /// window. When the reader scrolls up, the drag-end pass measures the
    /// rows that came within this margin.
    private static let pendingMeasurementPrefetchMargin: CGFloat = 600
    /// Visible-cell settle passes. Textual parses Markdown off the main actor,
    /// so the cell's real height can arrive well after the first layout. The
    /// later passes cover a long reply on a busy main thread; a later scroll
    /// or `willDisplay` starts a fresh set if the content is still not parsed.
    /// Seconds, so a settle request can wake the ladder early without
    /// consuming the slot.
    private static let visibleCellSettleDelays: [TimeInterval] = [
        0, 0.08, 0.16, 0.32, 0.64, 1.2, 2, 3, 5,
        // One extra slot: a hosted row first seen in the last regular slot
        // still owes its one fallback fit one layout opportunity later.
        0.08
    ]

    private func validatedHeight(_ height: CGFloat?, minimum: CGFloat = 0) -> CGFloat? {
        guard let height, height.isFinite else { return nil }
        let floor = max(Self.minimumPlausibleHeight, minimum)
        guard height >= floor else { return nil }
        return ceil(height)
    }

    /// A fitting height far below the content-aware estimate is a pre-parse
    /// stack spacing, not a row. 20% leaves room for an over-estimating text
    /// model while rejecting the 2–20pt placeholders a multi-row VStack
    /// reports before Textual parses its Markdown.
    private func plausibleFloor(for item: TimelineListItem) -> CGFloat {
        guard let content else { return Self.minimumPlausibleHeight }
        return max(Self.minimumPlausibleHeight, content.estimateKind(for: item).height * 0.2)
    }

    private func measureSynchronously(_ items: [TimelineListItem], width: CGFloat) {
        guard let content, width > 0 else { return }

        // C5/M2: the assistant body is measured by the engine that renders it.
        // The cell only exists for items that got a real height here, so the
        // row never pairs a TextKit cell with an estimate.
        for item in items {
            // A pending row's height is a structured estimate, not a cell
            // fit. Its delivery transition can replace a file grid with a
            // failed card, so the new key must outrank the height the row is
            // currently displaying: `resolvedHeight` only prefers
            // measured/precalc tiers over an ever-displayed row's old height,
            // and an estimate alone would be ignored. Write the adapter's
            // pending estimate as a pre-calc for the new key (the pending row
            // has no cell self-measure to report one).
            if case .pending = item {
                let key = content.heightKey(for: item, width: width)
                // The precalc tier normally means a plain-text pre-calculation;
                // here it carries the pending row's structured estimate so it
                // outranks the ever-displayed height. Do not pin the generic
                // `.row` fallback: a pending record with no text and no
                // attachments (only reachable through an archive-restore
                // race) has no structured height to offer.
                if case let .fixed(height) = content.estimateKind(for: item),
                   !layout.heights.hasMeasuredOrPrecalcHeight(for: key) {
                    layout.heights.set(height, for: key, tier: .precalc)
                }
                documentHeights.removeValue(forKey: item.itemID)
                continue
            }
            // Official hosted-cell contract rows measure themselves once when
            // the cell materializes and report later changes through
            // `heightDidChange`; the controller must not mark them measured.
            // A never-displayed row may get a structured provisional for the
            // frames before that materialization; the provisional is not a
            // measurement, so the cell's self-measure still owns the final
            // height.
            if content.usesCellReportedHeight(for: item) {
                // A structured pre-apply value is only a placeholder for a row
                // the reader has never seen. For a displayed row it would
                // replace the height under the finger (the device report's
                // 1557.7 -> 56); that row keeps its displayed height until the
                // cell reports. Writing it under a gesture is safe here
                // because a never-displayed row is not on screen yet.
                let key = content.heightKey(for: item, width: width)
                if !layout.heights.hasEverBeenDisplayed(item.itemID) {
                    if let provisional = content.measuredCodeGroupHeight(for: item, width: width) {
                        layout.heights.set(provisional, for: key, tier: .provisional)
                    } else if let estimate = content.officialEstimateHeight(for: item, width: width) {
                        // No structural height yet (streaming/unparsed): the
                        // official line-count estimate replaces the layout's
                        // coarse `.row` 200 fallback for the frames before the
                        // cell's first fit.
                        layout.heights.set(estimate, for: key, tier: .estimate)
                    }
                }
                continue
            }
            // The Code page renders every message with its own row view, so
            // the TextKit branches below never see it. Measure the group from
            // the same parts the row draws, before the snapshot applies: a
            // settled row must never correct its height while the reader is
            // looking at it (device report 2026-10-23).
            if let exact = content.measuredCodeGroupHeight(for: item, width: width) {
                let key = content.heightKey(for: item, width: width)
                layout.heights.set(exact, for: key, tier: .measured)
                documentHeights.removeValue(forKey: item.itemID)
                continue
            }
            // C5/M4: the streaming row is measured by the same engine that
            // renders its settled blocks. The tail view is constrained to the
            // remainder, so the stored height is exact instead of an estimate.
            if let streaming = content.assistantStreamingDocument(for: item) {
                let key = content.heightKey(for: item, width: width)
                if layout.heights.hasMeasuredOrPrecalcHeight(for: key),
                   let cached = layout.heights.tieredHeight(for: key) {
                    documentHeights[item.itemID] = cached
                    continue
                }
                let raw = AssistantMarkdownTextLayout.measure(
                    streaming.document, width: width,
                    displayScale: traitCollection.displayScale)
                guard let height = validatedHeight(raw) else {
                    // A correction/recovery can briefly parse to an empty
                    // document. Drop the old height with the old document, or
                    // the data source would pair a TextKit cell with a stale
                    // frame that the visible-cell settle can never correct.
                    documentHeights.removeValue(forKey: item.itemID)
                    continue
                }
                layout.heights.set(height, for: key, tier: .measured)
                documentHeights[item.itemID] = height
                continue
            }
            guard let document = content.assistantMarkdown(for: item) else {
                // The row may have been a document on an earlier pass and lost
                // eligibility (streaming started, an attachment arrived, or a
                // file-change footer appeared). A stale entry here would make
                // the hosting path skip its own measurement.
                documentHeights.removeValue(forKey: item.itemID)
                continue
            }
            // A row that just handed over from the reveal must take the
            // measured static height in this same apply; the display override
            // from the streaming cell would otherwise win the first prepare.
            layout.discardStreamingHeight(for: item.itemID)
            let footerHeight = content.assistantFooter(for: item).map {
                AssistantFooterMetrics.groupSpacing + $0.height
            } ?? 0
            let key = content.heightKey(for: item, width: width)
            if layout.heights.hasMeasuredOrPrecalcHeight(for: key),
               let cached = layout.heights.tieredHeight(for: key) {
                documentHeights[item.itemID] = cached
                continue
            }
            let raw = AssistantMarkdownTextLayout.measure(
                document, width: width, displayScale: traitCollection.displayScale)
                + footerHeight
            guard let height = validatedHeight(raw) else { continue }
            layout.heights.set(height, for: key, tier: .measured)
            documentHeights[item.itemID] = height
        }

        guard let measurer else { return }
        // A typography change re-keys every row in the same SwiftUI update that
        // calls this measurement, before the next layout pass. Sync the
        // measurer's traits now, or the new key caches an old-type height.
        if let hosted = measurer as? TimelineHostingHeightMeasurer {
            hosted.updateTraitOverrides(from: traitCollection)
        }
        let requests = items.compactMap { item -> TimelineMeasurementRequest? in
            // Already measured by TextKit 2 above.
            guard content.assistantMarkdown(for: item) == nil else { return nil }
            // Only plain text fits the synchronous offscreen pass. Textual
            // parses Markdown in a task that a hostless controller never runs
            // (the long-Markdown gate measured 2pt for 1471pt of content), so
            // a hosting pass for those rows is both wrong and wasted main
            // thread work. Their estimate stands until the visible cell fits.
            guard content.measurementContent(for: item) == .plainText else { return nil }
            let key = content.heightKey(for: item, width: width)
            guard !layout.heights.hasMeasuredOrPrecalcHeight(for: key) else { return nil }
            return TimelineMeasurementRequest(itemID: item.itemID, key: key,
                content: content.measurementContent(for: item),
                isStreaming: streamingItemIDs.contains(item.itemID),
                estimatedCostMilliseconds: 0)
        }
        guard !requests.isEmpty else { return }
        let plan = measurementPipeline.plan(requests)
        for request in plan.measureBeforeApply {
            // Async Markdown answers an offscreen pass with its pre-parse
            // stack spacing (measured 2.0pt for a 1471pt group). Never write
            // that as a row height; the estimate stands until the visible
            // cell reports its real fitting height.
            guard let raw = measurer.measure(itemID: request.itemID, width: width),
                  let height = validatedHeight(raw) else { continue }
            layout.heights.set(height, for: request.key, tier: .measured)
        }
    }

    private func schedulePendingMeasurements() {
        pendingMeasurementTask?.cancel()
        let pending = layout.pendingMeasurements
        guard !pending.isEmpty, columnWidth > 0 else { return }
        let width = columnWidth
        let viewportTop = viewport.offsetY + viewport.topInset
        // A history page's whole new prefix sits above the reading anchor.
        // Skip every row that is entirely above the viewport for that pass;
        // the prefetch margin applies to ordinary settles, where measuring a
        // row just above the top keeps the next scroll smooth.
        let prefetchMargin = historyPaging
            ? 0
            : max(Self.pendingMeasurementPrefetchMargin, viewport.visibleHeight * 1.5)
        let skipAbove = viewportTop - prefetchMargin
        pendingMeasurementTask = Task { @MainActor [weak self] in
#if AA_TIMELINE_PROBE
            let probeStart = CACurrentMediaTime()
            var probeMeasured = 0
            var probeSkipped = 0
            var probeScrolled = 0
            TimelineProbeStore.shared.noteHistory("pending-measure start n=\(pending.count)")
            defer {
                TimelineProbeStore.shared.noteHistory(
                    "pending-measure end n=\(pending.count) measured=\(probeMeasured) "
                    + "skipped=\(probeSkipped) scrolled=\(probeScrolled) "
                    + "ms=\(Int(((CACurrentMediaTime() - probeStart) * 1000).rounded()))")
            }
#endif
            if let self, let hosted = self.measurer as? TimelineHostingHeightMeasurer {
                hosted.updateTraitOverrides(from: self.traitCollection)
            }
            for item in pending {
                guard let self, !Task.isCancelled, self.currentItems.contains(item) else { return }
                guard let content = self.content else { return }
                // A page inserted above the reader leaves hundreds of rows
                // unmeasured. Measuring them offscreen is invisible work and
                // moves the page's estimated height one row at a time.
                if let attributes = self.layout.attributes(for: item.itemID),
                   attributes.frame.maxY < skipAbove {
#if AA_TIMELINE_PROBE
                    probeSkipped += 1
#endif
                    continue
                }
                // Hosted-contract rows are measured by their cell the first
                // time it materializes; there is nothing to do offscreen.
                if content.usesCellReportedHeight(for: item) {
#if AA_TIMELINE_PROBE
                    probeSkipped += 1
#endif
                    continue
                }
                // Parsing Markdown is main-thread work. A pending Code group
                // measured under a drag is the scroll jank the device reported
                // on 2026-10-23; the scroll-end callbacks start a fresh pass.
                if self.collectionView.isTracking || self.collectionView.isDecelerating {
#if AA_TIMELINE_PROBE
                    probeScrolled += 1
#endif
                    return
                }
                // A Code group's height comes from its own structural
                // measurement. A width or typography change re-keys it without
                // an apply that would carry the new measurement; settle it
                // here instead of leaving it on an estimate until the cell is
                // first seen.
                if let exact = content.measuredCodeGroupHeight(for: item, width: width) {
                    self.measurementPipeline.complete(item.itemID)
                    self.layout.applyMeasuredHeight(
                        exact, for: item.itemID,
                        key: content.heightKey(for: item, width: width))
#if AA_TIMELINE_PROBE
                    probeMeasured += 1
#endif
                    // One row per runloop turn; the next parse must not stack
                    // behind this one inside a single frame.
                    await Task.yield()
                    continue
                }
                // Async Markdown is settled by the visible cell, not by this
                // hostless loop; retrying an offscreen pass would only burn
                // main-thread layout for the same 2pt answer.
                guard content.measurementContent(for: item) == .plainText else {
#if AA_TIMELINE_PROBE
                    probeSkipped += 1
#endif
                    continue
                }
                let key = content.heightKey(for: item, width: width)
                // Retry briefly; a visible cell's async Markdown is settled by
                // the visible-cell passes instead of this offscreen loop.
                for attempt in 0..<Self.pendingMeasurementAttempts {
                    if let height = self.measuredHeight(for: item, width: width) {
                        self.measurementPipeline.complete(item.itemID)
                        self.layout.applyMeasuredHeight(height, for: item.itemID, key: key)
#if AA_TIMELINE_PROBE
                        probeMeasured += 1
#endif
                        break
                    }
                    if attempt < Self.pendingMeasurementAttempts - 1 {
                        try? await Task.sleep(for: Self.pendingMeasurementInterval)
                    }
                    if Task.isCancelled { return }
                }
                await Task.yield()
            }
        }
    }

    /// The visible cell is the only exact source for async content: Textual
    /// parses in a task an offscreen hosting controller never runs, so the
    /// offscreen pass sees only stack spacing. The official transcript's
    /// `ClaudeTranscriptUI.TranscriptCellHost.heightDidChange` reports the
    /// cell's real height; for the legacy (non-contract) rows AA polls the
    /// same `systemLayoutSizeFitting` the integration gate uses as its cell
    /// sample.
    private func measuredHeight(for item: TimelineListItem, width: CGFloat) -> CGFloat? {
        if let height = visibleCellFit(for: item) { return height }
        guard let measurer else { return nil }
        return validatedHeight(measurer.measure(itemID: item.itemID, width: width))
    }

    private func visibleCellFit(for item: TimelineListItem) -> CGFloat? {
        guard !navigationSuspended, let indexPath = indexPath(for: item),
              let cell = collectionView.cellForItem(at: indexPath) else { return nil }
        return cellFit(cell, minimum: plausibleFloor(for: item))
    }

    private func cellFit(_ cell: UICollectionViewCell, minimum: CGFloat = 0) -> CGFloat? {
        let width = cell.contentView.bounds.width
        guard width > 0 else { return nil }
        let height = cell.contentView.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel).height
        return validatedHeight(height, minimum: minimum)
    }

    /// The synchronously measured height of an M2 TextKit 2 row, or nil when
    /// the row is on the hosting path. The gate reads this to prove the first
    /// stored height is the measurement, not the estimate.
    func measuredTextKitHeight(for item: TimelineListItem) -> CGFloat? {
        documentHeights[item.itemID]
    }

    /// Re-measures one row on demand (the gate's async-Markdown settle step).
    func remeasure(_ item: TimelineListItem) {
        // A TextKit 2 row was measured before apply by the engine that renders
        // it; the visible-cell fit must not replace that measurement.
        guard documentHeights[item.itemID] == nil else { return }
        guard let content, columnWidth > 0 else { return }
        let width = columnWidth
        let key = content.heightKey(for: item, width: width)
        guard let height = measuredHeight(for: item, width: width) else { return }
        measurementPipeline.complete(item.itemID)
        layout.applyMeasuredHeight(height, for: item.itemID, key: key)
    }

    /// The official `rowMeasured` path: the hosting geometry value is the
    /// measurement, not a trigger. `_GeometryActionModifier`'s action reads
    /// `GeometryProxy.size.height` (`0x100b7d97c` / `0x100d540ac`), adds the
    /// row's vertical margins (`0x1019edf08` → `0x1019ece34`) and the surface
    /// accepts it only when it differs (`0x101a4081c fcmp; cset ne`), writing
    /// it inside `UIView.performWithoutAnimation` (`0x101a3b660`).
    /// `CANONICAL/05-layout-scroll.md` §2.2 steps 4–5.
    private func hostedContentHeightReported(_ height: CGFloat, for item: TimelineListItem,
                                             reportedKey: TimelineHeightKey,
                                             reportedSignature: TimelineContentSignature) {
        guard let content, !navigationSuspended, columnWidth > 0,
              height.isFinite, height > 0 else { return }
        guard let current = layout.heights.currentKey(for: item.itemID) else { return }
        // The cell's body belongs to the configuration that captured
        // `reportedKey`. A different current key normally means an apply
        // installed a new content revision and this cell still shows the
        // retired body; its geometry must not be written under the new
        // revision. The exception is a width/split-view/Dynamic-Type change,
        // which re-keys every row in `prepare` (official 0x101a3ff20) without
        // reconfiguring the cell: accept it only when the content signature
        // proves the body did not change. (Code `contentRevision` folds the
        // width into its digest, so it cannot be compared across a width
        // change — `TimelineChatContentAdapter.codeHeightDigest`.)
        let dimensionOnlyRekey = current.itemID == reportedKey.itemID
            && (current.width != reportedKey.width
                || current.dynamicType != reportedKey.dynamicType
                || current.typographyRevision != reportedKey.typographyRevision
                || current.layoutDirection != reportedKey.layoutDirection)
        guard current == reportedKey
            || (dimensionOnlyRekey && content.contentSignature(for: item) == reportedSignature)
        else { return }
        let key = current
        // Marked even when the value is unchanged: the geometry path reported
        // for this key, so the one-shot first-materialization fallback must
        // not fit the same row as well.
        hostedGeometryKeys[item.itemID] = key
        let driverMoving = anchorDriver?.state.motion == .easing
            || anchorDriver?.state.motion == .flying
        if driverMoving {
            // The programmatic-return spring owns the offset and re-reads the
            // live bottom every frame (`CANONICAL/05-layout-scroll.md` §6.4).
            // The height must land now — freezing it would freeze the target —
            // but it must not post an offset adjustment that fights the
            // spring. Official `rowMeasured` writes the height and lets the
            // Mover answer the placement. Cost: the official above-viewport
            // compensation (05 §2.2 step 6) is suppressed too, so content
            // above a growing row can shift for the duration of the return.
            pendingHostedReports[item.itemID] = nil
            applyHostedHeight(height, id: item.itemID, key: key,
                              suppressOffsetAdjustment: true)
            return
        }
        if phase.phase == .animating {
            // Another native animation (status-bar scroll-to-top) owns the
            // offset. Keep the newest report and let the animation-end settle
            // pass apply it.
            pendingHostedReports[item.itemID] = PendingHostedReport(key: key, height: height)
            return
        }
        // A newer direct report supersedes anything parked for this row: a
        // later flush of the older value would otherwise shrink the row back.
        pendingHostedReports[item.itemID] = nil
        applyHostedHeight(height, id: item.itemID, key: key)
    }

    /// Non-animated write for one geometry report. The changed-only decision
    /// lives in `TimelineListLayout.applyMeasuredHeight`: an equal value takes
    /// its `delta <= 0.5` branch, which latches `isMeasured` (official
    /// `0x1019e0b10` sets it unconditionally; only the `starts` prefix sum is
    /// conditional) without moving the offset or invalidating anything.
    /// Dropping the equal value here left a row that entered with a structural
    /// provisional at `tier=provisional` forever — the 461 device defect
    /// (`g:msg_e83b5b4b`, h=957) that `14ce7862` fixed.
    ///
    /// The layout's baseline is the height `prepare` resolved for the row
    /// (cache then displayed), not the raw attribute frame: an application can
    /// have written the cache before the next `prepare` rebuilt the frame, and
    /// comparing against the stale frame would post the same delta twice.
    private func applyHostedHeight(_ height: CGFloat, id: String, key: TimelineHeightKey,
                                   suppressOffsetAdjustment: Bool = false) {
        guard layout.heights.currentKey(for: id) == key else { return }
        UIView.performWithoutAnimation {
            layout.applyMeasuredHeight(
                height, for: id, key: key,
                suppressOffsetAdjustment: suppressOffsetAdjustment,
                probeSource: "rowMeasured")
        }
    }

    /// Applies the reports parked while a programmatic return owned the
    /// offset. Keys a later apply retired are dropped instead of being
    /// written under the new revision.
    private func applyPendingHostedReports() {
        guard !pendingHostedReports.isEmpty else { return }
        let reports = pendingHostedReports
        pendingHostedReports.removeAll()
        for (id, report) in reports {
            applyHostedHeight(report.height, id: id, key: report.key)
        }
    }

    /// Every visible legacy row may correct its height after the cell has
    /// rendered; this is their equivalent of the official cell's
    /// `heightDidChange`. The hosted-contract rows do not use this path: their
    /// geometry report is the measurement. Passes stop as soon as each visible
    /// cell's fitting height equals its frame; a pre-parse cell keeps them
    /// alive until the last pass.
    ///
    /// An apply must not restart the ladder. At the streaming frame rate the
    /// old unconditional restart cancelled the pass the previous apply had
    /// scheduled, so only the zero-delay pass ever ran and the later reads
    /// never happened (the two-pass confirmation could never be satisfied).
    /// A running ladder re-reads every visible cell each pass, which covers
    /// the content the apply introduced; a request that arrives between
    /// passes only wakes it early, it does not reset the schedule.
    private func scheduleVisibleCellSettle() {
        guard visibleCellSettleTask == nil else {
            visibleCellSettleNudged = true
            return
        }
        visibleCellSettleNudged = false
        visibleCellSettleGeneration &+= 1
        let generation = visibleCellSettleGeneration
        visibleCellSettleTask = Task { @MainActor [weak self] in
            defer { self?.clearVisibleCellSettleTask(generation: generation) }
            for delay in Self.visibleCellSettleDelays {
                guard let self, !Task.isCancelled else { return }
                // One wall-clock slot per scheduled pass. A settle request
                // inside the slot runs an extra pass but does NOT consume the
                // slot: at the streaming frame rate the old loop advanced one
                // delay per apply, so the 640 ms+ passes never survived a
                // burst.
                let slotEnd = CACurrentMediaTime() + delay
                while true {
                    guard !Task.isCancelled else { return }
                    guard await self.awaitSettleSlot(until: slotEnd) else { return }
                    guard self.visibleCellSettleGeneration == generation,
                          !self.navigationSuspended else { return }
                    // This pass consumes the wake signal; a request that
                    // arrives during the pass stays pending for the next one.
                    self.visibleCellSettleNudged = false
                    if !self.settleVisibleCellHeightsOnce() { return }
                    if CACurrentMediaTime() >= slotEnd { break }
                }
            }
        }
    }

    /// Waits for one ladder slot. Returns `false` when the task must stop;
    /// `true` when a pass may run — either the slot elapsed or a settle
    /// request woke the ladder for an early pass. Sliced so a request does not
    /// wait out a multi-second delay; the slices do no layout work.
    private func awaitSettleSlot(until end: TimeInterval) async -> Bool {
        let slice: TimeInterval = 0.02
        while true {
            if Task.isCancelled { return false }
            if visibleCellSettleNudged || navigationSuspended { return true }
            let remaining = end - CACurrentMediaTime()
            if remaining <= 0 { return true }
            try? await Task.sleep(for: .seconds(min(remaining, slice)))
        }
    }

    private func clearVisibleCellSettleTask(generation: Int) {
        guard visibleCellSettleGeneration == generation else { return }
        visibleCellSettleTask = nil
        // A request that arrived just as the ladder finished could not start
        // a new one while this task still occupied the slot. Hand it over
        // instead of dropping the pass.
        if visibleCellSettleNudged, !navigationSuspended {
            scheduleVisibleCellSettle()
        }
    }

    /// Returns false when every visible cell already matches its frame, so
    /// the caller can stop. A visible cell whose Markdown has not parsed yet
    /// (no plausible fitting height) keeps the passes alive.
    private func settleVisibleCellHeightsOnce() -> Bool {
        // A programmatic return owns the offset until it lands. Applying a
        // row correction inside that animation would add a second offset
        // change; the animation-end callback starts a fresh settle instead,
        // which also flushes the geometry reports parked meanwhile.
        guard phase.phase != .animating else { return false }
        guard let content, !navigationSuspended, columnWidth > 0,
              !collectionView.indexPathsForVisibleItems.isEmpty else { return false }
        applyPendingHostedReports()
        // The official `rowMeasured` write has no proven finger gate
        // (`0x1019e0b10`; `EVIDENCE/round19/streaming.md` §1.5): hosted growth
        // lands during a drag/deceleration through
        // `hostedContentHeightReported` when it cannot move content above the
        // row; growth entirely above the viewport parks for the drag-end
        // correction. This legacy polling pass would have to fit every visible
        // cell to see anything else, which is the device's 2026-10-23 scroll
        // stutter, and a shrink is parked until the gesture ends anyway. Keep
        // the passes alive and do no fitting under the finger.
        // `isUserScrolling` also covers the gate's test gesture, which has no
        // native tracking.
        let browsing = isUserScrolling
        var needsMore = false
        for indexPath in collectionView.indexPathsForVisibleItems.sorted() {
            guard currentItems.indices.contains(indexPath.item),
                  let cell = collectionView.cellForItem(at: indexPath) else { continue }
            let item = currentItems[indexPath.item]
            if content.usesCellReportedHeight(for: item) {
                // The hosting geometry value is the measurement
                // (`CANONICAL/05-layout-scroll.md` §2.2). Its changed-only
                // write happens in `hostedContentHeightReported`; this pass
                // keeps only the one-shot first-materialization fallback for
                // a cell whose SwiftUI content has not completed a layout
                // pass, so no geometry arrived yet.
                if browsing { needsMore = true; continue }
                // Official 0x101a39244: the cell self-measures only while
                // `isMeasured == false`, once per width. Check the item-level
                // flag before building the key: a Code key hashes the whole
                // streaming text, and a measured row must not pay that on
                // every settle pass.
                if layout.heights.isMeasured(itemID: item.itemID, width: columnWidth) {
                    continue
                }
                let key = content.heightKey(for: item, width: columnWidth)
                if hostedGeometryKeys[item.itemID] == key { continue }
                if hostedFallbackFitWidths[item.itemID] == key.width { continue }
                // Wait for one more layout opportunity before the single
                // fallback fit: the first pass after configuration can still
                // read the pre-layout skeleton (458 probe: 598 → 54 → 598),
                // and unlike the old two-pass confirmation there is no second
                // fit to reject that value.
                let now = CACurrentMediaTime()
                if let firstSeen = hostedFallbackFirstSeenAt[item.itemID] {
                    guard now - firstSeen >= 0.05 else {
                        needsMore = true
                        continue
                    }
                } else {
                    hostedFallbackFirstSeenAt[item.itemID] = now
                    needsMore = true
                    continue
                }
                // No estimate floor: a genuinely short row (a collapsed tool
                // header) is legitimate.
                guard let height = cellFit(cell) else {
                    needsMore = true
                    continue
                }
                // The fit lays out the hosting subtree; a geometry action can
                // have landed a fresher, content-derived value while it ran.
                // Never overwrite that with a possibly pre-layout fit.
                if layout.heights.isMeasured(itemID: item.itemID, width: key.width)
                    || hostedGeometryKeys[item.itemID] == key {
                    continue
                }
                hostedFallbackFitWidths[item.itemID] = key.width
                // Even a fit equal to the current height is a measurement:
                // `applyMeasuredHeight`'s delta<=0.5 branch latches
                // `isMeasured` (official 0x1019e0ba0).
                layout.applyMeasuredHeight(height, for: item.itemID, key: key,
                                           probeSource: "cellFit")
                needsMore = true
                continue
            }
            // A streaming row's visible height is the reveal override; the
            // stored measurement must not chase it frame by frame.
            if layout.hasStreamingHeight(for: item.itemID) { continue }
            if browsing { needsMore = true; continue }
            // TextKit 2 rows were measured before apply with the same engine
            // the cell renders; the visible-fit loop must not second-guess it.
            if documentHeights[item.itemID] != nil { continue }
            // Leave a row that is mid-animation alone: re-fitting it would
            // restart the animation from its current frame and stretch it.
            if isAnimatingRowHeight(item.itemID) { continue }
            guard let height = cellFit(cell, minimum: plausibleFloor(for: item)) else {
                // Pre-parse stack spacing or a probe: wait for the async content.
                needsMore = true
                continue
            }
            let key = content.heightKey(for: item, width: columnWidth)
            let current = layout.attributes(for: item.itemID)?.frame.height ?? 0
            guard abs(height - current) > 0.5 else { continue }
            measurementPipeline.complete(item.itemID)
            let policy = content.heightPolicy(for: item)
            // UIKit may already have adopted the fitted height during the
            // update; decide from the height the reader last saw. The record
            // expires: a scroll-driven first measurement later must not
            // animate from a content change the reader never saw move.
            let before = previousInteractiveHeights[item.itemID]
            let fresh = before.map {
                CACurrentMediaTime() - $0.recordedAt <= Self.preChangeRecordLifetime
            } ?? false
#if AA_TIMELINE_PROBE
            TimelineProbeStore.shared.noteHeightChange(
                itemID: item.itemID, item: item, old: current, new: height,
                source: "visibleFit")
#endif
            if policy == .interactive, let before, fresh,
               abs(height - before.height) >= 8 {
                // UIKit does not animate frames set through a custom layout's
                // invalidation; drive the height per frame instead.
                animateRowHeight(to: height, for: item, key: key, from: before.height)
            } else {
                layout.applyMeasuredHeight(height, for: item.itemID, key: key)
            }
            needsMore = true
        }
        return needsMore
    }

    // MARK: - Visible cell frame sync

    /// The layout invalidates the changed row and every visible row below it,
    /// but a path that moves rows without that context — a cleared streaming
    /// override, a window-prefix change — can leave a cell at its previous
    /// frame. The reader sees the cells overlap and the text draw over itself
    /// (device probe 2026-10-23: seven samples, 42 pt overlap).
    ///
    /// One visible-only check after each settled layout pass closes that gap.
    /// It never runs during a drag and only names cells that disagree with the
    /// layout's own attributes, so a converged list costs one comparison per
    /// visible row.
    private func scheduleVisibleCellFrameSync(delay: TimeInterval = 0.05) {
        guard !cellFrameSyncScheduled else { return }
        cellFrameSyncScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.cellFrameSyncScheduled = false
            self.syncVisibleCellFrames()
        }
    }

    private func syncVisibleCellFrames() {
        guard isViewLoaded, !navigationSuspended, !isPerformingSnapshot,
              phase.phase != .animating, !collectionView.isTracking,
              !collectionView.isDecelerating else { return }
        var stale: [IndexPath] = []
        for indexPath in collectionView.indexPathsForVisibleItems {
            // Hosted-contract rows invalidate their own row and the rows below
            // when a height lands; a frame-sync pass here would race it.
            guard currentItems.indices.contains(indexPath.item) else { continue }
            if let content,
               content.usesCellReportedHeight(for: currentItems[indexPath.item]) { continue }
            guard let cell = collectionView.cellForItem(at: indexPath),
                  let attributes = layout.layoutAttributesForItem(at: indexPath) else { continue }
            if abs(cell.frame.minY - attributes.frame.minY) > 0.5
                || abs(cell.frame.height - attributes.frame.height) > 0.5 {
                stale.append(indexPath)
            }
        }
        guard !stale.isEmpty else { return }
        let context = UICollectionViewLayoutInvalidationContext()
        context.invalidateItems(at: stale)
        collectionView.collectionViewLayout.invalidateLayout(with: context)
    }

    // MARK: - Viewport and bottom

    private var columnWidth: CGFloat {
        TimelineListMetrics.column(containerWidth: collectionView?.bounds.width ?? 0).width
    }

    var viewport: TimelineViewport {
        TimelineViewport(contentHeight: layout.contentHeight,
            containerHeight: collectionView.bounds.height,
            topInset: collectionView.adjustedContentInset.top,
            bottomInset: collectionView.adjustedContentInset.bottom,
            offsetY: collectionView.contentOffset.y,
            // Official one-physical-pixel tolerances use the screen scale
            // (CANONICAL/05-layout-scroll.md §6–7; part-ag §1.3), not the
            // Retina-2 fallback the geometry wrapper has to assume.
            displayScale: traitCollection.displayScale)
    }

    var bottomShortfall: CGFloat {
        max(0, layout.contentHeight - viewport.visibleBottom)
    }

    /// The host-side judgement the official `ScrollDownIndicator` receives
    /// through `hidden` (the view has no threshold of its own, part-u §5.1).
    ///
    /// The official predicate is `target − visibleBottom > 1 physical pixel`
    /// (`0x1019ddbf0`). AA needs a wider product dead zone: an animated
    /// return can rest about one physical pixel short of the layout's end
    /// (gate 600 measured 0.333 pt on a 3× simulator), and a keyboard/composer
    /// inset cycle can leave a few points of residual while the page still
    /// looks bottomed out (pp device report 2026-10-27: the control showed at
    /// the bottom after a keyboard round trip). Sixteen points is about one
    /// line of text — the smallest remaining travel a reader would notice.
    /// The official host threshold is U.
    private static let scrollDownIndicatorDeadZone: CGFloat = 16

    /// The driver owns the "at the end" truth. While it is following (or a
    /// return is on its way), the page is bottomed out by definition, so a
    /// transient inset residual must not summon the control. If a return
    /// genuinely fails, the reader can scroll once to leave `.end` and the
    /// control returns.
    private var isFollowingEnd: Bool {
        anchorDriver?.state.placement == .end
    }

    var canScrollDown: Bool {
        // `onControllerReady` fires before SwiftUI first loads the controller's
        // view, and `viewport` dereferences the implicitly-unwrapped
        // `collectionView` (nil until `viewDidLoad`). Build 601 crashed here
        // when the product bridge read this from attach; answer safely and let
        // the first viewport publication deliver the real value.
        guard isViewLoaded, !isFollowingEnd else { return false }
        return viewport.isMeasured
            && bottomShortfall > Self.scrollDownIndicatorDeadZone
    }

    /// The floating return control also hides while the drawer owns
    /// navigation, matching the old page's return pill.
    var showsScrollDownIndicator: Bool {
        canScrollDown && !navigationSuspended
    }

    private func publishViewport() {
        let next = viewport
        guard next.isMeasured else { return }
        guard next != lastPublishedViewport else { return }
        lastPublishedViewport = next
        onViewportChanged?(next)
        publishScrollDownIndicator()
        maybeAutoLoadOlder(next)
        maybeAutoLoadLatest(next)
    }

    /// Called by the bridge after a history/window flag changes. A viewport
    /// that is already parked at an edge would otherwise never re-publish and
    /// miss the new loadable edge.
    func requestOlderIfNearTop() {
        guard isViewLoaded else { return }
        maybeAutoLoadOlder(viewport)
    }

    func requestLatestIfAtBottom() {
        guard isViewLoaded else { return }
        maybeAutoLoadLatest(viewport)
    }

    /// The top trigger is one-shot: it disarms when it fires and only re-arms
    /// once a viewport sits more than the near-top margin below the top. If
    /// the bridge rejects the request before a read starts, nothing moves the
    /// viewport, so the latch would stay disarmed and the reader would have to
    /// tap the prompt. The bridge calls this on its early-exit guards.
    func rearmOlderAutoLoad() {
        olderAutoLoadArmed = true
    }

    /// Re-arms the one-shot bottom trigger when the bridge could not start the
    /// read yet (the opening path was still in flight).
    func rearmLatestAutoLoad() {
        latestAutoLoadSuppressed = false
        latestAutoLoadNeedsNewBottomVisit = false
        latestAutoLoadArmed = true
    }

    /// A history page is about to change the window. The reader asked for
    /// older rows, not for a latest replacement; a short page will make the
    /// viewport look "at bottom" but must not auto-load latest.
    func requireNewBottomVisitForLatest() {
        latestAutoLoadNeedsNewBottomVisit = true
        latestAutoLoadSuppressed = true
        latestAutoLoadArmed = false
    }

    /// The reader explicitly tapped the latest prompt; that is a real request
    /// and overrides the post-history guard.
    func allowLatestAfterHistoryGesture() {
        latestAutoLoadNeedsNewBottomVisit = false
        latestAutoLoadSuppressed = false
        latestAutoLoadArmed = false
    }

    /// A latest read just finished with the newer edge still incomplete (a
    /// stale local-first page). Do not immediately start the same read again
    /// from the bottom trigger; the background reconcile owns it now.
    func suppressLatestAutoLoad() {
        latestAutoLoadSuppressed = true
        latestAutoLoadArmed = false
    }

    /// True while a history prepend still owes a scroll correction. Auto-paging
    /// must not start from a transient viewport produced by that apply.
    var isHistoryPrependActive: Bool {
        historyPaging || historyAnchorSettling
            || insertionProjection != nil || !layout.insertionOwedIsSettled
    }

    /// Start the official-style history paging mode. The bridge calls this
    /// before the page request; the adapter calls `beginHistoryRequest` when
    /// the page arrives, which marks `historyPageArriving`.
    func beginHistoryPaging(anchorRowID: String? = nil) {
        guard TimelineHistoryAnchorMode.enabled else { return }
        // A page can arrive inside the previous page's 600 ms settle window.
        // Ending the settle below cancels its task, so the owed placement
        // correction would never run and the reading row would drift up by
        // the page's height on every page (b750 report: viewport pinned at
        // the top through four consecutive pages, offset never moved).
        if historyAnchorSettling {
            enforceSettledHistoryPlacement()
        }
        endHistoryAnchorSettling()
        requireNewBottomVisitForLatest()
        historyPagingTimeout?.cancel()
        historyPaging = true
        historyPageArriving = false
        historyAnchorItemID = nil
        historyAnchorRowID = anchorRowID
        historyAnchorOffsetIntoRow = 0
        historyInitialFirstRowID = currentItems.first.flatMap {
            content?.rowIDs(in: $0).first
        }
        historyPageFirstRowID = nil
        let inset = collectionView.adjustedContentInset
        let rawTop = collectionView.contentOffset.y + inset.top
        let contentHeight = max(0, layout.contentHeight)
        // A transient offset can sit outside the content (a height collapse
        // before UIKit clamps). Anchoring from it produces a massive negative
        // offsetIntoRow and later a blank viewport (device report 23:02:
        // off=-57129, into=-57096, contentH=49598). Never derive an anchor
        // from a viewport that is not inside the content.
        let top = min(max(rawTop, 0), contentHeight)
        let requestedAnchor = anchorRowID.flatMap { rowID -> (TimelineListItem, TimelineListLayoutAttributes)? in
            guard let item = content?.item(containingRow: rowID),
                  let attributes = layout.attributes(for: item.itemID) else { return nil }
            return (item, attributes)
        }
        let requestedInto = requestedAnchor.map { top - $0.1.frame.minY }
        func applyAnchor(item: TimelineListItem, rowID: String?,
                         into: CGFloat) {
            historyAnchorItemID = item.itemID
            historyAnchorRowID = rowID ?? content?.rowIDs(in: item).first
            historyAnchorOffsetIntoRow = into
            anchorDriver?.beginHistoryPaging(anchorID: item.itemID, offsetIntoRow: into)
            let attributes = layout.attributes(for: item.itemID)
            probeHistory("begin reqRow=\(rowID ?? "-") item=\(item.itemID) "
                + "rowY=\(attributes?.frame.minY ?? -1) into=\(into) "
                + "off=\(collectionView.contentOffset.y) inset=\(inset.top) "
                + "contentH=\(layout.contentHeight) items=\(currentItems.count) "
                + "sanitized=\(abs(rawTop - top) > 1 ? 1 : 0)")
        }
        if let requestedAnchor, let requestedInto,
           abs(rawTop - top) <= 1,
           let attributes = layout.attributes(for: requestedAnchor.0.itemID),
           requestedInto >= -viewport.visibleHeight,
           requestedInto <= attributes.frame.height + viewport.visibleHeight {
            applyAnchor(item: requestedAnchor.0, rowID: anchorRowID, into: requestedInto)
        } else if let fallback = anchor(at: top - inset.top),
                  let item = currentItems.first(where: { $0.itemID == fallback.id }) {
            applyAnchor(item: item, rowID: content?.rowIDs(in: item).first,
                        into: fallback.offsetIntoRow)
        } else {
            anchorDriver?.beginHistoryPaging()
            probeHistory("begin unresolved reqRow=\(anchorRowID ?? "-") "
                + "off=\(collectionView.contentOffset.y) contentH=\(layout.contentHeight) "
                + "items=\(currentItems.count) sanitized=\(abs(rawTop - top) > 1 ? 1 : 0)")
        }
        // A page that never changes content would otherwise pin this mode.
        historyPagingTimeout = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled, let self, self.historyPaging else { return }
            self.endHistoryPaging()
            self.endHistoryAnchorSettling()
        }
    }

    /// A history page regroups the whole window, so the anchor item's id can
    /// change even though its rows are still present. Rebind the driver to
    /// the item that now contains the reader's row before resolving the
    /// target; keeping the same `offsetIntoRow` preserves the old item top's
    /// screen position.
    private func reanchorHistoryPageIfNeeded() {
        guard historyPaging || historyAnchorSettling,
              let rowID = historyAnchorRowID, let content else { return }
        guard let item = content.item(containingRow: rowID) else {
            probeHistory("reanchor row=\(rowID) not-in-window")
            return
        }
        // The stored offset can itself be garbage when the request started
        // from an out-of-content viewport. Rebinding the row would then
        // enforce a huge negative target and leave no visible cells (device
        // report 23:02: off=-4612, contentH=102992, visible=0). Fall back to
        // the row under the current viewport instead of the lost anchor.
        if let attributes = layout.attributes(for: item.itemID) {
            let bound = max(viewport.visibleHeight, 2_000)
            let into = historyAnchorOffsetIntoRow
            if !into.isFinite || into < -bound || into > attributes.frame.height + bound {
                let rawTop = collectionView.contentOffset.y
                    + collectionView.adjustedContentInset.top
                let top = min(max(rawTop, 0), max(0, layout.contentHeight))
                guard let fallback = anchor(at: top - collectionView.adjustedContentInset.top),
                      let fallbackItem = currentItems.first(where: { $0.itemID == fallback.id }) else {
                    probeHistory("reanchor reset row=\(rowID) no-fallback into=\(into)")
                    return
                }
                let old = historyAnchorItemID ?? "-"
                historyAnchorItemID = fallbackItem.itemID
                historyAnchorRowID = content.rowIDs(in: fallbackItem).first
                historyAnchorOffsetIntoRow = fallback.offsetIntoRow
                anchorDriver?.beginHistoryPaging(anchorID: fallbackItem.itemID,
                                                 offsetIntoRow: fallback.offsetIntoRow)
                probeHistory("reanchor reset row=\(rowID) old=\(old) "
                    + "new=\(fallbackItem.itemID) badInto=\(into) "
                    + "into=\(fallback.offsetIntoRow) contentH=\(layout.contentHeight)")
                return
            }
        }
        guard item.itemID != historyAnchorItemID else { return }
        let old = historyAnchorItemID ?? "-"
        historyAnchorItemID = item.itemID
        anchorDriver?.beginHistoryPaging(anchorID: item.itemID,
                                         offsetIntoRow: historyAnchorOffsetIntoRow)
        probeHistory("reanchor row=\(rowID) old=\(old) new=\(item.itemID) "
            + "into=\(historyAnchorOffsetIntoRow) contentH=\(layout.contentHeight)")
    }

    func endHistoryPaging() {
        historyPagingTimeout?.cancel()
        historyPagingTimeout = nil
        historyPageArriving = false
        historyInitialFirstRowID = nil
        historyPageFirstRowID = nil
        guard historyPaging else { return }
        if let anchorID = historyAnchorItemID,
           let attributes = layout.attributes(for: anchorID) {
            probeHistory("end item=\(anchorID) screenY=\(attributes.frame.minY - collectionView.contentOffset.y) "
                + "off=\(collectionView.contentOffset.y) contentH=\(layout.contentHeight)")
        } else {
            probeHistory("end item=\(historyAnchorItemID ?? "-") gone off=\(collectionView.contentOffset.y) "
                + "contentH=\(layout.contentHeight)")
        }
        anchorDriver?.endHistoryPaging()
        historyPaging = false
        // Keep the row/offset for the settle window; `endHistoryAnchorSettling`
        // clears them. A page's last height corrections land after this call.
    }

    /// Keep the reading anchor enforced for a short quiet window after the
    /// page commits. `historyPaging` is already false here (the gate asserts
    /// it), so the driver's own content-change branch no longer runs.
    private func beginHistoryAnchorSettling() {
        guard historyAnchorRowID != nil else { return }
        historyAnchorSettling = true
        probeHistory("settle begin row=\(historyAnchorRowID ?? "-") "
            + "into=\(historyAnchorOffsetIntoRow) contentH=\(layout.contentHeight)")
        historySettleTask?.cancel()
        historySettleTask = Task { @MainActor [weak self] in
            // A gesture at the moment of correction owns the viewport; wait
            // for it to finish (bounded) instead of fighting the finger.
            for _ in 0..<15 {
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled, let self, self.historyAnchorSettling else { return }
                if self.isUserScrolling { continue }
                self.enforceSettledHistoryPlacement()
                self.endHistoryAnchorSettling()
                return
            }
            self?.endHistoryAnchorSettling()
        }
    }

    /// Enforce the page's reading anchor, not the driver's live placement.
    ///
    /// The apply path rebinds through `reanchorHistoryPageIfNeeded()` before
    /// every enforcement; the settle task used to trust the driver state.
    /// Gestures and UIKit scroll events during the request rewrite that state
    /// from the viewport, and at the top edge `anchor(at:)` names the window's
    /// *first* item — after the prepend that item's row is the top of the
    /// newly loaded page. The settle then wrote the apply's own correction
    /// (4160/7048/7125) back to -97, which also re-armed the near-top
    /// auto-load latch and looped (b750 report 2026-10-31 02:24).
    private func enforceSettledHistoryPlacement() {
        guard let itemID = historyAnchorItemID else {
            anchorDriver?.enforceReadingPlacement()
            return
        }
        // The settle correction repairs late height changes at the page's
        // anchor. A reader who has already moved more than a viewport away
        // owns their position; the apply-time correction is the one that
        // lands large drift, never this quiet-window pass.
        if let attributes = layout.attributes(for: itemID) {
            let target = attributes.frame.minY + historyAnchorOffsetIntoRow
                - collectionView.adjustedContentInset.top
            let drift = abs(collectionView.contentOffset.y - target)
            if drift > max(viewport.visibleHeight, 2_000) { return }
        }
        anchorDriver?.beginHistoryPaging(anchorID: itemID,
                                         offsetIntoRow: historyAnchorOffsetIntoRow)
        anchorDriver?.endHistoryPaging()   // enforces, then clears its flag
    }

    private func endHistoryAnchorSettling() {
        if historyAnchorSettling {
            probeHistory("settle end off=\(collectionView.contentOffset.y) "
                + "contentH=\(layout.contentHeight)")
        }
        historySettleTask?.cancel()
        historySettleTask = nil
        historyAnchorSettling = false
        historyAnchorItemID = nil
        historyAnchorRowID = nil
        historyAnchorOffsetIntoRow = 0
    }

    /// The adapter's prepend snapshot is the one that carries the page. The
    /// v2 path does not install a one-shot absolute target; the first-row
    /// marker lets an earlier in-flight apply finish without consuming the
    /// page's correction.
    func noteHistoryPageArriving(firstRowID: String?) {
        guard historyPaging else { return }
        historyPageArriving = true
        historyPageFirstRowID = firstRowID
        probeHistory("arriving pageFirst=\(firstRowID ?? "-") "
            + "initialFirst=\(historyInitialFirstRowID ?? "-") "
            + "currentFirst=\(currentItems.first.flatMap { content?.rowIDs(in: $0).first } ?? "-") "
            + "items=\(currentItems.count) contentH=\(layout.contentHeight)")
    }

    private func maybeAutoLoadOlder(_ viewport: TimelineViewport) {
        guard viewport.isMeasured else { return }
        let nearTop = viewport.offsetY + viewport.topInset <= Self.olderAutoLoadThreshold
        guard nearTop else {
            olderAutoLoadArmed = true
            return
        }
        // A list shorter than the viewport is already showing both edges; let
        // the prompt/pull own that case instead of auto-loading every page.
        guard viewport.contentHeight > viewport.visibleHeight + 1 else { return }
        guard !navigationSuspended, canLoadOlder, !isHistoryPrependActive,
              olderAutoLoadArmed else { return }
        olderAutoLoadArmed = false
        probeHistory("auto-older fire top=\(viewport.offsetY + viewport.topInset) "
            + "contentH=\(viewport.contentHeight) visH=\(viewport.visibleHeight)")
        onNeedsOlder?()
    }

    private func maybeAutoLoadLatest(_ viewport: TimelineViewport) {
        guard viewport.isMeasured else { return }
        if latestAutoLoadNeedsNewBottomVisit {
            // Only a real gesture that leaves the bottom counts as a new
            // visit. A short history page or a content-height change may
            // report "at bottom" without the reader asking for newer rows.
            guard !viewport.measuredAtBottom, isUserScrolling else { return }
            latestAutoLoadNeedsNewBottomVisit = false
            latestAutoLoadSuppressed = false
            latestAutoLoadArmed = true
        }
        guard viewport.measuredAtBottom else {
            // A content-height change can dip the viewport out of bottom
            // without the reader moving. Only a real gesture clears the
            // local-first suppression; otherwise the same read restarts and
            // its spinner never settles.
            if isUserScrolling {
                latestAutoLoadSuppressed = false
                latestAutoLoadArmed = true
            } else if !latestAutoLoadSuppressed {
                latestAutoLoadArmed = true
            }
            return
        }
        guard !navigationSuspended, canLoadLatest, !isHistoryPrependActive,
              latestAutoLoadArmed else { return }
        // Reaching the bottom of a history window is the reader's request for
        // the newest side. One trigger per bottom episode: a failed load waits
        // for a fresh leave-and-return (or the visible latest prompt).
        latestAutoLoadArmed = false
        probeHistory("auto-latest fire off=\(viewport.offsetY) "
            + "contentH=\(viewport.contentHeight) visH=\(viewport.visibleHeight)")
        onNeedsLatest?()
    }

    private func publishScrollDownIndicator() {
        let next = showsScrollDownIndicator
        guard next != lastScrollDownIndicator else { return }
        lastScrollDownIndicator = next
        onScrollDownIndicatorChanged?(next)
    }

    /// Called by `loadLatest()` before its await: the newer window can be
    /// applied before the post-await `requestBottom` runs, so the return
    /// intent must exist first.
    func beginWindowReplacementReturn() {
        // No wall-clock deadline here: this arm exists precisely because the
        // window apply can land at any time during a slow `loadLatest` await.
        // The post-await `requestBottom` re-arms with the bounded lifetime.
        windowReplacementReturn = true
        windowReturnToken &+= 1
    }

    private func armWindowReplacementReturn() {
        windowReplacementReturn = true
        windowReturnToken &+= 1
        let token = windowReturnToken
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, self.windowReturnToken == token else { return }
            self.windowReplacementReturn = false
        }
    }

    /// Forced commands (pill / loadLatest / approval dismissed / window
    /// re-assert) arm unconditionally; follow requests use the gated arm.
    func requestBottom(animated: Bool, forced: Bool = true) {
        if navigationSuspended {
            suspendedBottomRequest = (animated, forced || (suspendedBottomRequest?.forced ?? false))
            return
        }
        guard collectionView != nil else { return }
        // An approval card owns the page until it resolves; only a forced
        // command (the card disappearing, load-latest) may override it.
        if interactionPresented && !forced { return }
        // A follow request only follows a page that is waiting at the end;
        // a reader up in history is never pulled by new content.
        if !forced, anchorDriver?.state.placement != .end { return }
        // Official `askedForEnd` is ignored while the finger is on the list;
        // defer it and replay at the gesture end.
        if collectionView.isTracking {
            pendingGestureBottomRequest = (
                animated,
                forced || (pendingGestureBottomRequest?.forced ?? false))
            return
        }
        if forced { armWindowReplacementReturn() }
        // A programmatic write interrupts UIKit's deceleration without a
        // guaranteed didEndDecelerating; close the user-scroll phase here so
        // the settle passes and guards do not stay blocked.
        if phase.phase == .decelerating {
            let transition = phase.apply(.didEndDecelerating)
            onPhaseChanged?(transition)
        }
        anchorDriver?.requestEnd(animated: animated
            && !reduceMotion && !UIAccessibility.isVoiceOverRunning)
        // The request moves the placement to `.end` synchronously; hide the
        // return control now instead of waiting for the first offset sample
        // (a request that needs no movement would otherwise leave it up).
        publishScrollDownIndicator()
        scheduleVisibleCellSettle()
    }

    func setReduceMotion(_ value: Bool) {
        reduceMotion = value
    }

    /// Opening: arm the bottom before the first snapshot so every measured
    /// content-size change pins there, then land without an animation. The
    /// wrapper's 400 ms fallback settles the cold-load mask even if the window
    /// never arrives.
    func beginOpeningBottom() {
        if navigationSuspended {
            suspendedOpeningRequest = true
            return
        }
        guard collectionView != nil else { return }
        anchorDriver?.requestEnd(animated: false)
    }

    /// The opening's arrival check. `onApplyCompleted` can run before the
    /// collection view has laid out the first snapshot (the C3 gate itself
    /// calls `layoutIfNeeded` there), so force the pass, land, and report
    /// whether the measured viewport is truly at the bottom. The caller keeps
    /// the cold-load mask until this returns true, or its 400 ms fallback.
    @discardableResult
    func settleOpeningBottom() -> Bool {
        guard let collectionView, !navigationSuspended else { return false }
        collectionView.layoutIfNeeded()
        beginOpeningBottom()
        return viewport.isMeasured && viewport.contentHeight > 0 && viewport.measuredAtBottom
    }

    /// Follow requests keep the official semantics: askedForEnd only acts
    /// from a following page (the reducer ignores it while dragging).
    @discardableResult
    func requestFollowingBottom(requiresNoInteraction: Bool) -> Bool {
        guard !navigationSuspended else { return false }
        if requiresNoInteraction && interactionPresented { return false }
        guard anchorDriver?.state.placement == .end else { return false }
        anchorDriver?.requestEnd(animated: true)
        return true
    }

    /// Compatibility seam for the C3 gate (C5 rewrites its assertions against
    /// the placement state); the anchor model has no separate arm.
    @discardableResult
    func armFollowingBottom(readerRestsAtBottom: Bool, mode: TimelineScrollState.Mode,
                            interactionPresented: Bool, requiresNoInteraction: Bool) -> Bool {
        _ = readerRestsAtBottom; _ = mode
        _ = interactionPresented; _ = requiresNoInteraction
        return true
    }

    func disarmBottom() {
        anchorDriver?.adoptReadingPlacement()
        // The placement (not the offset) moved; re-evaluate the control so a
        // reader takeover can reveal it without waiting for the next sample.
        publishScrollDownIndicator()
    }

    func readerDidRestAtBottom(_ rests: Bool, interactionPresented: Bool) {
        _ = rests; _ = interactionPresented
    }

    /// An approval appearing stops automatic following; its disappearance is
    /// an explicit return (the old `setInteractionPresented`).
    func setInteractionPresented(_ presented: Bool) {
        guard interactionPresented != presented else { return }
        interactionPresented = presented
        anchorDriver?.interactionPresentedChanged(presented)
    }

    /// Stops the in-flight programmatic return. The old view released its
    /// `ScrollPosition` target on the same edges (approval appears, drawer
    /// moves); leaving the motion running would still pull the page.
    private func stopBottomAnimation() {
        anchorDriver?.haltMotion()
        if phase.phase == .animating {
            let transition = phase.apply(.watchdogExpired)
            onPhaseChanged?(transition)
        }
    }

    // MARK: - Container anchoring

    /// The old timeline's `.defaultScrollAnchor(.bottom, for: .sizeChanges)`:
    /// a container height change (split view, rotation) keeps the newest row at
    /// the input bar. Content-size changes are not anchored here; those follow
    /// only while the bottom target is armed.
    ///
    /// Inset-only changes (keyboard, composer height) do not come through
    /// here: the anchor driver writes them inside the safe-area update's
    /// animation transaction and follows only a waiting-at-end placement.
    private func handleContainerHeightChange() {
        guard let collectionView else { return }
        let height = collectionView.bounds.height
        let heightChanged = lastContainerHeight > 0 && abs(height - lastContainerHeight) > 0.5
        lastContainerHeight = height
        guard heightChanged, !navigationSuspended, !phase.userIsScrolling else { return }
        anchorDriver?.containerChanged()
    }

    private func beginPulls(at viewport: TimelineViewport) {
        // The prompt flags are geometric, not model flags: a pull anywhere
        // else in the transcript must not be read as "at history edge".
        olderPromptVisible = currentItems.first == .olderPrompt && canLoadOlder
            && promptIsVisible(.olderPrompt)
        latestPromptVisible = currentItems.last == .latestPrompt && canLoadLatest
            && promptIsVisible(.latestPrompt)
        olderPull.begin(at: viewport, promptVisible: olderPromptVisible, canLoad: canLoadOlder)
        latestPull.begin(at: viewport, promptVisible: latestPromptVisible, canLoad: canLoadLatest)
    }

    /// A drag can start just below the top and reach the prompt mid-gesture.
    /// The one-time arm at `scrollViewWillBeginDragging` would miss it, which
    /// is exactly the "pull does nothing, tap works" shape.
    private func rearmVisiblePulls(at viewport: TimelineViewport) {
        if !olderPromptVisible, currentItems.first == .olderPrompt,
           canLoadOlder, promptIsVisible(.olderPrompt) {
            olderPromptVisible = true
            olderPull.begin(at: viewport, promptVisible: true, canLoad: true)
        }
        if !latestPromptVisible, currentItems.last == .latestPrompt,
           canLoadLatest, promptIsVisible(.latestPrompt) {
            latestPromptVisible = true
            latestPull.begin(at: viewport, promptVisible: true, canLoad: true)
        }
    }

    private func promptIsVisible(_ item: TimelineListItem) -> Bool {
        guard let attributes = layout.attributes(for: item.itemID) else { return false }
        let current = viewport
        return attributes.frame.maxY > current.offsetY + current.topInset
            && attributes.frame.minY < current.visibleBottom
    }

    /// The first row at or below the viewport top. A history prepend anchors
    /// to this row so the text the reader is looking at stays put.
    func visibleAnchorRowID() -> String? {
        guard let content else { return nil }
        let top = viewport.offsetY + viewport.topInset
        for item in currentItems {
            guard let attributes = layout.attributes(for: item.itemID) else { continue }
            if attributes.frame.maxY > top {
                return content.rowIDs(in: item).first
            }
        }
        return currentItems.first.flatMap { content.rowIDs(in: $0).first }
    }

    /// The reading anchor in itemID space: the row under the viewport top and
    /// the distance into it (official `readerBeganDragging` derivation).
    /// Static chrome (the older/latest prompts and the tail) is not content:
    /// anchoring on the older prompt makes a prepend insert rows *below* the
    /// anchor, so the prompt stays put and the reader is left looking at the
    /// new page's top. Skip it exactly as the official row list would.
    func anchor(at offset: CGFloat) -> (id: String, offsetIntoRow: CGFloat)? {
        let top = offset + viewport.topInset
        for item in currentItems where TimelineHistoryAnchorRows.isAnchorable(item) {
            guard let attributes = layout.attributes(for: item.itemID) else { continue }
            if attributes.frame.maxY > top {
                return (item.itemID, top - attributes.frame.minY)
            }
        }
        let anchorable = currentItems.filter(TimelineHistoryAnchorRows.isAnchorable)
        guard let first = anchorable.first else { return nil }
        let firstStart = layout.attributes(for: first.itemID)?.frame.minY ?? top
        if top <= firstStart {
            return (first.itemID, max(0, top - firstStart))
        }
        guard let last = anchorable.last,
              let lastAttributes = layout.attributes(for: last.itemID) else {
            return (first.itemID, max(0, top - firstStart))
        }
        return (last.itemID, top - lastAttributes.frame.minY)
    }

    var firstVisibleRowID: String? {
        visibleAnchorRowID()
    }

    private func updatePulls(_ viewport: TimelineViewport) {
        olderPull.update(viewport)
        latestPull.update(viewport)
    }

    private func settlePulls() {
        let older = olderPull.end()
        let latest = latestPull.end()
        if older { onLoadOlder?() }
        else if latest { onLoadLatest?() }
    }

    // MARK: - History anchors and prepend

    func historyLayout(anchorRowID: String, edge: TimelineHistoryLayout.Edge) -> TimelineHistoryLayout? {
        guard let content, let item = content.item(containingRow: anchorRowID),
              let attributes = layout.attributes(for: item.itemID),
              let first = currentItems.first else { return nil }
        let firstRowID = content.rowIDs(in: first).first ?? first.itemID
        return TimelineHistoryLayout(firstRowID: firstRowID, anchorRowID: anchorRowID,
            edge: edge, y: edge == .top ? attributes.frame.minY : attributes.frame.maxY)
    }

    /// The part of a prepended list the anchor projection actually reads:
    /// everything from the new top through the anchor item. Everything below
    /// keeps the height it had in the old window.
    private func measurePrefix(upTo anchorRowID: String,
                               in items: [TimelineListItem]) -> [TimelineListItem] {
        guard let content,
              let index = items.firstIndex(where: {
                  content.anchorRowIDs(in: $0).contains(anchorRowID)
              }) else { return items }
        return Array(items.prefix(index + 1))
    }

    /// Where the anchor will sit after `items` is laid out, using the cache's
    /// current heights. The new page was measured synchronously just before
    /// this call, so the value is the same one the post-apply layout produces.
    func projectedHistoryLayout(items: [TimelineListItem], anchorRowID: String,
                                edge: TimelineHistoryLayout.Edge) -> TimelineHistoryLayout? {
        guard let content, columnWidth > 0 else { return nil }
        var y = TimelineListMetrics.topInset
        var firstRowID: String?
        for (index, item) in items.enumerated() {
            let key = content.heightKey(for: item, width: columnWidth)
            // Use the same resolver the layout's `prepare` will use. A
            // re-keyed row keeps the height the reader sees until its cell
            // reports the new one; the prepend target must be computed from
            // that same value or the anchor would move twice (once by the
            // target, once by the report's compensation).
            let height = layout.heights.resolvedHeight(for: key, itemID: item.itemID,
                fallback: content.estimateKind(for: item))
            if index == 0 { firstRowID = content.rowIDs(in: item).first ?? item.itemID }
            if content.anchorRowIDs(in: item).contains(anchorRowID) {
                return TimelineHistoryLayout(firstRowID: firstRowID ?? item.itemID,
                    anchorRowID: anchorRowID, edge: edge,
                    y: edge == .top ? y : y + height)
            }
            y += height
            if index < items.count - 1 {
                y += content.itemSpacing(after: item)
            }
        }
        return nil
    }

    /// Sets the absolute prepend target before the snapshot applies. Returns
    /// the existing `TimelineHistoryPosition` so the caller can feed
    /// `receivedPage`/readiness without re-deriving the origin.
    func beginHistoryRequest(generation: Int, anchorRowID: String,
                             edge: TimelineHistoryLayout.Edge,
                             newItems: [TimelineListItem]) -> TimelineHistoryPosition? {
        guard let origin = historyLayout(anchorRowID: anchorRowID, edge: edge) else { return nil }
        return beginHistoryRequest(generation: generation, anchorRowID: anchorRowID,
            edge: edge, newItems: newItems, origin: origin)
    }

    /// The adapter captures `origin` before it rebuilds its groups. A history
    /// page can merge the anchor's group; after the merge, the old row no
    /// longer resolves to an item that still has layout attributes, so the
    /// origin must be taken from the pre-refresh maps.
    func beginHistoryRequest(generation: Int, anchorRowID: String,
                             edge: TimelineHistoryLayout.Edge,
                             newItems: [TimelineListItem],
                             origin: TimelineHistoryLayout) -> TimelineHistoryPosition? {
        if historyPaging {
            // Official-style path: the anchor driver already holds the
            // reading placement and resolves the new offset from the updated
            // layout. No projected one-shot target is installed.
            probeHistory("request v2 anchor=\(anchorRowID) n=\(newItems.count) "
                + "first=\(newItems.first.flatMap { content?.rowIDs(in: $0).first } ?? "-")")
            noteHistoryPageArriving(firstRowID: newItems.first.flatMap {
                content?.rowIDs(in: $0).first
            })
            return nil
        }
        // Loading older is a browsing action. Stop any programmatic motion;
        // the reading placement then absorbs the prepend by construction.
        stopBottomAnimation()
        // The projected anchor only needs the heights from the new top down
        // to the anchor. Measuring the entire window here made a 300-row
        // history page a synchronous offscreen-hosting pass over every row
        // below it as well (device report 2026-10-30: loading history dropped
        // frames). Rows below the anchor already have heights from the
        // previous window; the post-apply measurement still covers any gap.
        measureSynchronously(measurePrefix(upTo: anchorRowID, in: newItems),
                             width: columnWidth)
        guard let projected = projectedHistoryLayout(items: newItems,
                                                     anchorRowID: anchorRowID, edge: edge) else { return nil }
        let position = TimelineHistoryPosition(id: generation, layout: origin,
            offsetY: collectionView.contentOffset.y, topInset: collectionView.adjustedContentInset.top)
        layout.beginInsertionOwed(generation: generation, origin: origin,
            offsetY: collectionView.contentOffset.y, topInset: collectionView.adjustedContentInset.top)
        layout.updateInsertionOwed(layout: projected)
        insertionProjection = (anchorRowID, edge)
        return position
    }

    func cancelHistoryRequest() {
        insertionProjection = nil
        layout.cancelInsertionOwed()
        endHistoryPaging()
        endHistoryAnchorSettling()
    }

    var items: [TimelineListItem] { currentItems }

    func indexPath(for item: TimelineListItem) -> IndexPath? {
        guard let index = currentItems.firstIndex(of: item) else { return nil }
        return IndexPath(item: index, section: 0)
    }

    /// The item's top edge in screen coordinates.
    func screenY(for item: TimelineListItem) -> CGFloat? {
        guard let attributes = layout.attributes(for: item.itemID) else { return nil }
        return attributes.frame.minY - collectionView.contentOffset.y
    }

    // MARK: - Navigation suspension

    func setNavigationSuspended(_ suspended: Bool) {
        guard navigationSuspended != suspended else { return }
        navigationSuspended = suspended
        anchorDriver?.navigationSuspendedChanged(suspended)
        if suspended {
            layout.cancelBrowsingCorrections()
            olderPull.cancel()
            latestPull.cancel()
            pendingMeasurementTask?.cancel()
            stopBottomAnimation()
            pendingGestureBottomRequest = nil
        } else {
            // An interrupted animation has no completion; clear the phase so
            // the next reader gesture is not read as an animation completion.
            if phase.phase == .animating {
                let transition = phase.apply(.watchdogExpired)
                onPhaseChanged?(transition)
            }
            // The driver's navigationSuspendedChanged(false) performs the
            // placement itself.
            publishViewport()
            if suspendedOpeningRequest {
                suspendedOpeningRequest = false
                suspendedBottomRequest = nil
                beginOpeningBottom()
            } else if let request = suspendedBottomRequest {
                suspendedBottomRequest = nil
                requestBottom(animated: request.animated, forced: request.forced)
            }
        }
        // Suspension hides the return control without a viewport change;
        // resume re-measures through `publishViewport`, and the dedupe keeps
        // this second call free.
        publishScrollDownIndicator()
    }
}

extension TimelineCollectionController: TimelineListLayoutHost {
    var layoutItemCount: Int { currentItems.count }

    func layoutItem(at index: Int) -> TimelineListItem { currentItems[index] }

    var layoutFirstRowID: String? {
        currentItems.first.flatMap { content?.rowIDs(in: $0).first }
    }

    func layoutHeightKey(for item: TimelineListItem, width: CGFloat) -> TimelineHeightKey {
        content?.heightKey(for: item, width: width) ?? TimelineHeightKey(itemID: item.itemID,
            contentRevision: 0, width: width, dynamicType: "", typographyRevision: 0, layoutDirection: 0)
    }

    func layoutEstimateKind(for item: TimelineListItem) -> TimelineHeightEstimateKind {
        content?.estimateKind(for: item) ?? .row
    }

    func layoutHeightPolicy(for item: TimelineListItem) -> TimelineRowHeightPolicy {
        content?.heightPolicy(for: item) ?? .measured
    }

    func layoutItemSpacing(after item: TimelineListItem) -> CGFloat {
        content?.itemSpacing(after: item) ?? TimelineListMetrics.itemSpacing
    }

    func layoutContentKind(for item: TimelineListItem) -> TimelineMeasurementContent {
        content?.measurementContent(for: item) ?? .markdown
    }

    func layoutInteractionState() -> TimelineLayoutInteractionState {
        var state = content?.interactionState() ?? TimelineLayoutInteractionState()
        let driverFollowing = anchorDriver?.state.placement == .end
        state.hasArmedBottomTarget = driverFollowing
        // Native drags report `.interacting`; the decision's "tracking" input
        // means "the finger is down", so map the native phase onto it. Without
        // this, a pending-measurement correction moves the offset under the
        // reader's finger during a drag.
        state.isTracking = phase.phase == .interacting
        state.isDecelerating = phase.phase == .decelerating
        state.userIsScrolling = phase.userIsScrolling
#if DEBUG
        // Simulator gates drive the drag invariants without a real finger.
        // The override must reach every decision helper, not just the
        // controller's own guards, so apply it here where the layout reads the
        // interaction state.
        if let testGestureState {
            state.isTracking = testGestureState.tracking
            state.isDecelerating = testGestureState.decelerating
            state.userIsScrolling = testGestureState.tracking || testGestureState.decelerating
        }
#endif
        state.interactionPresented = interactionPresented
        state.mode = driverFollowing ? .following : .reading
        state.suppressContentOffsetAdjustment = navigationSuspended
        return state
    }

#if DEBUG
    func setTestGestureState(tracking: Bool, decelerating: Bool) {
        let previous = testGestureState
        let wasScrolling = previous.map { $0.tracking || $0.decelerating } ?? false
        testGestureState = (tracking: tracking, decelerating: decelerating)
        if tracking || decelerating {
            guard !wasScrolling else { return }
            // The simulator cannot synthesize touches, so the seam must move
            // the same state `scrollViewWillBeginDragging` moves. Without
            // `mode = .reading` a content change under the test finger let
            // `noteBottomArrival` re-arm the bottom target on every frame;
            // the repin then dragged the offset down with the growing row
            // (gate: target moved 388 pt off the screen).
            anchorDriver?.readerBeganDragging()
            windowReplacementReturn = false
            _ = phase.apply(.willBeginDragging)
            layout.noteDragWillBegin()
            return
        }
        guard wasScrolling else {
            // A release without an active test gesture still starts the
            // settle passes; the cell that changed while it ran needs one.
            scheduleVisibleCellSettle()
            return
        }
        // Mirror the matching end callback so the phase machine and the
        // settle passes see a finished drag, exactly like a real scroll end.
        let decelerated = previous?.decelerating == true
        _ = phase.apply(.didEndDragging(willDecelerate: decelerated))
        anchorDriver?.readerLifted(willCoast: decelerated)
        layout.noteDragDidEnd(willDecelerate: decelerated)
        if decelerated {
            _ = phase.apply(.didEndDecelerating)
            anchorDriver?.coastingEnded()
            layout.noteDecelerationDidEnd()
        }
        scheduleVisibleCellSettle()
        scheduleVisibleCellFrameSync()
        schedulePendingMeasurements()
        publishViewport()
    }
#endif

    /// One definition for every guard that must not mutate geometry under the
    /// reader's finger. Release builds read the real collection view.
    var isUserScrolling: Bool {
#if DEBUG
        if let testGestureState {
            return testGestureState.tracking || testGestureState.decelerating
        }
#endif
        return collectionView?.isTracking == true || collectionView?.isDecelerating == true
    }

    func layoutDidSettlePull() { settlePulls() }

    func layoutDidChangeContentHeight(_ height: CGFloat) {
        publishViewport()
        if !didStartAnchorDriver {
            startAnchorDriverIfNeeded()
        } else {
            if historyPaging || historyAnchorSettling {
                reanchorHistoryPageIfNeeded()
            }
            anchorDriver?.contentChanged()
            if historyAnchorSettling, !historyPaging {
                anchorDriver?.enforceReadingPlacement()
            }
        }
        onContentHeightChanged?(height)
    }

    /// The first layout with content flips `hasLanded` and places once. It can
    /// arrive from the controller's own layout pass or from the layout's first
    /// height commit; both must be able to land it.
    private func startAnchorDriverIfNeeded() {
        guard !didStartAnchorDriver, layout.contentHeight > 0,
              !currentItems.isEmpty else { return }
        didStartAnchorDriver = true
        anchorDriver?.viewportChanged()
    }

    /// A width change (rotation, split view) re-keyed rows without an apply.
    /// Measure on the next turn: `prepare` must not start measurement, and
    /// the pending set is only complete after this prepare returns.
    func layoutNeedsMeasurement(width: CGFloat) {
        guard width > 0 else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.navigationSuspended, !self.currentItems.isEmpty else { return }
            self.schedulePendingMeasurements()
        }
    }
}

extension TimelineCollectionController: TimelineListLayoutCellReportedHeightHost {
    /// Rows that follow the official hosted-cell contract. The layout needs
    /// this to skip them in the legacy correction paths (streaming-height
    /// cleanup) and to run the hosted height accounting.
    func layoutUsesCellReportedHeight(for item: TimelineListItem) -> Bool {
        content?.usesCellReportedHeight(for: item) ?? false
    }
}


extension TimelineCollectionController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView,
                        willDisplay cell: UICollectionViewCell,
                        forItemAt indexPath: IndexPath) {
        // A newly materialized row is the first moment its real SwiftUI
        // content exists. Defer the first fit to the next turn so the hosting
        // view has run its initial layout; the settle passes then wait for an
        // async Markdown parse.
        if currentItems.indices.contains(indexPath.item) {
            // From here on this row's displayed height is a height the reader
            // actually saw; a future re-key may keep it.
            layout.heights.markEverDisplayed(currentItems[indexPath.item].itemID)
        }
        guard !navigationSuspended else { return }
        // Coalesce the burst of willDisplay calls a scroll produces. The
        // scroll-end callbacks start their own settle, so a fast fling does
        // not run a SwiftUI fitting pass per materialized cell.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, !self.navigationSuspended else { return }
            self.scheduleVisibleCellSettle()
        }
    }

    /// A streaming row that scrolls away stops driving per-frame heights (its
    /// display link is reset with the reused cell). Drop its display override
    /// so the offscreen row returns to its measured height; a later
    /// configuration re-installs the current clamp.
    func collectionView(_ collectionView: UICollectionView,
                        didEndDisplaying cell: UICollectionViewCell,
                        forItemAt indexPath: IndexPath) {
        guard currentItems.indices.contains(indexPath.item) else { return }
        layout.clearStreamingHeight(for: currentItems[indexPath.item].itemID)
        scheduleVisibleCellFrameSync()
    }

    func scrollViewDidChangeAdjustedContentInset(_ scrollView: UIScrollView) {
        guard !navigationSuspended else { return }
        // UIKit can install its own safe area after the first inset write; the
        // official formula subtracts it from the page proxy, so recompute here
        // or the proxy is counted twice (new session, 2026-10-28). Our own
        // writes land here too and are a no-op (the value already matches).
        anchorDriver?.containerInsetsChanged()
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        guard !navigationSuspended else { return }
        if historyAnchorSettling { endHistoryAnchorSettling() }
        // A real gesture is the reader's intent; it may retry a latest read
        // that a local-first page suppressed.
        latestAutoLoadSuppressed = false
        anchorDriver?.readerBeganDragging()
        // The reader's finger always wins over a window replacement whose
        // return has not resolved yet.
        windowReplacementReturn = false
        let transition = phase.apply(.willBeginDragging)
        onPhaseChanged?(transition)
        layout.noteDragWillBegin()
        beginPulls(at: viewport)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !navigationSuspended else { return }
#if DEBUG
        if testGestureState != nil {
            let y = scrollView.contentOffset.y
            if let last = debugScrollLastOffset, abs(y - last) > 0.5,
               debugScrollCallSites.count < 6 {
                let frames = Thread.callStackSymbols.prefix(14)
                    .map { $0.replacingOccurrences(of: "0x", with: "") }
                    .joined(separator: " | ")
                debugScrollCallSites.append("\(last)->\(y): \(frames)")
            }
            debugScrollLastOffset = y
        }
#endif
#if AA_TIMELINE_PROBE
        TimelineProbeStore.shared.scrollTick()
#endif
        let current = viewport
        if phase.phase == .interacting { rearmVisiblePulls(at: current) }
        if phase.phase == .interacting || phase.phase == .decelerating { updatePulls(current) }
        publishViewport()
        anchorDriver?.scrolledWithoutAHand()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        guard !navigationSuspended else { return }
        // Official: the drag-end event applies only while `motion == dragging`
        // (part-ag §1.7). If a programmatic return is already animating (a
        // product event started it under the finger is deferred, see
        // `requestBottom`), leaving `.animating` alone is what keeps the
        // spring alive.
        if phase.phase == .interacting {
            let transition = phase.apply(.didEndDragging(willDecelerate: decelerate))
            onPhaseChanged?(transition)
            if anchorDriver?.state.motion == .dragging {
                anchorDriver?.readerLifted(willCoast: decelerate)
            }
        }
        layout.noteDragDidEnd(willDecelerate: decelerate)
        scheduleVisibleCellSettle()
        scheduleVisibleCellFrameSync()
        schedulePendingMeasurements()
        publishViewport()
        replayPendingGestureBottomRequest()
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        guard !navigationSuspended else { return }
        // Official: the deceleration-end event applies only while
        // `motion == coasting` (part-ag §1.7). A return that halted the coast
        // is `.animating` now; this callback must not set it idle or the
        // follower would stop mid-flight without an arrival.
        if phase.phase == .decelerating {
            let transition = phase.apply(.didEndDecelerating)
            onPhaseChanged?(transition)
            // A return started mid-coast owns the placement now; the native
            // deceleration callback must not re-derive it from a mid-flight
            // position (the reducer guard is motion == .coasting).
            if anchorDriver?.state.motion == .coasting {
                anchorDriver?.coastingEnded()
            }
        }
        layout.noteDecelerationDidEnd()
        scheduleVisibleCellSettle()
        scheduleVisibleCellFrameSync()
        schedulePendingMeasurements()
        scheduleVisibleCellSettle()
        publishViewport()
        replayPendingGestureBottomRequest()
    }

    func scrollViewShouldScrollToTop(_ scrollView: UIScrollView) -> Bool {
        guard !navigationSuspended else { return false }
        if phase.phase == .decelerating {
            let transition = phase.apply(.didEndDecelerating)
            onPhaseChanged?(transition)
        }
        // Official interception (`0x101a3cb14 → 0x101a3d838`): UIKit's own
        // scroll-to-top is refused; the anchor model owns the motion.
        anchorDriver?.requestStart()
        return false
    }


}

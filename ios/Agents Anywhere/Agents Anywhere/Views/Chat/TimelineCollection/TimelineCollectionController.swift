import SwiftUI
import UIKit
import OSLog

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
    private var bottomAnimationWatchdog: Task<Void, Never>?
    private var lastPublishedViewport = TimelineViewport()

    private(set) var phase = TimelinePhaseMapping()
    private(set) var armedBottom = TimelineArmedBottomTarget()
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

    // C4 product state. `mode` and `readerRestsAtBottom` mirror the facts the
    // SwiftUI timeline kept in `TimelineScrollState`; the layout's correction
    // decisions read them through `layoutInteractionState()`.
    private(set) var mode: TimelineScrollState.Mode = .reading
    private(set) var readerRestsAtBottom = false
    /// The at-bottom verdict at the instant the finger let go. A layout tick
    /// inside the 64 ms settlement window can move the measured viewport; the
    /// old state ORed this latch with the fresh measurement so a reader who
    /// arrived still resumes following.
    private var readerSettledAtBottom = false
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
    private var userScrollSettleTask: Task<Void, Never>?
    private var isPinningBottom = false
    /// Streaming height follow (M4.2): the official sprung motion toward the
    /// bottom, driven by its own display link while the reveal grows the row.
    private var streamingFollowLink: CADisplayLink?
    private var streamingFollowSpring = TimelineSpringFollow.Spring.ease
    private var streamingFollowStartPosition: CGFloat = 0
    private var streamingFollowStartTime: TimeInterval = 0
    private var streamingFollowLastTime: TimeInterval = 0
    private var streamingFollowLastPosition: CGFloat = 0
    /// Last frame that actually moved; a link with no movement for 0.5 s is
    /// stopped even while the reveal flag is still set (a cell that scrolled
    /// away never reports its completion frame).
    private var streamingFollowLastMoveAt: TimeInterval = 0
    /// True between the first reveal frame and its completion frame. While
    /// true the follower keeps running even when it momentarily reaches the
    /// current bottom, because the target is still growing.
    private var streamingFollowActive = false
    /// True between the first and last reveal height frame. While set, the
    /// instant re-pin yields to the sprung follower (otherwise the pin would
    /// satisfy the target before the follower could ever see a delta).
    private var streamingRevealActive = false
    /// Programmatic bottom return (`requestBottom(animated: true)`): the
    /// official Mover spring, not UIKit's system scroll animation.
    /// `Spring(0.4, bounce 0)` within one viewport, `Spring(0.36, bounce 0.15)`
    /// beyond it, with the one-viewport pre-place
    /// (`CANONICAL/05-layout-scroll.md` §6.4; `11-motion-haptics.md` §3.1;
    /// `EVIDENCE/round19/motion.md` P1-2). The target is re-read every frame,
    /// so content that grows during the return is still followed.
    private var returnFollowLink: CADisplayLink?
    private var returnFollowSpring = TimelineSpringFollow.Spring.ease
    private var returnFollowStartPosition: CGFloat = 0
    private var returnFollowStartTime: TimeInterval = 0
    private var returnFollowLastTime: TimeInterval = 0
    private var returnFollowLastPosition: CGFloat = 0
    #if DEBUG
    /// Number of sprung follows started; the M4 gate asserts the follower
    /// actually ran (an instant pin would leave this at zero).
    private(set) var debugStreamingFollowStarts = 0
    private(set) var debugStreamingFrameCalls = 0
    private(set) var debugStreamingFollowEligibleFrames = 0
    #endif
    private var isScrollingToTop = false
    private var scrollToTopWatchdog: Task<Void, Never>?
    private var scrollToTopToken = 0
    private var bottomArrivalCallbackScheduled = false
    /// The old path passed `nil` to `withAnimation` under Reduce Motion, so a
    /// return landed immediately. The wrapper forwards the environment value.
    private var reduceMotion = false
    private var didMarkActivation = false
    private static let log = Logger(subsystem: "agents.anywhere", category: "timeline")

    /// Pull inputs. C5 sets these from the real prompt visibility and session
    /// flags; the C3 gate drives them directly.
    var olderPromptVisible = false
    var latestPromptVisible = false
    var canLoadOlder = false
    var canLoadLatest = false
    var onLoadOlder: (() -> Void)?
    var onLoadLatest: (() -> Void)?

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
    /// The page's SwiftUI safe area: composer bar + home indicator + keyboard.
    /// The list is a full-bleed representable, so this is its only inset
    /// source. The probe (run 40353074977) measured the proxy inside the
    /// `safeAreaBar` at exactly those three parts, delivered once per change
    /// inside the system animation transaction.
    var safeAreaInsets: UIEdgeInsets = .zero {
        didSet {
            guard oldValue != safeAreaInsets else { return }
            applySafeAreaInsets()
        }
    }

    /// Writes the official content inset and keeps the reader's place across
    /// the write.
    ///
    /// The official `TranscriptListSurface` does the same (`0x101a3c820`):
    /// capture `contentOffset`, set the inset under `isSettingItsOwnInset`
    /// (`0x104e3d208`), then restore the offset (`0x10418f9a0`). It computes
    /// `max(safeArea − scrollView.safeAreaInsets, 0)`; the subtraction keeps
    /// the value independent of whether UIKit also contributes the view's own
    /// safe area through automatic adjustment. AA keeps the same formula and
    /// the same system-default adjustment, so the net inset equals the page's
    /// proxy either way.
    ///
    /// The write happens inside the safe-area update's animation transaction,
    /// so it inherits the keyboard's own animation without a
    /// `UIView.animate` of our own and without keyboard notifications.
    private func applySafeAreaInsets() {
        guard isViewLoaded, let collectionView else { return }
        let viewInsets = collectionView.safeAreaInsets
        let target = UIEdgeInsets(top: max(safeAreaInsets.top - viewInsets.top, 0),
                                  left: max(safeAreaInsets.left - viewInsets.left, 0),
                                  bottom: max(safeAreaInsets.bottom - viewInsets.bottom, 0),
                                  right: max(safeAreaInsets.right - viewInsets.right, 0))
        let current = collectionView.contentInset
        let changed = abs(current.top - target.top) > 0.5
            || abs(current.left - target.left) > 0.5
            || abs(current.bottom - target.bottom) > 0.5
            || abs(current.right - target.right) > 0.5
        if changed {
            let offset = collectionView.contentOffset
            collectionView.contentInset = target
            if collectionView.contentOffset != offset {
                collectionView.setContentOffset(offset, animated: false)
            }
        }
        // A reader resting at the bottom follows the new inset (the keyboard
        // and the growing composer are the same case). A reading position is
        // kept by the offset restore above.
        guard changed, layout.contentHeight > 0,
              readerRestsAtBottom, !phase.userIsScrolling,
              !isPinningBottom else { return }
        let bottomTarget = TimelineOffsetTarget.bottomOffset(
            contentHeight: layout.contentHeight,
            containerHeight: collectionView.bounds.height,
            topInset: collectionView.adjustedContentInset.top,
            bottomInset: collectionView.adjustedContentInset.bottom)
        if abs(collectionView.contentOffset.y - bottomTarget) > 0.5 {
            collectionView.setContentOffset(
                CGPoint(x: collectionView.contentOffset.x, y: bottomTarget),
                animated: false)
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
        collectionView.showsVerticalScrollIndicator = false
        // [E] CANONICAL/05-layout-scroll.md §5 — the official surface uses
        // `keyboardDismissMode = .interactiveWithAccessory` (raw 4,
        // `0x101a3b344`), not the plain interactive mode.
        collectionView.keyboardDismissMode = .interactiveWithAccessory
        // Kept at the system default, exactly like the official surface (the
        // evidence never finds a write to this property). The official formula
        // subtracts the scroll view's own safe-area insets, so whether UIKit
        // contributes them or not the net inset is the page proxy.
        collectionView.contentInsetAdjustmentBehavior = .automatic
        applySafeAreaInsets()
        // The official surface disables UIKit's automatic self-sizing
        // invalidation; the layout owns every height. AA's controlled
        // exceptions are driven explicitly by `applyPreferredHeights` after a
        // reconfigure, so automatic invalidation would only add layout passes.
        collectionView.selfSizingInvalidation = .disabled
        collectionView.delegate = self
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
                            self.streamingRevealActive = false
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
        scheduleVisibleCellFrameSync()
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        // The list's own safe area does not drive the inset (`.never`); the
        // page's SwiftUI proxy does. Rotation and split view still change the
        // bounds, which the bottom anchor follows.
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
                toMeasure.append(item)
            }
        }
        measureSynchronously(toMeasure, width: columnWidth)
#if AA_TIMELINE_PROBE
        TimelineProbeStore.shared.noteMeasureDuration(CACurrentMediaTime() - probeApplyStart)
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
        let following = height != nil && state.isAutoScrollPinning && !animating
        streamingRevealActive = height != nil
        if let height {
            #if DEBUG
            debugStreamingFrameCalls += 1
            if following { debugStreamingFollowEligibleFrames += 1 }
            #endif
            layout.applyStreamingHeight(height, for: item.itemID,
                                        adjustOffset: !(following || animating))
            if following {
                streamingFollowActive = true
                startStreamingFollowIfNeeded()
            } else if state.isTracking || state.isDecelerating {
                stopStreamingFollow()
            }
        } else {
            layout.clearStreamingHeight(for: item.itemID)
            streamingFollowActive = false
            startStreamingFollowIfNeeded()
        }
    }

    // MARK: - Streaming bottom follow

    /// The official `Mover.ease`: step the analytic spring toward the live
    /// content bottom on a display link. The target is re-read every frame
    /// (the reveal keeps growing the row); the spring phase keeps its original
    /// start so the motion does not restart each frame.
    private func startStreamingFollowIfNeeded() {
        guard let collectionView, !navigationSuspended,
              armedBottom.isArmed, phase.phase != .animating else { return }
        let state = layoutInteractionState()
        guard !state.isTracking, !state.isDecelerating else { return }
        guard !UIAccessibility.isReduceMotionEnabled,
              !UIAccessibility.isVoiceOverRunning else {
            // Accessibility bypass: place directly, as the official reducer
            // does instead of easing.
            stopStreamingFollow()
            repinDirectly()
            return
        }
        if streamingFollowLink != nil { return }

        let target = streamingFollowEndOffset()
        let current = collectionView.contentOffset.y
        let scale = traitCollection.displayScale
        guard TimelineSpringFollow.shouldMove(
            target: target, current: current, displayScale: scale) else { return }

        let visible = streamingFollowVisibleHeight()
        // The curve is chosen from the original distance; the pre-place only
        // moves the takeoff point (official: >1 viewport pre-places, then
        // flies the remainder).
        let spring = TimelineSpringFollow.spring(
            target: target, current: current, visibleHeight: visible)
        let preplaced = TimelineSpringFollow.preplacedOffset(
            target: target, current: current, visibleHeight: visible)
        if abs(preplaced - current) >= TimelineSpringFollow.pixel(displayScale: scale) {
            collectionView.setContentOffset(
                CGPoint(x: collectionView.contentOffset.x, y: preplaced),
                animated: false)
        }
        streamingFollowSpring = spring
        streamingFollowStartPosition = collectionView.contentOffset.y
        streamingFollowStartTime = ProcessInfo.processInfo.systemUptime
        streamingFollowLastTime = streamingFollowStartTime
        streamingFollowLastPosition = streamingFollowStartPosition
        streamingFollowLastMoveAt = streamingFollowStartTime

        let maxFPS = max(60, view.window?.screen.maximumFramesPerSecond ?? 60)
        let link = CADisplayLink(target: self,
                                 selector: #selector(streamingFollowTick(_:)))
        // Official range: [maxFPS/2, maxFPS]; no preferred rate is set.
        link.preferredFrameRateRange = CAFrameRateRange(
            minimum: Float(maxFPS) / 2, maximum: Float(maxFPS),
            preferred: 0)
        link.add(to: .main, forMode: .common)
        streamingFollowLink = link
        #if DEBUG
        debugStreamingFollowStarts += 1
        #endif
    }

    @objc private func streamingFollowTick(_ link: CADisplayLink) {
        guard let collectionView else {
            stopStreamingFollow()
            return
        }
        let state = layoutInteractionState()
        guard armedBottom.isArmed, !navigationSuspended,
              phase.phase != .animating,
              !state.isTracking, !state.isDecelerating else {
            stopStreamingFollow()
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        // Another writer (keyboard snap, explicit return, inset change) moved
        // the page between frames. Re-seed the spring at the real offset so the
        // next step cannot pull it back toward the old takeoff point.
        let actual = collectionView.contentOffset.y
        if abs(actual - streamingFollowLastPosition) > 1.0 {
            streamingFollowStartPosition = actual
            streamingFollowStartTime = now
            streamingFollowLastPosition = actual
            streamingFollowLastTime = now
            streamingFollowLastMoveAt = now
        }
        let maxFPS = Double(max(60, view.window?.screen.maximumFramesPerSecond ?? 60))
        let dt = min(max(0, now - streamingFollowLastTime), 2 / maxFPS)
        let target = streamingFollowEndOffset()
        let visible = streamingFollowVisibleHeight()
        // A burst that moved the target more than two viewports: jump one
        // viewport short of the target, then fly (official catch-up distance).
        if streamingFollowActive,
           target - streamingFollowLastPosition
            > TimelineSpringFollow.catchUpDistance(visibleHeight: visible) {
            let preplaced = target - visible
            collectionView.setContentOffset(
                CGPoint(x: collectionView.contentOffset.x, y: preplaced),
                animated: false)
            streamingFollowSpring = .fly
            streamingFollowStartPosition = preplaced
            streamingFollowStartTime = now
            streamingFollowLastPosition = preplaced
            streamingFollowLastTime = now
            return
        }
        let elapsed = now - streamingFollowStartTime
        let progress = CGFloat(streamingFollowSpring.progress(at: elapsed))
        let position = streamingFollowStartPosition
            + (target - streamingFollowStartPosition) * progress
        let velocity = dt > 0
            ? (position - streamingFollowLastPosition) / CGFloat(dt) : 0
        if abs(position - streamingFollowLastPosition) >= 0.5 {
            streamingFollowLastMoveAt = now
        }
        collectionView.setContentOffset(
            CGPoint(x: collectionView.contentOffset.x, y: position),
            animated: false)
        if !streamingFollowActive, TimelineSpringFollow.hasArrived(
            target: target, position: position, velocity: velocity,
            dt: dt, displayScale: traitCollection.displayScale) {
            collectionView.setContentOffset(
                CGPoint(x: collectionView.contentOffset.x, y: target),
                animated: false)
            stopStreamingFollow()
            noteBottomArrival()
            return
        }
        // No movement for half a second and already at the target: the reveal
        // is over, or its cell scrolled away before reporting completion. A
        // later reveal frame restarts the link.
        if now - streamingFollowLastMoveAt > 0.5,
           abs(target - position) < TimelineSpringFollow.pixel(
            displayScale: traitCollection.displayScale) {
            stopStreamingFollow()
            return
        }
        streamingFollowLastTime = now
        streamingFollowLastPosition = position
    }

    private func stopStreamingFollow() {
        streamingFollowLink?.invalidate()
        streamingFollowLink = nil
    }

    private func streamingFollowVisibleHeight() -> CGFloat {
        guard let collectionView else { return 0 }
        return TimelineOffsetTarget.visibleHeight(
            containerHeight: collectionView.bounds.height,
            topInset: collectionView.adjustedContentInset.top,
            bottomInset: collectionView.adjustedContentInset.bottom)
    }

    /// The `.end` target for the streaming follow: the measured content bottom
    /// (AA has no send anchor pad).
    private func streamingFollowEndOffset() -> CGFloat {
        guard let collectionView else { return 0 }
        return TimelineOffsetTarget.bottomOffset(
            contentHeight: layout.contentHeight,
            containerHeight: collectionView.bounds.height,
            topInset: collectionView.adjustedContentInset.top,
            bottomInset: collectionView.adjustedContentInset.bottom)
    }

    /// Pin an explicit return to the bottom of a just-replaced window.
    ///
    /// UIKit re-anchors a snapshot that replaces every id; the animated target
    /// from `requestBottom` was computed against the old content height. Once
    /// the new window has laid out, pin to its measured bottom and let the
    /// ordinary follow arm keep it there through later growth.
    private func resolveWindowReplacementBottom() {
        guard let collectionView, !navigationSuspended else { return }
        // The apply completion is asynchronous: the reader may have started a
        // drag, a deceleration or a status-bar scroll-to-top after the apply
        // was enqueued. A gesture always wins over the pending return.
        guard windowReplacementReturn,
              !phase.userIsScrolling,
              !isScrollingToTop,
              !collectionView.isTracking,
              !collectionView.isDecelerating else {
            if !windowReplacementReturn {
                mode = .reading
                armedBottom.disarm()
            }
            return
        }
        collectionView.layoutIfNeeded()
        stopBottomAnimation()
        armedBottom.forceArm()
        mode = .returning
        let target = TimelineOffsetTarget.bottomOffset(
            contentHeight: layout.contentHeight,
            containerHeight: collectionView.bounds.height,
            topInset: collectionView.adjustedContentInset.top,
            bottomInset: collectionView.adjustedContentInset.bottom)
        isPinningBottom = true
        collectionView.setContentOffset(
            CGPoint(x: collectionView.contentOffset.x, y: target), animated: false)
        isPinningBottom = false
        // Settle the visible cells in this runloop: the probe's stale-cell
        // sample after a window replacement was a frame the 0.05 s frame-sync
        // pass had not applied yet.
        collectionView.layoutIfNeeded()
        noteBottomArrival()
        windowReplacementReturn = false
    }

    /// Accessibility/manual placement: pin instantly once.
    private func repinDirectly() {
        guard let collectionView, armedBottom.isArmed else { return }
        let target = streamingFollowEndOffset()
        guard abs(collectionView.contentOffset.y - target) > 0.5 else { return }
        isPinningBottom = true
        collectionView.setContentOffset(
            CGPoint(x: collectionView.contentOffset.x, y: target), animated: false)
        isPinningBottom = false
        noteBottomArrival()
    }

    // MARK: - Programmatic bottom return (official Mover spring)

    /// Official `askedForEnd` (05 §6.4): a programmatic return is the Mover
    /// spring — `Spring(0.4, bounce 0)` (`0x1019fa768`) inside one viewport,
    /// `Spring(0.36, bounce 0.15)` (`0x1019fa780`) beyond it — with the
    /// one-viewport pre-place (`11-motion-haptics.md` §3.1, part-ag §1.3/§1.5).
    /// The target is re-read every frame, so growth during the return is
    /// followed instead of being snapped to at the end.
    private func startReturnFollow() {
        guard let collectionView, !navigationSuspended else { return }
        let scale = traitCollection.displayScale
        let current = collectionView.contentOffset.y
        let target = streamingFollowEndOffset()
        guard TimelineSpringFollow.shouldMove(
            target: target, current: current, displayScale: scale) else {
            // Official dead band: less than one physical pixel is a no-op.
            finishReturnFollow(at: target)
            return
        }
        let visible = streamingFollowVisibleHeight()
        // The curve is chosen from the original distance; the pre-place only
        // moves the takeoff point (official >1 viewport: pre-place one screen,
        // then fly).
        let spring = TimelineSpringFollow.spring(
            target: target, current: current, visibleHeight: visible)
        let preplaced = TimelineSpringFollow.preplacedOffset(
            target: target, current: current, visibleHeight: visible)
        var start = current
        if abs(preplaced - current) >= TimelineSpringFollow.pixel(displayScale: scale) {
            collectionView.setContentOffset(
                CGPoint(x: collectionView.contentOffset.x, y: preplaced),
                animated: false)
            start = preplaced
        }
        returnFollowSpring = spring
        returnFollowStartPosition = start
        returnFollowStartTime = ProcessInfo.processInfo.systemUptime
        returnFollowLastTime = returnFollowStartTime
        returnFollowLastPosition = start

        let maxFPS = max(60, view.window?.screen.maximumFramesPerSecond ?? 60)
        let link = CADisplayLink(target: self,
                                 selector: #selector(returnFollowTick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(
            minimum: Float(maxFPS) / 2, maximum: Float(maxFPS), preferred: 0)
        link.add(to: .main, forMode: .common)
        returnFollowLink = link
    }

    @objc private func returnFollowTick(_ link: CADisplayLink) {
        guard let collectionView else {
            stopReturnFollow()
            return
        }
        // A reader gesture, navigation suspension or another explicit write
        // owns the page.
        guard !navigationSuspended, phase.phase == .animating else {
            stopReturnFollow()
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        let actual = collectionView.contentOffset.y
        // Another writer (keyboard snap, container anchor) moved the page
        // between frames: re-seed the spring at the real offset instead of
        // pulling it back toward the old takeoff point.
        if abs(actual - returnFollowLastPosition) > 1.0 {
            returnFollowStartPosition = actual
            returnFollowStartTime = now
            returnFollowLastTime = now
            returnFollowLastPosition = actual
        }
        let maxFPS = Double(max(60, view.window?.screen.maximumFramesPerSecond ?? 60))
        let dt = min(max(0, now - returnFollowLastTime), 2 / maxFPS)
        let target = streamingFollowEndOffset()
        let visible = streamingFollowVisibleHeight()
        // Content that pushes the bottom more than two viewports away mid
        // flight: jump one viewport short of the target, then fly (official
        // catch-up distance).
        if target - returnFollowLastPosition
            > TimelineSpringFollow.catchUpDistance(visibleHeight: visible) {
            let preplaced = target - visible
            collectionView.setContentOffset(
                CGPoint(x: collectionView.contentOffset.x, y: preplaced),
                animated: false)
            returnFollowSpring = .fly
            returnFollowStartPosition = preplaced
            returnFollowStartTime = now
            returnFollowLastTime = now
            returnFollowLastPosition = preplaced
            return
        }
        let elapsed = now - returnFollowStartTime
        let progress = CGFloat(returnFollowSpring.progress(at: elapsed))
        let position = returnFollowStartPosition
            + (target - returnFollowStartPosition) * progress
        let velocity = dt > 0
            ? (position - returnFollowLastPosition) / CGFloat(dt) : 0
        collectionView.setContentOffset(
            CGPoint(x: collectionView.contentOffset.x, y: position),
            animated: false)
        if TimelineSpringFollow.hasArrived(
            target: target, position: position, velocity: velocity,
            dt: dt, displayScale: traitCollection.displayScale) {
            finishReturnFollow(at: target)
            return
        }
        returnFollowLastTime = now
        returnFollowLastPosition = position
    }

    /// Lands the return exactly on the live target and closes the
    /// `.animating` phase the way `scrollViewDidEndScrollingAnimation` did for
    /// UIKit's native animation.
    private func finishReturnFollow(at target: CGFloat) {
        stopReturnFollow()
        bottomAnimationWatchdog?.cancel()
        guard let collectionView else { return }
        collectionView.setContentOffset(
            CGPoint(x: collectionView.contentOffset.x, y: target), animated: false)
        if phase.phase == .animating {
            let transition = phase.apply(.animationEnded)
            onPhaseChanged?(transition)
        }
        noteBottomArrival()
        // The native animation's completion used to schedule this from
        // `scrollViewDidEndScrollingAnimation`; the spring replaces it, so the
        // stale-frame check after a return must be scheduled here.
        scheduleVisibleCellSettle()
        scheduleVisibleCellFrameSync()
    }

    private func stopReturnFollow() {
        returnFollowLink?.invalidate()
        returnFollowLink = nil
    }

    /// Re-issues a bottom request that arrived with the finger down. The
    /// deceleration-end callback keeps it until the coast is truly over; a
    /// newer return already in flight supersedes it.
    private func replayPendingGestureBottomRequest() {
        guard let request = pendingGestureBottomRequest else { return }
        // A status-bar scroll-to-top owns the offset; its own end callback
        // re-evaluates the page, and a replayed return must not fight it.
        guard !isScrollingToTop, !phase.userIsScrolling,
              !collectionView.isTracking,
              !collectionView.isDecelerating else { return }
        pendingGestureBottomRequest = nil
        guard returnFollowLink == nil else { return }
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
        pendingMeasurementTask = Task { @MainActor [weak self] in
            if let self, let hosted = self.measurer as? TimelineHostingHeightMeasurer {
                hosted.updateTraitOverrides(from: self.traitCollection)
            }
            for item in pending {
                guard let self, !Task.isCancelled, self.currentItems.contains(item) else { return }
                guard let content = self.content else { return }
                // Hosted-contract rows are measured by their cell the first
                // time it materializes; there is nothing to do offscreen.
                if content.usesCellReportedHeight(for: item) { continue }
                // Parsing Markdown is main-thread work. A pending Code group
                // measured under a drag is the scroll jank the device reported
                // on 2026-10-23; the scroll-end callbacks start a fresh pass.
                if self.collectionView.isTracking || self.collectionView.isDecelerating {
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
                    // One row per runloop turn; the next parse must not stack
                    // behind this one inside a single frame.
                    await Task.yield()
                    continue
                }
                // Async Markdown is settled by the visible cell, not by this
                // hostless loop; retrying an offscreen pass would only burn
                // main-thread layout for the same 2pt answer.
                guard content.measurementContent(for: item) == .plainText else { continue }
                let key = content.heightKey(for: item, width: width)
                // Retry briefly; a visible cell's async Markdown is settled by
                // the visible-cell passes instead of this offscreen loop.
                for attempt in 0..<Self.pendingMeasurementAttempts {
                    if let height = self.measuredHeight(for: item, width: width) {
                        self.measurementPipeline.complete(item.itemID)
                        self.layout.applyMeasuredHeight(height, for: item.itemID, key: key)
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
        if phase.phase == .animating, returnFollowLink != nil {
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

    private func publishViewport() {
        let next = viewport
        guard next.isMeasured else { return }
        guard next != lastPublishedViewport else { return }
        lastPublishedViewport = next
        onViewportChanged?(next)
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
        // Official `askedForEnd` is ignored while the reader's finger is on
        // the list (part-ag §1.7); defer it (and replay after the gesture, so
        // AA still honors a send/pending request). This must run before any
        // side effect: arming the bottom here would let `repinIfArmed`
        // instant-pin the page under the finger on the next content change —
        // the device's 388 pt mechanism.
        if collectionView.isTracking {
            // Merge `forced` like `suspendedBottomRequest`: a forced request
            // queued behind a follow request must not lose its force.
            pendingGestureBottomRequest = (
                animated,
                forced || (pendingGestureBottomRequest?.forced ?? false))
            return
        }
        // An explicit bottom command (pill, send, return) owns the offset. A
        // concurrent window replacement resolves against the new content.
        if forced { armWindowReplacementReturn() }
        stopStreamingFollow()
        // A previous return (spring or native) must close its `.animating`
        // phase before this request starts another one; an interrupted
        // Reduce-Motion return would otherwise leave the phase stuck.
        stopBottomAnimation()
        userScrollSettleTask?.cancel()
        readerSettledAtBottom = false
        mode = .returning
        if forced {
            armedBottom.forceArm()
        } else if !armedBottom.isArmed {
            // Keep re-resolving the bottom while the return is in flight, the
            // same way the old `.returning` mode did on every content change.
            _ = armedBottom.armFollowing(readerRestsAtBottom: readerRestsAtBottom,
                                         mode: .returning,
                                         interactionPresented: interactionPresented,
                                         requiresNoInteraction: false)
        }
        let target = TimelineOffsetTarget.bottomOffset(contentHeight: layout.contentHeight,
            containerHeight: collectionView.bounds.height,
            topInset: collectionView.adjustedContentInset.top,
            bottomInset: collectionView.adjustedContentInset.bottom)
        if animated && !reduceMotion && !UIAccessibility.isVoiceOverRunning {
            // Official `askedForEnd` (05 §6.4) / Mover: the return is a spring,
            // not a UIKit scroll animation. The follower re-reads the live
            // bottom target each frame; the watchdog only covers a stalled
            // display link. Coasting is halted by the first spring frame
            // (official: coasting 先 halt, 再 animate).
            let transition = phase.apply(.animationBegan)
            onPhaseChanged?(transition)
            startBottomAnimationWatchdog()
            startReturnFollow()
        } else {
            // Reduce Motion / VoiceOver: the official reducer places directly.
            collectionView.setContentOffset(CGPoint(x: collectionView.contentOffset.x, y: target), animated: false)
            noteBottomArrival()
        }
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
        armedBottom.forceArm()
        mode = .returning
        snapToBottom()
        // A no-op snap (already at the bottom) must still recycle the forced
        // arm/mode; otherwise a later growth re-pins once as a "forced" target.
        noteBottomArrival()
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

    /// Follow requests (sending, a new pending bubble) only arm when the
    /// reader rests at the bottom or is already returning; explicit commands
    /// call `requestBottom` directly, exactly like the SwiftUI state machine.
    @discardableResult
    func requestFollowingBottom(requiresNoInteraction: Bool) -> Bool {
        guard !navigationSuspended else { return false }
        let armMode: TimelineScrollState.Mode = armedBottom.isArmed ? .following : mode
        guard armedBottom.armFollowing(readerRestsAtBottom: readerRestsAtBottom,
                                       mode: armMode,
                                       interactionPresented: interactionPresented,
                                       requiresNoInteraction: requiresNoInteraction) else { return false }
        requestBottom(animated: true, forced: false)
        return true
    }

    @discardableResult
    func armFollowingBottom(readerRestsAtBottom: Bool, mode: TimelineScrollState.Mode,
                            interactionPresented: Bool, requiresNoInteraction: Bool) -> Bool {
        armedBottom.armFollowing(readerRestsAtBottom: readerRestsAtBottom, mode: mode,
            interactionPresented: interactionPresented, requiresNoInteraction: requiresNoInteraction)
    }

    func disarmBottom() { armedBottom.disarm() }

    func readerDidRestAtBottom(_ rests: Bool, interactionPresented: Bool) {
        _ = armedBottom.readerDidRestAtBottom(readerRestsAtBottom: rests,
                                              interactionPresented: interactionPresented)
    }

    /// An approval appearing stops automatic following; its disappearance is
    /// an explicit return (the old `setInteractionPresented`).
    func setInteractionPresented(_ presented: Bool) {
        guard interactionPresented != presented else { return }
        interactionPresented = presented
        if presented {
            stopBottomAnimation()
            armedBottom.disarm()
            mode = .reading
        } else {
            requestBottom(animated: true, forced: true)
        }
    }

    private func endScrollToTopTracking() {
        scrollToTopToken &+= 1
        scrollToTopWatchdog?.cancel()
        isScrollingToTop = false
    }

    /// Stops the in-flight programmatic return. The old view released its
    /// `ScrollPosition` target on the same edges (approval appears, drawer
    /// moves); leaving the motion running would still pull the page.
    private func stopBottomAnimation() {
        bottomAnimationWatchdog?.cancel()
        stopReturnFollow()
        guard let collectionView, phase.phase == .animating else { return }
        collectionView.setContentOffset(collectionView.contentOffset, animated: false)
        let transition = phase.apply(.watchdogExpired)
        onPhaseChanged?(transition)
    }

    // MARK: - Container anchoring

    /// The old timeline's `.defaultScrollAnchor(.bottom, for: .sizeChanges)`:
    /// a container height change (split view, rotation) keeps the newest row at
    /// the input bar. Content-size changes are not anchored here; those follow
    /// only while the bottom target is armed.
    ///
    /// Inset-only changes (keyboard, composer height) do not come through
    /// here: `applySafeAreaInsets` writes them inside the safe-area update's
    /// animation transaction and follows the bottom only when the reader rests
    /// there.
    private func handleContainerHeightChange() {
        guard let collectionView else { return }
        let height = collectionView.bounds.height
        let heightChanged = lastContainerHeight > 0 && abs(height - lastContainerHeight) > 0.5
        lastContainerHeight = height
        guard heightChanged, !navigationSuspended, !phase.userIsScrolling else { return }
        snapToBottom()
        noteBottomArrival()
    }

    private func snapToBottom() {
        guard !isPinningBottom, let collectionView else { return }
        let target = TimelineOffsetTarget.bottomOffset(contentHeight: layout.contentHeight,
            containerHeight: collectionView.bounds.height,
            topInset: collectionView.adjustedContentInset.top,
            bottomInset: collectionView.adjustedContentInset.bottom)
        guard abs(collectionView.contentOffset.y - target) > 0.5 else { return }
        isPinningBottom = true
        collectionView.setContentOffset(CGPoint(x: collectionView.contentOffset.x, y: target), animated: false)
        isPinningBottom = false
    }

    private func noteBottomArrival() {
        // A zero content height is an unprepared layout, not an arrival:
        // `measuredAtBottom` is true for any viewport taller than the
        // (empty) content. Arming there would pin the page on the first
        // measured growth.
        guard viewport.contentHeight > 0,
              !isScrollingToTop, !phase.userIsScrolling,
              viewport.measuredAtBottom else { return }
        readerRestsAtBottom = true
        if mode == .returning { mode = interactionPresented ? .reading : .following }
        if interactionPresented {
            // A presented approval owns the page until it resolves; an
            // opening/forced target that happened to land must not keep
            // re-pinning on later stream growth.
            armedBottom.disarm()
        } else if mode != .reading,
                  armedBottom.source == .forced || armedBottom.source == nil {
            // Only a return (`.returning`) or an already-following page turns
            // an arrival into persistence. A programmatic offset change while
            // the mode is `.reading` is not a reader gesture and must not
            // start following.
            armedBottom.disarm()
            armedBottom.readerDidRestAtBottom(readerRestsAtBottom: true,
                                              interactionPresented: false)
        }
        if onBottomArrived != nil, !bottomArrivalCallbackScheduled {
            // `noteBottomArrival` can run inside `prepare`; never mutate
            // SwiftUI model state from a layout pass.
            bottomArrivalCallbackScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.bottomArrivalCallbackScheduled = false
                self.onBottomArrived?()
            }
        }
    }

    private func scheduleUserScrollSettle() {
        userScrollSettleTask?.cancel()
        userScrollSettleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(64))
            guard let self, !Task.isCancelled else { return }
            self.settleUserScroll()
        }
    }

    /// I31: a stop at the measured bottom resumes following; a stop in
    /// history leaves the reader in reading mode (the explicit return pill,
    /// C5, is their way back).
    private func settleUserScroll() {
        if phase.userIsScrolling {
            // Deceleration outlived the 64 ms window; judge after it ends.
            scheduleUserScrollSettle()
            return
        }
        guard !navigationSuspended, mode != .returning else { return }
        let rests = viewport.contentHeight > 0
            && (readerSettledAtBottom || viewport.measuredAtBottom)
        readerSettledAtBottom = false
        readerRestsAtBottom = rests
        if rests, !interactionPresented {
            mode = .following
            armedBottom.readerDidRestAtBottom(readerRestsAtBottom: true, interactionPresented: false)
        } else {
            mode = .reading
        }
    }

    /// Nominal official ease duration (`Spring(0.4, bounce 0)`); the analytic
    /// spring needs longer to fall under one physical pixel, so the watchdog
    /// below is a stalled-display-link cap, not the expected completion.
    private static let returnAnimationDuration: TimeInterval = 0.4
    /// A display link that never delivers its arrival frame must not leave
    /// the phase `.animating` (which would block every settle pass). The
    /// margin covers the spring's sub-pixel settling time.
    private static let returnWatchdog = Duration.milliseconds(
        Int((returnAnimationDuration + 1.1) * 1000))

    private func startBottomAnimationWatchdog() {
        bottomAnimationWatchdog?.cancel()
        bottomAnimationWatchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.returnWatchdog)
            guard let self, !Task.isCancelled, self.phase.phase == .animating else { return }
            // The spring follower stalled (backgrounded, display link starved,
            // or a target that kept moving): land on the live bottom.
            self.stopReturnFollow()
            if let collectionView = self.collectionView {
                collectionView.setContentOffset(
                    CGPoint(x: collectionView.contentOffset.x,
                            y: self.streamingFollowEndOffset()),
                    animated: false)
            }
            let transition = self.phase.apply(.watchdogExpired)
            self.onPhaseChanged?(transition)
            // The display link is the normal arrival signal; a starved or
            // interrupted one must still close the phase or the settle passes
            // stay blocked behind `.animating`.
            self.noteBottomArrival()
            self.scheduleVisibleCellSettle()
        }
    }

    private func repinIfArmed() {
        // The reveal follower and the programmatic-return spring own the
        // offset while they run; an instant pin here would fight them on every
        // content change.
        guard streamingFollowLink == nil, returnFollowLink == nil else { return }
        // Official: dragging/coasting produces no placement (part-ag §1.7).
        // Pinning under the finger is the device's 388 pt mechanism. The
        // bottom target stays armed; the gesture-end path re-evaluates it.
        guard !isUserScrolling else { return }
        // A streaming height change arrives here *after* prepare refreshed
        // `layout.contentHeight` and before any pin, so this is the one place
        // the follower can see a real target delta. Start it instead of
        // pinning; if it cannot start, fall through to the instant pin.
        if streamingRevealActive, !isPinningBottom {
            let state = layoutInteractionState()
            if state.isAutoScrollPinning,
               !state.isTracking, !state.isDecelerating,
               phase.phase != .animating {
                startStreamingFollowIfNeeded()
                if streamingFollowLink != nil { return }
            }
        }
        guard !isPinningBottom, armedBottom.isArmed else { return }
        guard let target = armedBottom.contentChanged(contentHeight: layout.contentHeight,
            containerHeight: collectionView.bounds.height,
            topInset: collectionView.adjustedContentInset.top,
            bottomInset: collectionView.adjustedContentInset.bottom) else { return }
        guard abs(collectionView.contentOffset.y - target) > 0.5 else { return }
        isPinningBottom = true
        collectionView.setContentOffset(CGPoint(x: collectionView.contentOffset.x, y: target), animated: false)
        isPinningBottom = false
        noteBottomArrival()
    }

    // MARK: - Pull

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
            if content.rowIDs(in: item).contains(anchorRowID) {
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
        // Loading older is a browsing action. Stop any follow target before
        // the prepend's content-size changes: a still-armed bottom would pin
        // the page and the absolute anchor could never hold.
        armedBottom.disarm()
        mode = .reading
        readerRestsAtBottom = false
        readerSettledAtBottom = false
        userScrollSettleTask?.cancel()
        stopBottomAnimation()
        measureSynchronously(newItems, width: columnWidth)
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
        if suspended {
            layout.cancelBrowsingCorrections()
            olderPull.cancel()
            latestPull.cancel()
            pendingMeasurementTask?.cancel()
            stopBottomAnimation()
            pendingGestureBottomRequest = nil
            userScrollSettleTask?.cancel()
            armedBottom.disarm()
            mode = .reading
            readerSettledAtBottom = false
            endScrollToTopTracking()
        } else {
            // An interrupted animation has no completion; clear the phase so
            // the next reader gesture is not read as an animation completion.
            if phase.phase == .animating {
                let transition = phase.apply(.watchdogExpired)
                onPhaseChanged?(transition)
            }
            let rests = viewport.measuredAtBottom
            readerRestsAtBottom = rests
            if rests, !interactionPresented {
                mode = .following
                armedBottom.navigationResumed(readerRestsAtBottom: true,
                                              interactionPresented: false)
                repinIfArmed()
            } else {
                mode = .reading
            }
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
        state.hasArmedBottomTarget = armedBottom.isArmed
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
        state.mode = mode
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
            stopStreamingFollow()
            stopReturnFollow()
            windowReplacementReturn = false
            bottomAnimationWatchdog?.cancel()
            userScrollSettleTask?.cancel()
            endScrollToTopTracking()
            _ = phase.apply(.willBeginDragging)
            layout.noteDragWillBegin()
            armedBottom.disarm()
            mode = .reading
            readerRestsAtBottom = false
            readerSettledAtBottom = false
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
        layout.noteDragDidEnd(willDecelerate: decelerated)
        if decelerated {
            _ = phase.apply(.didEndDecelerating)
            layout.noteDecelerationDidEnd()
        }
        readerSettledAtBottom = viewport.measuredAtBottom
        scheduleVisibleCellSettle()
        scheduleVisibleCellFrameSync()
        schedulePendingMeasurements()
        scheduleUserScrollSettle()
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
        repinIfArmed()
        noteBottomArrival()
        onContentHeightChanged?(height)
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

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        guard !navigationSuspended else { return }
        // The reader's finger always wins over the streaming follow and over
        // a window replacement whose return has not resolved yet.
        stopStreamingFollow()
        stopReturnFollow()
        windowReplacementReturn = false
        bottomAnimationWatchdog?.cancel()
        userScrollSettleTask?.cancel()
        endScrollToTopTracking()
        let transition = phase.apply(.willBeginDragging)
        onPhaseChanged?(transition)
        layout.noteDragWillBegin()
        armedBottom.disarm()
        mode = .reading
        readerRestsAtBottom = false
        readerSettledAtBottom = false
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
        noteBottomArrival()
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
        }
        if !decelerate { readerSettledAtBottom = viewport.measuredAtBottom }
        layout.noteDragDidEnd(willDecelerate: decelerate)
        scheduleVisibleCellSettle()
        scheduleVisibleCellFrameSync()
        schedulePendingMeasurements()
        scheduleUserScrollSettle()
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
        }
        readerSettledAtBottom = viewport.measuredAtBottom
        layout.noteDecelerationDidEnd()
        scheduleVisibleCellSettle()
        scheduleVisibleCellFrameSync()
        schedulePendingMeasurements()
        scheduleUserScrollSettle()
        scheduleVisibleCellSettle()
        publishViewport()
        replayPendingGestureBottomRequest()
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        bottomAnimationWatchdog?.cancel()
        let transition = phase.apply(.animationEnded)
        onPhaseChanged?(transition)
        scheduleVisibleCellSettle()
        scheduleVisibleCellFrameSync()
        noteBottomArrival()
        publishViewport()
    }

    func scrollViewShouldScrollToTop(_ scrollView: UIScrollView) -> Bool {
        guard !navigationSuspended else { return false }
        isScrollingToTop = true
        scrollToTopToken &+= 1
        let token = scrollToTopToken
        scrollToTopWatchdog?.cancel()
        scrollToTopWatchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard let self, !Task.isCancelled, self.scrollToTopToken == token,
                  self.isScrollingToTop else { return }
            // A no-op scroll-to-top may not call `didScrollToTop`; holding the
            // flag would block every later bottom arrival.
            self.isScrollingToTop = false
        }
        // The status-bar scroll owns the offset; a pending bottom return must
        // not keep its display link or watchdog running into this animation.
        stopReturnFollow()
        bottomAnimationWatchdog?.cancel()
        let transition = phase.apply(.scrollToTopBegan)
        onPhaseChanged?(transition)
        userScrollSettleTask?.cancel()
        // The reader asked for the top; a pending window return must not
        // resolve once its apply completion arrives.
        windowReplacementReturn = false
        armedBottom.disarm()
        mode = .reading
        readerRestsAtBottom = false
        readerSettledAtBottom = false
        return true
    }

    func scrollViewDidScrollToTop(_ scrollView: UIScrollView) {
        guard !navigationSuspended else { return }
        endScrollToTopTracking()
        let transition = phase.apply(.scrollToTopEnded)
        onPhaseChanged?(transition)
        armedBottom.disarm()
        mode = .reading
        readerRestsAtBottom = false
        publishViewport()
    }
}

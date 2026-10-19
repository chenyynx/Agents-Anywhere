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
    private var lastReloadGeneration = Int.min
    private var signatures = TimelineContentSignatures()
    private var measurementPipeline = TimelineMeasurementPipeline(budgetMilliseconds: .max)
    private var pendingApply: (items: [TimelineListItem], animating: Bool)?
    private var pendingMeasurementTask: Task<Void, Never>?
    private var bottomAnimationWatchdog: Task<Void, Never>?
    private var lastPublishedViewport = TimelineViewport()

    private(set) var phase = TimelinePhaseMapping()
    private(set) var armedBottom = TimelineArmedBottomTarget()
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
    /// Commands that arrive while the drawer owns navigation. The old state
    /// machine refused the native command but kept the intent; resume replays
    /// it exactly once instead of silently dropping a pending/approval return.
    private var suspendedBottomRequest: (animated: Bool, forced: Bool)?
    private var suspendedOpeningRequest = false
    private var lastContainerHeight: CGFloat = 0
    private var lastBottomInset: CGFloat = 0
    private var keyboardVisible = false
    private var keyboardTransitionActive = false
    private var keyboardTransitionToken = 0
    private var keyboardTransitionTask: Task<Void, Never>?
    private var userScrollSettleTask: Task<Void, Never>?
    private var isPinningBottom = false
    private var isScrollingToTop = false
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
        collectionView.alwaysBounceVertical = true
        collectionView.showsVerticalScrollIndicator = false
        collectionView.keyboardDismissMode = .interactive // I7
        collectionView.contentInsetAdjustmentBehavior = .automatic
        // The official surface disables UIKit's automatic self-sizing
        // invalidation; the layout owns every height. AA's controlled
        // exceptions are driven explicitly by `applyPreferredHeights` after a
        // reconfigure, so automatic invalidation would only add layout passes.
        collectionView.selfSizingInvalidation = .disabled
        collectionView.delegate = self
        collectionView.register(TimelineHostingCell.self,
                                forCellWithReuseIdentifier: TimelineHostingCell.reuseIdentifier)
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
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: TimelineHostingCell.reuseIdentifier,
                                                          for: indexPath) as! TimelineHostingCell
            if let self, let content = self.content {
                cell.configure(content.rowView(for: item), policy: content.heightPolicy(for: item))
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
        pinBottomForKeyboardIfNeeded()
        handleContainerHeightChange()
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        // The keyboard and the composer both arrive as safe-area changes; the
        // old timeline anchored every container-size change to the bottom
        // (`.defaultScrollAnchor(.bottom, for: .sizeChanges)`). Re-evaluate
        // after the inset has settled as well as on bounds changes, and run
        // the per-frame keyboard pin here too: an inset-only change may never
        // move `bounds.height`.
        pinBottomForKeyboardIfNeeded()
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
        let oldItems = currentItems
        let oldIDs = Set(oldItems)
        let entries: [TimelineContentEntry] = items.map { item in
            TimelineContentEntry(item: item, signature: content.contentSignature(for: item))
        }
        let change = signatures.update(entries)
        // A content change and a key change are not the same set: rotation,
        // Dynamic Type and a typography setting produce a new width/key with
        // an unchanged signature. Measure anything the cache has no real
        // height for, and reconfigure every cell whose key moved: the cell's
        // SwiftUI text reads the type scale from UserDefaults, which is not
        // observable, so a new height without a reconfigure would pair the
        // new frame with the old font.
        let changed = Set(change.changed)
        var toMeasure: [TimelineListItem] = []
        var reconfigure = changed
        for item in items {
            let key = content.heightKey(for: item, width: columnWidth)
            if layout.heights.currentKey(for: item.itemID) != key {
                reconfigure.insert(item)
            }
            if changed.contains(item) || !layout.heights.hasMeasuredOrPrecalcHeight(for: key) {
                toMeasure.append(item)
            }
        }
        measureSynchronously(toMeasure, width: columnWidth)

        var snapshot = NSDiffableDataSourceSnapshot<TimelineCollectionSection, TimelineListItem>()
        snapshot.appendSections([.main])
        snapshot.appendItems(items)
        let existingChanges = items.filter { oldIDs.contains($0) && reconfigure.contains($0) }
        if !existingChanges.isEmpty { snapshot.reconfigureItems(existingChanges) }
        currentItems = items
        dataSource.apply(snapshot, animatingDifferences: animating) { [weak self] in
            self?.onApplyCompleted?()
            self?.schedulePendingMeasurements()
            self?.publishViewport()
        }
    }

    /// Re-renders existing cells without touching signatures or measurement.
    /// This is the C3 gate's fold/tail path: the cell's preferred height is
    /// the correction signal, exactly as a disclosure toggle behaves.
    func reconfigure(_ items: [TimelineListItem]) {
        guard dataSource != nil else { return }
        var snapshot = dataSource.snapshot()
        let present = items.filter { snapshot.itemIdentifiers.contains($0) }
        guard !present.isEmpty else { return }
        snapshot.reconfigureItems(present)
        dataSource.apply(snapshot, animatingDifferences: false) { [weak self] in
            // The hosting cell has no heightDidChange callback; ask the
            // visible exception rows for their fitting height after the new
            // content has laid out.
            DispatchQueue.main.async { [weak self] in self?.applyPreferredHeights(for: present) }
        }
    }

    private func applyPreferredHeights(for items: [TimelineListItem]) {
        settlePreferredHeights(for: items, attempt: 0)
    }

    /// The hosting content of a reconfigured exception row updates on a later
    /// layout pass. The first gate run read the old collapsed fitting height
    /// (248.7) while the content had already expanded (404.3); a single
    /// immediate read is racy. Poll the cell's content fitting for a few
    /// frames and apply when it changes. This is the explicit replacement for
    /// the heightDidChange callback AA's hosting rows do not have.
    private(set) var preferredDiagnostics: [String: Int] = [:]

    private func notePreferred(_ key: String) {
        preferredDiagnostics[key, default: 0] += 1
    }

    private func settlePreferredHeights(for items: [TimelineListItem], attempt: Int) {
        guard let content, attempt <= 9 else { return }
        notePreferred("pass")
        for item in items {
            notePreferred("item")
            guard content.heightPolicy(for: item).acceptsPreferredHeight else {
                notePreferred("notInteractive"); continue
            }
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
            let current = layout.attributes(for: item.itemID)?.frame.height ?? 0
            if abs(fitting - current) > 0.5 {
                notePreferred("applyRequested")
                layout.applyPreferredHeight(ceil(fitting), for: item.itemID)
                // The controller owns this correction path; force the layout
                // pass so the new value is observable in the same turn.
                collectionView.layoutIfNeeded()
            } else {
                notePreferred("alreadyEqual")
            }
        }
        // Poll several frames: the hosting content can report its old size on
        // the first pass and the new size only after SwiftUI lays out.
        guard attempt < 9 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.settlePreferredHeights(for: items, attempt: attempt + 1)
        }
    }

    private func measureSynchronously(_ items: [TimelineListItem], width: CGFloat) {
        guard let content, let measurer, width > 0 else { return }
        // A typography change re-keys every row in the same SwiftUI update that
        // calls this measurement, before the next layout pass. Sync the
        // measurer's traits now, or the new key caches an old-type height.
        if let hosted = measurer as? TimelineHostingHeightMeasurer {
            hosted.updateTraitOverrides(from: traitCollection)
        }
        let requests = items.compactMap { item -> TimelineMeasurementRequest? in
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
            guard let height = measurer.measure(itemID: request.itemID, width: width) else { continue }
            layout.heights.set(height, for: request.key, tier: .measured)
        }
    }

    private func schedulePendingMeasurements() {
        pendingMeasurementTask?.cancel()
        let pending = layout.pendingMeasurements
        guard !pending.isEmpty, let measurer, columnWidth > 0 else { return }
        let width = columnWidth
        pendingMeasurementTask = Task { @MainActor [weak self] in
            if let self, let hosted = self.measurer as? TimelineHostingHeightMeasurer {
                hosted.updateTraitOverrides(from: self.traitCollection)
            }
            for item in pending {
                guard let self, !Task.isCancelled, self.currentItems.contains(item) else { return }
                guard let content = self.content else { return }
                let key = content.heightKey(for: item, width: width)
                // A hosted Markdown view parses asynchronously; a nil/zero
                // first pass is expected. Retry briefly before leaving the row
                // on displayed/estimate height.
                for attempt in 0..<4 {
                    if let height = measurer.measure(itemID: item.itemID, width: width) {
                        self.measurementPipeline.complete(item.itemID)
                        self.layout.applyMeasuredHeight(height, for: item.itemID, key: key)
                        break
                    }
                    if attempt < 3 {
                        try? await Task.sleep(for: .milliseconds(150))
                    }
                    if Task.isCancelled { return }
                }
                await Task.yield()
            }
        }
    }

    /// Re-measures one row on demand (the gate's async-Markdown settle step).
    func remeasure(_ item: TimelineListItem) {
        guard let content, let measurer, columnWidth > 0 else { return }
        let width = columnWidth
        let key = content.heightKey(for: item, width: width)
        guard let height = measurer.measure(itemID: item.itemID, width: width) else { return }
        measurementPipeline.complete(item.itemID)
        layout.applyMeasuredHeight(height, for: item.itemID, key: key)
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
            offsetY: collectionView.contentOffset.y)
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

    /// Forced commands (pill / loadLatest / approval dismissed / window
    /// re-assert) arm unconditionally; follow requests use the gated arm.
    func requestBottom(animated: Bool, forced: Bool = true) {
        if navigationSuspended {
            suspendedBottomRequest = (animated, forced || (suspendedBottomRequest?.forced ?? false))
            return
        }
        guard collectionView != nil else { return }
        userScrollSettleTask?.cancel()
        bottomAnimationWatchdog?.cancel()
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
        if animated && !reduceMotion {
            let transition = phase.apply(.animationBegan)
            onPhaseChanged?(transition)
            collectionView.setContentOffset(CGPoint(x: collectionView.contentOffset.x, y: target), animated: true)
            startBottomAnimationWatchdog()
        } else {
            collectionView.setContentOffset(CGPoint(x: collectionView.contentOffset.x, y: target), animated: false)
            noteBottomArrival()
        }
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

    /// Stops UIKit's in-flight animated return. The old view released its
    /// `ScrollPosition` target on the same edges (approval appears, drawer
    /// moves); leaving the native animation running would still pull the page.
    private func stopBottomAnimation() {
        bottomAnimationWatchdog?.cancel()
        guard let collectionView, phase.phase == .animating else { return }
        collectionView.setContentOffset(collectionView.contentOffset, animated: false)
        let transition = phase.apply(.watchdogExpired)
        onPhaseChanged?(transition)
    }

    // MARK: - Keyboard and container anchoring

    func setKeyboardVisible(_ visible: Bool) {
        // Visibility only decides whether the per-frame pin runs. The hide
        // animation keeps its transition window; its scheduled end releases
        // the pin (same split as the old keyboard monitor).
        keyboardVisible = visible
    }

    /// A keyboard event restarts the transition window; a superseded end must
    /// not close a newer window. Inside the window the keyboard's own pin owns
    /// the offset, so the armed target pauses its content-size repin.
    func beginKeyboardTransition(duration: TimeInterval) {
        keyboardTransitionToken &+= 1
        let token = keyboardTransitionToken
        keyboardTransitionActive = true
        armedBottom.setKeyboardTransition(true)
        keyboardTransitionTask?.cancel()
        keyboardTransitionTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(max(duration, 0)))
            guard let self, !Task.isCancelled, self.keyboardTransitionToken == token else { return }
            self.endKeyboardTransition()
        }
    }

    func endKeyboardTransition() {
        guard keyboardTransitionActive else { return }
        keyboardTransitionActive = false
        keyboardTransitionToken &+= 1
        keyboardTransitionTask?.cancel()
        armedBottom.setKeyboardTransition(false)
        repinIfArmed()
        publishViewport()
    }

    /// The old timeline's `.defaultScrollAnchor(.bottom, for: .sizeChanges)`:
    /// a container height change (composer growth, rotation, keyboard) keeps
    /// the newest row at the input bar. Content-size changes are not anchored
    /// here; those follow only while the bottom target is armed.
    private func handleContainerHeightChange() {
        guard let collectionView else { return }
        let height = collectionView.bounds.height
        let heightChanged = lastContainerHeight > 0 && abs(height - lastContainerHeight) > 0.5
        lastContainerHeight = height
        // `.automatic` turns safe-area changes into adjusted content inset;
        // an inset-only keyboard/composer change must anchor too.
        let bottomInset = collectionView.adjustedContentInset.bottom
        let insetChanged = lastBottomInset > 0 && abs(bottomInset - lastBottomInset) > 0.5
        lastBottomInset = bottomInset
        guard heightChanged || insetChanged, !navigationSuspended else { return }
        // Interactive keyboard dismissal shrinks the container while the
        // finger is down; the keyboard's own pin is muted then, and this
        // anchor must not fight the gesture either.
        guard !(keyboardVisible && phase.userIsScrolling) else { return }
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

    private func pinBottomForKeyboardIfNeeded() {
        // `readerRestsAtBottom` is the pre-keyboard geometric truth. The
        // current viewport may already be short because the keyboard is moving
        // it; requiring `measuredAtBottom` here would refuse exactly the frames
        // the pin exists for.
        guard keyboardTransitionActive, keyboardVisible, readerRestsAtBottom,
              !interactionPresented, !navigationSuspended, viewport.isMeasured else { return }
        snapToBottom()
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

    private static let returnAnimationDuration: TimeInterval = 0.28
    private static let returnWatchdog = Duration.milliseconds(
        Int((returnAnimationDuration + 1.0 / 60.0) * 1000))

    private func startBottomAnimationWatchdog() {
        bottomAnimationWatchdog?.cancel()
        bottomAnimationWatchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.returnWatchdog)
            guard let self, !Task.isCancelled, self.phase.phase == .animating else { return }
            let transition = self.phase.apply(.watchdogExpired)
            self.onPhaseChanged?(transition)
            // A no-op animated return never calls
            // `scrollViewDidEndScrollingAnimation` (measured 0 in the spike),
            // so the watchdog is the only arrival signal for that shape.
            self.noteBottomArrival()
        }
    }

    private func repinIfArmed() {
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
        olderPull.begin(at: viewport, promptVisible: olderPromptVisible, canLoad: canLoadOlder)
        latestPull.begin(at: viewport, promptVisible: latestPromptVisible, canLoad: canLoadLatest)
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
            let height = layout.heights.resolvedHeight(for: key, itemID: item.itemID,
                fallback: content.estimateKind(for: item))
            if index == 0 { firstRowID = content.rowIDs(in: item).first ?? item.itemID }
            if content.rowIDs(in: item).contains(anchorRowID) {
                return TimelineHistoryLayout(firstRowID: firstRowID ?? item.itemID,
                    anchorRowID: anchorRowID, edge: edge,
                    y: edge == .top ? y : y + height)
            }
            y += height
            if index < items.count - 1 { y += TimelineListMetrics.itemSpacing }
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
        measureSynchronously(newItems, width: columnWidth)
        guard let projected = projectedHistoryLayout(items: newItems,
                                                     anchorRowID: anchorRowID, edge: edge) else { return nil }
        let position = TimelineHistoryPosition(id: generation, layout: origin,
            offsetY: collectionView.contentOffset.y, topInset: collectionView.adjustedContentInset.top)
        layout.beginInsertionOwed(generation: generation, origin: origin,
            offsetY: collectionView.contentOffset.y, topInset: collectionView.adjustedContentInset.top)
        layout.updateInsertionOwed(layout: projected)
        return position
    }

    func cancelHistoryRequest() {
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
            userScrollSettleTask?.cancel()
            armedBottom.disarm()
            mode = .reading
            readerSettledAtBottom = false
            isScrollingToTop = false
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
        state.keyboardTransition = keyboardTransitionActive
        state.interactionPresented = interactionPresented
        state.mode = mode
        state.suppressContentOffsetAdjustment = navigationSuspended
        return state
    }

    func layoutDidSettlePull() { settlePulls() }

    func layoutDidChangeContentHeight(_ height: CGFloat) {
        publishViewport()
        pinBottomForKeyboardIfNeeded()
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

extension TimelineCollectionController: UICollectionViewDelegate {
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        guard !navigationSuspended else { return }
        bottomAnimationWatchdog?.cancel()
        userScrollSettleTask?.cancel()
        isScrollingToTop = false
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
        let current = viewport
        if phase.phase == .interacting || phase.phase == .decelerating { updatePulls(current) }
        pinBottomForKeyboardIfNeeded()
        publishViewport()
        noteBottomArrival()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        guard !navigationSuspended else { return }
        let transition = phase.apply(.didEndDragging(willDecelerate: decelerate))
        onPhaseChanged?(transition)
        if !decelerate { readerSettledAtBottom = viewport.measuredAtBottom }
        layout.noteDragDidEnd(willDecelerate: decelerate)
        scheduleUserScrollSettle()
        publishViewport()
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        guard !navigationSuspended else { return }
        let transition = phase.apply(.didEndDecelerating)
        onPhaseChanged?(transition)
        readerSettledAtBottom = viewport.measuredAtBottom
        layout.noteDecelerationDidEnd()
        scheduleUserScrollSettle()
        publishViewport()
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        bottomAnimationWatchdog?.cancel()
        let transition = phase.apply(.animationEnded)
        onPhaseChanged?(transition)
        noteBottomArrival()
        publishViewport()
    }

    func scrollViewShouldScrollToTop(_ scrollView: UIScrollView) -> Bool {
        guard !navigationSuspended else { return false }
        isScrollingToTop = true
        let transition = phase.apply(.scrollToTopBegan)
        onPhaseChanged?(transition)
        userScrollSettleTask?.cancel()
        armedBottom.disarm()
        mode = .reading
        readerRestsAtBottom = false
        readerSettledAtBottom = false
        return true
    }

    func scrollViewDidScrollToTop(_ scrollView: UIScrollView) {
        guard !navigationSuspended else { return }
        isScrollingToTop = false
        let transition = phase.apply(.scrollToTopEnded)
        onPhaseChanged?(transition)
        armedBottom.disarm()
        mode = .reading
        readerRestsAtBottom = false
        publishViewport()
    }
}

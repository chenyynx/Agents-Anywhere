import SwiftUI
import UIKit

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
    enum Section { case main }

    let layout = TimelineListLayout()
    private(set) var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, TimelineListItem>!
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
        collectionView.contentInsetAdjustmentBehavior = .automatic
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
        if let pending = pendingApply, columnWidth > 0 {
            pendingApply = nil
            apply(items: pending.items, animating: pending.animating)
        }
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
        let toMeasure = change.changed
        measureSynchronously(toMeasure, width: columnWidth)

        var snapshot = NSDiffableDataSourceSnapshot<Section, TimelineListItem>()
        snapshot.appendSections([.main])
        snapshot.appendItems(items)
        let existingChanges = change.changed.filter { oldIDs.contains($0) }
        if !existingChanges.isEmpty { snapshot.reconfigureItems(existingChanges) }
        currentItems = items
        dataSource.apply(snapshot, animatingDifferences: animating) { [weak self] in
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
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func measureSynchronously(_ items: [TimelineListItem], width: CGFloat) {
        guard let content, let measurer, width > 0 else { return }
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
        guard collectionView != nil else { return }
        if forced { armedBottom.forceArm() }
        let target = TimelineOffsetTarget.bottomOffset(contentHeight: layout.contentHeight,
            containerHeight: collectionView.bounds.height,
            topInset: collectionView.adjustedContentInset.top,
            bottomInset: collectionView.adjustedContentInset.bottom)
        if animated {
            let transition = phase.apply(.animationBegan)
            onPhaseChanged?(transition)
            collectionView.setContentOffset(CGPoint(x: collectionView.contentOffset.x, y: target), animated: true)
            startBottomAnimationWatchdog()
        } else {
            collectionView.setContentOffset(CGPoint(x: collectionView.contentOffset.x, y: target), animated: false)
        }
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
        }
    }

    private func repinIfArmed() {
        guard armedBottom.isArmed else { return }
        guard let target = armedBottom.contentChanged(contentHeight: layout.contentHeight,
            containerHeight: collectionView.bounds.height,
            topInset: collectionView.adjustedContentInset.top,
            bottomInset: collectionView.adjustedContentInset.bottom) else { return }
        guard abs(collectionView.contentOffset.y - target) > 0.5 else { return }
        collectionView.setContentOffset(CGPoint(x: collectionView.contentOffset.x, y: target), animated: false)
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
        if suspended {
            layout.cancelBrowsingCorrections()
            olderPull.cancel()
            latestPull.cancel()
            pendingMeasurementTask?.cancel()
            bottomAnimationWatchdog?.cancel()
            armedBottom.disarm()
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
        state.isTracking = false // native drags report `.interacting`, not `.tracking`
        state.isDecelerating = phase.phase == .decelerating
        state.userIsScrolling = phase.userIsScrolling
        return state
    }

    func layoutDidSettlePull() { settlePulls() }

    func layoutDidChangeContentHeight(_ height: CGFloat) {
        publishViewport()
        repinIfArmed()
        onContentHeightChanged?(height)
    }
}

extension TimelineCollectionController: UICollectionViewDelegate {
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        bottomAnimationWatchdog?.cancel()
        let transition = phase.apply(.willBeginDragging)
        onPhaseChanged?(transition)
        layout.noteDragWillBegin()
        armedBottom.disarm()
        beginPulls(at: viewport)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        let current = viewport
        if phase.phase == .interacting || phase.phase == .decelerating { updatePulls(current) }
        publishViewport()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        let transition = phase.apply(.didEndDragging(willDecelerate: decelerate))
        onPhaseChanged?(transition)
        layout.noteDragDidEnd(willDecelerate: decelerate)
        publishViewport()
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        let transition = phase.apply(.didEndDecelerating)
        onPhaseChanged?(transition)
        layout.noteDecelerationDidEnd()
        publishViewport()
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        bottomAnimationWatchdog?.cancel()
        let transition = phase.apply(.animationEnded)
        onPhaseChanged?(transition)
        publishViewport()
    }

    func scrollViewShouldScrollToTop(_ scrollView: UIScrollView) -> Bool {
        let transition = phase.apply(.scrollToTopBegan)
        onPhaseChanged?(transition)
        armedBottom.disarm()
        return true
    }

    func scrollViewDidScrollToTop(_ scrollView: UIScrollView) {
        let transition = phase.apply(.scrollToTopEnded)
        onPhaseChanged?(transition)
        publishViewport()
    }
}

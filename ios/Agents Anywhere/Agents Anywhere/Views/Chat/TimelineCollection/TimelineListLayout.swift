import UIKit

/// Marks the attributes of a timeline cell with the height key and the
/// controlled-exception policy that produced its frame. The cell asks for a
/// preferred height only for `.interactive`/`.tail` rows; `.measured` rows
/// always consume the layout's fixed height.
final class TimelineListLayoutAttributes: UICollectionViewLayoutAttributes {
    var item: TimelineListItem?
    var heightKey: TimelineHeightKey?
    var policy: TimelineRowHeightPolicy = .measured

    override func copy(with zone: NSZone? = nil) -> Any {
        let copy = super.copy(with: zone) as! TimelineListLayoutAttributes
        copy.item = item
        copy.heightKey = heightKey
        copy.policy = policy
        return copy
    }
}

/// The collection timeline's only layout.
///
/// It owns the height truth (via `TimelineHeightCache`), the absolute prepend
/// compensation (via `TimelineInsertionOwed`) and the two correction
/// categories of v7 §3.4.4. The controller owns measurement; this type never
/// starts one — it records what is missing and consumes heights when they
/// arrive.
@MainActor
final class TimelineListLayout: UICollectionViewLayout {
    weak var host: TimelineListLayoutHost?

    let heights = TimelineHeightCache()
    private(set) var contentHeight: CGFloat = 0
    /// Items whose current key has neither a measured nor a precalc tier.
    /// The controller measures these after the snapshot is applied and calls
    /// `applyMeasuredHeight`.
    private(set) var pendingMeasurements: Set<TimelineListItem> = []

    private var attributesByIndex: [TimelineListLayoutAttributes] = []
    private var attributesByItemID: [String: TimelineListLayoutAttributes] = [:]
    private var lastLayoutWidth: CGFloat = 0
    private var isInsideUpdate = false
    private var insertionOwed: TimelineInsertionOwed?
    private var deferral = TimelinePullDeferOrdering()
    private struct DeferredHeight {
        let key: TimelineHeightKey
        let height: CGFloat
    }
    private var deferredHeights: [String: DeferredHeight] = [:]
    private var preferredCorrections: [IndexPath: CGFloat] = [:]
    private var preferredContentSizeDeltas: [IndexPath: CGFloat] = [:]

    // Integration-gate counters. They are cheap and make the C3 assertions
    // read the real layout path instead of re-deriving it in the test.
    private(set) var targetContentOffsetCallCount = 0
    private(set) var lastProposedContentOffset: CGFloat = 0
    private(set) var lastReturnedContentOffset: CGFloat = 0
    private(set) var prepareForUpdatesCallCount = 0
    private(set) var finalizeUpdatesCallCount = 0

    /// The committed scroll target from `finalizeCollectionViewUpdates` when
    /// UIKit never asked for it (v7 §3.4.5).
    var onFinalizeFallbackApplied: ((CGFloat) -> Void)?

    // MARK: - Geometry

    override var collectionViewContentSize: CGSize {
        CGSize(width: collectionView?.bounds.width ?? 0, height: contentHeight)
    }

    override func prepare() {
        super.prepare()
        guard let collectionView, let host else {
            attributesByIndex = []
            attributesByItemID = [:]
            contentHeight = 0
            return
        }
        let width = collectionView.bounds.width
        let column = TimelineListMetrics.column(containerWidth: width)
        var cursor = TimelineListMetrics.topInset
        var next: [TimelineListLayoutAttributes] = []
        var byID: [String: TimelineListLayoutAttributes] = [:]
        var pending: Set<TimelineListItem> = []
        next.reserveCapacity(host.layoutItemCount)

        for index in 0..<host.layoutItemCount {
            let item = host.layoutItem(at: index)
            let key = host.layoutHeightKey(for: item, width: column.width)
            heights.setCurrentKey(key)
            let estimate = host.layoutEstimateKind(for: item)
            let height = heights.resolvedHeight(for: key, itemID: item.itemID, fallback: estimate)
            if heights.hasMeasuredOrPrecalcHeight(for: key) {
                heights.resolvePending(item.itemID)
            } else {
                pending.insert(item)
                heights.markPending(item.itemID)
            }
            heights.noteDisplayedHeight(height, for: item.itemID)

            let attributes = TimelineListLayoutAttributes(forCellWith: IndexPath(item: index, section: 0))
            attributes.frame = CGRect(x: column.x, y: cursor, width: column.width, height: height)
            attributes.item = item
            attributes.heightKey = key
            attributes.policy = host.layoutHeightPolicy(for: item)
            next.append(attributes)
            byID[item.itemID] = attributes
            cursor += height
            if index < host.layoutItemCount - 1 { cursor += TimelineListMetrics.itemSpacing }
        }

        let previousHeight = contentHeight
        attributesByIndex = next
        attributesByItemID = byID
        contentHeight = max(0, cursor)
        lastLayoutWidth = width
        pendingMeasurements = pending
        heights.prune(keeping: Set(byID.keys))
        deferredHeights = deferredHeights.filter { byID[$0.key] != nil }
        if abs(previousHeight - contentHeight) > 0.5 {
            host.layoutDidChangeContentHeight(contentHeight)
        }
    }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        attributesByIndex.filter { $0.frame.intersects(rect) }
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard indexPath.section == 0, attributesByIndex.indices.contains(indexPath.item) else { return nil }
        return attributesByIndex[indexPath.item]
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        newBounds.width != lastLayoutWidth
    }

    func attributes(for itemID: String) -> TimelineListLayoutAttributes? {
        attributesByItemID[itemID]
    }

    // MARK: - Insertion owed (absolute prepend target)

    func beginInsertionOwed(generation: Int, origin: TimelineHistoryLayout?,
                            offsetY: CGFloat, topInset: CGFloat) {
        insertionOwed = TimelineInsertionOwed(generation: generation, origin: origin,
            offsetY: offsetY, topInset: topInset)
    }

    @discardableResult
    func updateInsertionOwed(layout: TimelineHistoryLayout) -> CGFloat? {
        guard var owed = insertionOwed else { return nil }
        let target = owed.update(layout: layout)
        insertionOwed = owed
        return target
    }

    var insertionOwedIsSettled: Bool { insertionOwed?.isSettled ?? true }

    /// A reader gesture, the bottom pill, `loadLatest` or a navigation change
    /// takes over; a slow response must not move them.
    func cancelInsertionOwed() {
        insertionOwed?.cancel()
        insertionOwed = nil
    }

    override func targetContentOffset(forProposedContentOffset proposedContentOffset: CGPoint) -> CGPoint {
        targetContentOffsetCallCount += 1
        lastProposedContentOffset = proposedContentOffset.y
        guard var owed = insertionOwed else {
            lastReturnedContentOffset = proposedContentOffset.y
            return proposedContentOffset
        }
        let y = owed.targetOffset(proposed: proposedContentOffset.y)
        insertionOwed = owed
        lastReturnedContentOffset = y
        return CGPoint(x: proposedContentOffset.x, y: y)
    }

    override func prepare(forCollectionViewUpdates updateItems: [UICollectionViewUpdateItem]) {
        super.prepare(forCollectionViewUpdates: updateItems)
        prepareForUpdatesCallCount += 1
        isInsideUpdate = true
    }

    override func finalizeCollectionViewUpdates() {
        super.finalizeCollectionViewUpdates()
        finalizeUpdatesCallCount += 1
        isInsideUpdate = false
        if var owed = insertionOwed, let fallback = owed.finalizeFallback() {
            insertionOwed = owed
            applyOffsetFallback(fallback)
        }
        insertionOwed = nil
#if DEBUG
        var expected: [String: TimelineHeightKey] = [:]
        for attributes in attributesByIndex {
            guard let item = attributes.item, let key = attributes.heightKey else { continue }
            expected[item.itemID] = key
        }
        // Owed is cleared by `finalizeFallback` above; this check covers the
        // other half — a reconfigure that forgot to install the new height key
        // would silently reuse another revision's height.
        let violations = TimelineLayoutInvariants.heightKeyViolations(cache: heights, expectedKeys: expected)
        if !violations.isEmpty {
            assertionFailure("timeline layout invariants: \(violations)")
        }
#endif
    }

    /// Applies the fallback with animations disabled. The first attempt can
    /// still be clamped by the pre-update content size; one next-runloop retry
    /// distinguishes "content is genuinely shorter" from "the old size won".
    private func applyOffsetFallback(_ y: CGFloat) {
        guard let collectionView else { return }
        collectionView.layoutIfNeeded()
        let first = clampedContentOffset(y, in: collectionView)
        collectionView.setContentOffset(CGPoint(x: collectionView.contentOffset.x, y: first), animated: false)
        guard abs(first - y) > 0.5 else {
            onFinalizeFallbackApplied?(first)
            return
        }
        DispatchQueue.main.async { [weak self, weak collectionView] in
            guard let self, let collectionView else { return }
            collectionView.layoutIfNeeded()
            let retry = self.clampedContentOffset(y, in: collectionView)
            collectionView.setContentOffset(CGPoint(x: collectionView.contentOffset.x, y: retry), animated: false)
            self.onFinalizeFallbackApplied?(retry)
        }
    }

    private func clampedContentOffset(_ y: CGFloat, in collectionView: UICollectionView) -> CGFloat {
        let top = -collectionView.adjustedContentInset.top
        let bottom = max(top, collectionView.contentSize.height - collectionView.bounds.height
            + collectionView.adjustedContentInset.bottom)
        return min(max(y, top), bottom)
    }

    // MARK: - Pending measurement corrections (category A)

    /// A controller-driven measurement completed. The fixed height is the
    /// truth; the decision only says whether the reader's content must move.
    func applyMeasuredHeight(_ height: CGFloat, for itemID: String, key: TimelineHeightKey) {
        guard heights.currentKey(for: itemID) == key else { return }
        let hadCommittedHeight = heights.hasMeasuredOrPrecalcHeight(for: key)
        heights.set(height, for: key, tier: .measured)
        heights.resolvePending(itemID)
        guard let attributes = attributesByItemID[itemID], attributes.heightKey == key else { return }
        let delta = height - attributes.frame.height
        guard abs(delta) > 0.5 else { return }
        let state = host?.layoutInteractionState() ?? TimelineLayoutInteractionState()
        let decision = TimelinePreferredAttributesDecision.pendingMeasurement(
            delta: delta,
            cellMinY: attributes.frame.minY,
            viewportTop: viewportTop,
            isStreaming: state.streamingItemIDs.contains(itemID),
            isAutoScrollPinning: state.isAutoScrollPinning,
            isTracking: state.isTracking,
            isDecelerating: state.isDecelerating,
            keyboardTransition: state.keyboardTransition,
            suppressContentOffsetAdjustment: state.suppressContentOffsetAdjustment,
            hasCachedHeight: hadCommittedHeight)
        if decision.height == .deferUntilSettled {
            deferredHeights[itemID] = DeferredHeight(key: key, height: height)
            return
        }
        heights.noteDisplayedHeight(height, for: itemID)
        invalidateHeight(itemID: itemID, attributes: attributes,
                         correction: decision.correction, contentSizeDelta: delta, state: state)
    }

    /// The official layout ships offset and size adjustments together
    /// (`setContentOffsetAdjustment:` + `setContentSizeAdjustment:`), so the
    /// offset is interpreted against the corrected content size instead of
    /// the old one. Without the size half, a correction near the bottom can
    /// be clamped by the stale maximum offset.
    private func invalidateHeight(itemID: String, attributes: TimelineListLayoutAttributes,
                                  correction: CGFloat?, contentSizeDelta: CGFloat,
                                  state: TimelineLayoutInteractionState) {
        guard let collectionView else { return }
        let context = UICollectionViewLayoutInvalidationContext()
        context.invalidateItems(at: [attributes.indexPath])
        if contentSizeDelta != 0 {
            context.contentSizeAdjustment = CGSize(width: 0, height: contentSizeDelta)
        }
        if let correction, correction != 0 {
            if isInsideUpdate, insertionOwed != nil {
                insertionOwed?.adjustTarget(by: correction)
            } else if !state.suppressContentOffsetAdjustment {
                context.contentOffsetAdjustment = CGPoint(x: 0, y: correction)
            }
        }
        collectionView.collectionViewLayout.invalidateLayout(with: context)
    }

    // MARK: - Cell self-sizing exceptions (category B)

    /// Controller-driven preferred-height application for controlled
    /// exceptions. AA's hosting cells have no `heightDidChange` callback, so
    /// the controller asks the visible cell for its fitting height after a
    /// fold/notice/tail reconfiguration and feeds it here. The decision and
    /// invalidation are the same ones the UIKit preferred-attributes path
    /// uses.
    func applyPreferredHeight(_ height: CGFloat, for itemID: String) {
        guard let attributes = attributesByItemID[itemID],
              attributes.policy.acceptsPreferredHeight,
              let key = attributes.heightKey,
              heights.currentKey(for: itemID) == key else { return }
        let delta = height - attributes.frame.height
        guard abs(delta) > 0.5 else { return }
        let state = host?.layoutInteractionState() ?? TimelineLayoutInteractionState()
        let decision = TimelinePreferredAttributesDecision.selfSizing(
            delta: delta,
            cellMinY: attributes.frame.minY,
            cellMaxY: attributes.frame.maxY,
            viewportTop: viewportTop,
            viewportBottom: viewportBottom,
            isStreaming: state.streamingItemIDs.contains(itemID),
            isAutoScrollPinning: state.isAutoScrollPinning,
            isTracking: state.isTracking,
            isDecelerating: state.isDecelerating,
            keyboardTransition: state.keyboardTransition,
            hasCachedHeight: heights.hasMeasuredOrPrecalcHeight(for: key))
        if decision.height == .deferUntilSettled {
            deferredHeights[itemID] = DeferredHeight(key: key, height: height)
            return
        }
        heights.set(height, for: key, tier: .measured)
        heights.noteDisplayedHeight(height, for: itemID)
        invalidateHeight(itemID: itemID, attributes: attributes,
                         correction: decision.correction, contentSizeDelta: delta, state: state)
    }

    override func shouldInvalidateLayout(forPreferredLayoutAttributes preferredAttributes: UICollectionViewLayoutAttributes,
                                         withOriginalAttributes originalAttributes: UICollectionViewLayoutAttributes) -> Bool {
        guard let original = originalAttributes as? TimelineListLayoutAttributes,
              original.policy.acceptsPreferredHeight,
              let item = original.item,
              let key = original.heightKey,
              heights.currentKey(for: item.itemID) == key else { return false }
        let delta = preferredAttributes.frame.height - original.frame.height
        guard abs(delta) > 0.5 else { return false }
        let state = host?.layoutInteractionState() ?? TimelineLayoutInteractionState()
        let decision = TimelinePreferredAttributesDecision.selfSizing(
            delta: delta,
            cellMinY: original.frame.minY,
            cellMaxY: original.frame.maxY,
            viewportTop: viewportTop,
            viewportBottom: viewportBottom,
            isStreaming: state.streamingItemIDs.contains(item.itemID),
            isAutoScrollPinning: state.isAutoScrollPinning,
            isTracking: state.isTracking,
            isDecelerating: state.isDecelerating,
            keyboardTransition: state.keyboardTransition,
            hasCachedHeight: heights.hasMeasuredOrPrecalcHeight(for: key))
        if decision.height == .deferUntilSettled {
            deferredHeights[item.itemID] = DeferredHeight(key: key, height: preferredAttributes.frame.height)
            return false
        }
        heights.set(preferredAttributes.frame.height, for: key, tier: .measured)
        heights.noteDisplayedHeight(preferredAttributes.frame.height, for: item.itemID)
        preferredCorrections[original.indexPath] = decision.correction ?? 0
        preferredContentSizeDeltas[original.indexPath] = delta
        return true
    }

    override func invalidationContext(forPreferredLayoutAttributes preferredAttributes: UICollectionViewLayoutAttributes,
                                      withOriginalAttributes originalAttributes: UICollectionViewLayoutAttributes) -> UICollectionViewLayoutInvalidationContext {
        let context = UICollectionViewLayoutInvalidationContext()
        context.invalidateItems(at: [originalAttributes.indexPath])
        let correction = preferredCorrections.removeValue(forKey: originalAttributes.indexPath) ?? 0
        let sizeDelta = preferredContentSizeDeltas.removeValue(forKey: originalAttributes.indexPath) ?? 0
        if sizeDelta != 0 {
            context.contentSizeAdjustment = CGSize(width: 0, height: sizeDelta)
        }
        if correction != 0 {
            let state = host?.layoutInteractionState() ?? TimelineLayoutInteractionState()
            if isInsideUpdate, insertionOwed != nil {
                insertionOwed?.adjustTarget(by: correction)
            } else if !state.suppressContentOffsetAdjustment {
                context.contentOffsetAdjustment = CGPoint(x: 0, y: correction)
            }
        }
        return context
    }

    // MARK: - Browsing defer

    func noteDragWillBegin() {
        insertionOwed?.cancel()
        insertionOwed = nil
        deferral.beginDrag()
    }

    func noteDragDidEnd(willDecelerate: Bool) {
        if let application = deferral.endDrag(willDecelerate: willDecelerate) {
            apply(application)
        }
    }

    func noteDecelerationDidEnd() {
        if let application = deferral.endDeceleration() {
            apply(application)
        }
    }

    /// Navigation suspension: parked corrections belong to the old viewport.
    func cancelBrowsingCorrections() {
        deferral.cancel()
        deferredHeights.removeAll()
        preferredCorrections.removeAll()
        preferredContentSizeDeltas.removeAll()
        insertionOwed?.cancel()
        insertionOwed = nil
    }

    private func apply(_ application: TimelinePullDeferOrdering.Application) {
        guard let collectionView else { return }
        let context = UICollectionViewLayoutInvalidationContext()
        var total: CGFloat = 0
        var contentSizeTotal: CGFloat = 0
        var invalidated: [IndexPath] = []
        for effect in application.effects {
            switch effect {
            case .settlePull:
                host?.layoutDidSettlePull()
            case .apply(let correction):
                guard let deferred = deferredHeights.removeValue(forKey: correction.itemID),
                      heights.currentKey(for: correction.itemID) == deferred.key,
                      let attributes = attributesByItemID[correction.itemID] else { continue }
                heights.set(deferred.height, for: deferred.key, tier: .measured)
                heights.noteDisplayedHeight(deferred.height, for: correction.itemID)
                total += correction.delta
                contentSizeTotal += deferred.height - attributes.frame.height
                invalidated.append(attributes.indexPath)
            }
        }
        guard !invalidated.isEmpty || total != 0 else { return }
        context.invalidateItems(at: invalidated)
        if total != 0 { context.contentOffsetAdjustment = CGPoint(x: 0, y: total) }
        if contentSizeTotal != 0 {
            context.contentSizeAdjustment = CGSize(width: 0, height: contentSizeTotal)
        }
        collectionView.collectionViewLayout.invalidateLayout(with: context)
    }

    // MARK: - Viewport helpers

    private var viewportTop: CGFloat {
        guard let collectionView else { return 0 }
        return collectionView.contentOffset.y + collectionView.adjustedContentInset.top
    }

    private var viewportBottom: CGFloat {
        guard let collectionView else { return 0 }
        return collectionView.contentOffset.y + collectionView.bounds.height
            - collectionView.adjustedContentInset.bottom
    }
}

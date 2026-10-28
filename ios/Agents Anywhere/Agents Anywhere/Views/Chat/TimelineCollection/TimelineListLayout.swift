import UIKit

/// Marks the attributes of a timeline cell with the height key, the
/// controlled-exception policy, and the official `isMeasured` /
/// `usesCellReportedHeight` flags. The cell self-sizes only while the row is
/// unmeasured; measured rows consume the layout's fixed height.
final class TimelineListLayoutAttributes: UICollectionViewLayoutAttributes {
    var item: TimelineListItem?
    var heightKey: TimelineHeightKey?
    var policy: TimelineRowHeightPolicy = .measured
    /// Whether the row's current key already carries a measured/precalc
    /// height. Mirrors the official row's `isMeasured`: only an unmeasured
    /// cell may self-size, and a measured row rejects its preferred height.
    var isMeasured = false
    /// This row follows the official hosted-cell contract (Code message
    /// groups): the controller stops pre-measuring/polling it and the cell
    /// reports content height through `heightDidChange`.
    var usesCellReportedHeight = false

    override func copy(with zone: NSZone? = nil) -> Any {
        let copy = super.copy(with: zone) as! TimelineListLayoutAttributes
        copy.item = item
        copy.heightKey = heightKey
        copy.policy = policy
        copy.isMeasured = isMeasured
        copy.usesCellReportedHeight = usesCellReportedHeight
        return copy
    }
}

/// Invalidation context for an accepted cell self-measure. UIKit's default
/// context carries neither the row nor the height the cell fitted, and the
/// layout needs both to write the measurement and compute the correction.
final class TimelinePreferredHeightInvalidationContext: UICollectionViewLayoutInvalidationContext {
    var itemID: String?
    var heightKey: TimelineHeightKey?
    var preferredHeight: CGFloat?
}

/// Optional host capability: rows that follow the official hosted-cell
/// contract. Kept out of `TimelineListLayoutHost` so a host without Code rows
/// does not need a new method.
@MainActor
protocol TimelineListLayoutCellReportedHeightHost: AnyObject {
    func layoutUsesCellReportedHeight(for item: TimelineListItem) -> Bool
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
    /// Previous snapshot's identity and keys, for longest-common-prefix reuse.
    private var isInsideUpdate = false
    private var insertionOwed: TimelineInsertionOwed?
    private var deferral = TimelinePullDeferOrdering()
    private struct DeferredHeight {
        let key: TimelineHeightKey
        let height: CGFloat
    }
    private var deferredHeights: [String: DeferredHeight] = [:]
    /// Per-frame reveal heights for streaming rows. Display-only: never
    /// written to `heights`, so the row returns to its measured height when
    /// the reveal finishes.
    private var streamingHeights: [String: CGFloat] = [:]
    /// Last value this layout applied for a row (self-measure or hosting
    /// report), scoped to the height key that produced it. A geometry action
    /// can fire repeatedly with the same height; ±0.5 is the same pixel and
    /// must not re-enter the application. A new key must still be written even
    /// when its content happens to match the previous revision's height.
    private struct AppliedHeight {
        let key: TimelineHeightKey
        let height: CGFloat
    }
    private var lastAppliedHeight: [String: AppliedHeight] = [:]
    /// One-shot absolute offset owed to an update transaction when a height
    /// change lands inside it. Official `offsetOwedToUpdate`: the update's
    /// `targetContentOffset` answers with this value, and no offset/size
    /// adjustment is posted in the same transaction.
    private var heightOwedToUpdate: TimelineOneShotOwed?
    /// The page was settled at the bottom when this update started. Recorded
    /// before `prepare` can start a follow motion, so the update itself can
    /// land on the new end even when UIKit never asks for the target.
    private var followBottomDuringUpdate = false

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
        prepareCount += 1
        let width = collectionView.bounds.width
        // Ignore the first layout (0 → screen width): the controller already
        // measured every new key before the apply. Only a later resize is a
        // pure bounds change with no apply to schedule the new keys.
        let widthChanged = lastLayoutWidth > 0 && width != lastLayoutWidth
        // Official 0x101a3ff20: a width change re-measures every row, even
        // when the view returns to a width used earlier. The height tiers stay
        // as estimates; only the measured state is cleared.
        if widthChanged { heights.forgetMeasuredWidths() }
        let column = TimelineListMetrics.column(containerWidth: width)
        let count = host.layoutItemCount
        var items: [TimelineListItem] = []
        var keys: [TimelineHeightKey] = []
        var resolved: [CGFloat] = []
        var measuredFlags: [Bool] = []
        var cellReportedFlags: [Bool] = []
        items.reserveCapacity(count)
        keys.reserveCapacity(count)
        resolved.reserveCapacity(count)
        measuredFlags.reserveCapacity(count)
        cellReportedFlags.reserveCapacity(count)
        var pending: Set<TimelineListItem> = []
        let cellReportedHost = host as? TimelineListLayoutCellReportedHeightHost

        for index in 0..<count {
            let item = host.layoutItem(at: index)
            let key = host.layoutHeightKey(for: item, width: column.width)
            heights.setCurrentKey(key)
            // The provider's estimate walks the row's text and rebuilds the
            // structural plan. A measured tier or a displayed height answers
            // first, so the estimate is only needed for a key neither can
            // serve. Asking for it unconditionally made every streaming apply
            // re-walk the whole window's text on the main thread — the
            // scroll jitter reported on 2026-10-23.
            let hasResolved = heights.tieredHeight(for: key) != nil
                || heights.displayedHeight(for: item.itemID) != nil
            let estimate: TimelineHeightEstimateKind = hasResolved
                ? .row : host.layoutEstimateKind(for: item)
            // A streaming row's per-frame clamped height is a display override:
            // it is used for this prepare but never written to the height
            // cache, so clearing it restores the measured height.
            let streamingHeight = streamingHeights[item.itemID]
            let height = streamingHeight
                ?? heights.resolvedHeight(for: key, itemID: item.itemID, fallback: estimate)
            // Official 0x101a3ff20: the row's `isMeasured` is item-level and
            // a width change is the only thing that clears it. A same-width
            // content revision keeps the row measured; its new height arrives
            // from the hosting geometry report (`rowMeasured`), not a second
            // self-measure.
            let hasMeasuredHeight = heights.isMeasured(itemID: item.itemID, width: key.width)
            // Pending stays key-level: the controller still owes this key a
            // real measurement even when the row was measured under an
            // earlier revision.
            if heights.hasMeasuredOrPrecalcHeight(for: key) {
                heights.resolvePending(item.itemID)
            } else {
                pending.insert(item)
                heights.markPending(item.itemID)
            }
            if streamingHeight == nil {
                heights.noteDisplayedHeight(height, for: item.itemID)
            }
            lastPreparedHeight[item.itemID] = height
            lastPreparedKeyRevision[item.itemID] = key.contentRevision
            items.append(item)
            keys.append(key)
            resolved.append(height)
            measuredFlags.append(hasMeasuredHeight)
            cellReportedFlags.append(
                cellReportedHost?.layoutUsesCellReportedHeight(for: item) ?? false)
        }

        // One entry per item (the last one's gap is unused, but keeping the
        // array aligned with `items` makes the prefix cursor safe when every
        // item is reused: `spacings[prefix - 1]` must exist for prefix == count).
        var spacings: [CGFloat] = []
        spacings.reserveCapacity(count)
        for index in 0..<count {
            spacings.append(host.layoutItemSpacing(after: items[index]))
        }

        // Official (0x101a3ff40 / 0x1019e1468): prepare rebuilds the full
        // `starts` prefix sum every time; there is no "reuse the common
        // prefix" optimization. AA's LCP kept old attribute objects but their
        // frame.minY could already be stale after a row above changed height,
        // which the probe recorded as staleCell and cellOverlap. Rebuild
        // every attribute from the resolved heights, exactly like the
        // official runner.
        var next: [TimelineListLayoutAttributes] = []
        next.reserveCapacity(count)
        var cursor = TimelineListMetrics.topInset
        for index in 0..<count {
            let attributes = TimelineListLayoutAttributes(forCellWith: IndexPath(item: index, section: 0))
            attributes.frame = CGRect(x: column.x, y: cursor, width: column.width,
                                      height: resolved[index])
            attributes.item = items[index]
            attributes.heightKey = keys[index]
            attributes.policy = host.layoutHeightPolicy(for: items[index])
            attributes.isMeasured = measuredFlags[index]
            attributes.usesCellReportedHeight = cellReportedFlags[index]
            next.append(attributes)
            cursor += resolved[index]
            if index < count - 1 { cursor += spacings[index] }
        }

        var byID: [String: TimelineListLayoutAttributes] = [:]
        byID.reserveCapacity(count)
        for attributes in next {
            if let item = attributes.item { byID[item.itemID] = attributes }
        }

        let previousHeight = contentHeight
        attributesByIndex = next
        attributesByItemID = byID
        contentHeight = next.last?.frame.maxY ?? 0
        lastLayoutWidth = width
        pendingMeasurements = pending
        heights.prune(keeping: Set(byID.keys))
        deferredHeights = deferredHeights.filter { byID[$0.key] != nil }
        streamingHeights = streamingHeights.filter { byID[$0.key] != nil }
        lastAppliedHeight = lastAppliedHeight.filter { byID[$0.key] != nil }
        if abs(previousHeight - contentHeight) > 0.5 {
            host.layoutDidChangeContentHeight(contentHeight)
        }
        // A pure rotation/split-view resize never runs a snapshot apply, so
        // the controller's apply-time measurement cannot see these new keys.
        if widthChanged, !pending.isEmpty {
            host.layoutNeedsMeasurement(width: column.width)
        }
    }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        guard !attributesByIndex.isEmpty else { return [] }
        // Attributes are sorted by y. Find the first whose bottom reaches the
        // rect, then walk until the top passes the rect's bottom.
        var low = 0
        var high = attributesByIndex.count
        while low < high {
            let mid = (low + high) / 2
            if attributesByIndex[mid].frame.maxY < rect.minY { low = mid + 1 } else { high = mid }
        }
        var result: [UICollectionViewLayoutAttributes] = []
        var index = low
        while index < attributesByIndex.count, attributesByIndex[index].frame.minY <= rect.maxY {
            let attributes = attributesByIndex[index]
            if attributes.frame.intersects(rect) { result.append(attributes) }
            index += 1
        }
        return result
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

    /// Ordered frames for the integration gate's overlap check. Debug-only
    /// callers; the layout itself never reads this.
    var orderedAttributes: [TimelineListLayoutAttributes] { attributesByIndex }

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

#if DEBUG
    /// Gate probe: whether the prepend target is still armed, which page row
    /// it belongs to and what absolute offset it wants.
    var debugInsertionOwed: String {
        guard let owed = insertionOwed else { return "nil" }
        let target = owed.target.map { String(describing: $0) } ?? "nil"
        return "gen=\(owed.generation) expected=\(owed.expectedFirstRowID ?? "nil")"
            + " target=\(target) settled=\(owed.isSettled)"
    }
#endif

    /// A reader gesture, the bottom pill, `loadLatest` or a navigation change
    /// takes over; a slow response must not move them.
    func cancelInsertionOwed() {
        insertionOwed?.cancel()
        insertionOwed = nil
    }

    override func targetContentOffset(forProposedContentOffset proposedContentOffset: CGPoint) -> CGPoint {
        targetContentOffsetCallCount += 1
        lastProposedContentOffset = proposedContentOffset.y
#if AA_TIMELINE_PROBE
        AnchorDeviceProbe.shared.recordLayout(
            "target inside=\(isInsideUpdate ? 1 : 0) follow=\(followBottomDuringUpdate ? 1 : 0) proposed=\(Int(proposedContentOffset.y))")
#endif
        // The target belongs to the update that carries the prepended page.
        // An unrelated update (a streaming batch landing first) must not
        // consume it or the history request loses its compensation.
        if var owed = insertionOwed,
           owed.expectedFirstRowID == host?.layoutFirstRowID {
            // A height correction inside this update folded into the same
            // absolute target (`applyHeightUpdates`); never add a second
            // height owed on top of it.
            heightOwedToUpdate = nil
            let y = owed.targetOffset(proposed: proposedContentOffset.y)
            insertionOwed = owed
            lastReturnedContentOffset = y
#if DEBUG
            if abs(y - proposedContentOffset.y) > 0.5 {
                traceOffset("targetInsertion", before: proposedContentOffset.y,
                            after: y, note: "owed insertion")
            }
#endif
            return CGPoint(x: proposedContentOffset.x, y: y)
        }
        // A page waiting at the bottom lands on the new end inside the update
        // that carries the inserted/deleted rows (official
        // `rowsOwedToNextUpdate` → `offsetOwedToUpdate`). Without this answer
        // the anchor Mover only sees the new height after the update and
        // springs there, so a new tool row read as a slow drift instead of the
        // content pushing the page up. This outranks a height owed: the new
        // bottom is already the final position for every change in the update.
        //
        // The gate is the flag captured in `prepare(forCollectionViewUpdates:)`,
        // not the live driver state: UIKit calls `prepare()` before asking for
        // the target, and absorbing the rows there already starts the follow
        // motion (`.easing`), which would make a live check skip this answer.
        if isInsideUpdate, followBottomDuringUpdate, let view = collectionView {
            let bottom = TimelineOffsetTarget.bottomOffset(
                contentHeight: contentHeight,
                containerHeight: view.bounds.height,
                topInset: view.adjustedContentInset.top,
                bottomInset: view.adjustedContentInset.bottom)
            if abs(bottom - proposedContentOffset.y) > 0.5 {
                heightOwedToUpdate = nil
                lastReturnedContentOffset = bottom
#if AA_TIMELINE_PROBE
                AnchorDeviceProbe.shared.recordLayout("targetFollow bottom=\(Int(bottom))")
#endif
#if DEBUG
                traceOffset("targetFollowBottom", before: proposedContentOffset.y,
                            after: bottom, note: "follow new end")
#endif
                return CGPoint(x: proposedContentOffset.x, y: bottom)
            }
        }
        // A height change applied inside the update without a prepend target:
        // answer with its absolute offset. The value is idempotent for the
        // repeated queries UIKit makes in one transaction.
        if var owed = heightOwedToUpdate {
            let y = owed.offer(proposed: proposedContentOffset.y)
            heightOwedToUpdate = owed
            lastReturnedContentOffset = y
#if DEBUG
            if abs(y - proposedContentOffset.y) > 0.5 {
                traceOffset("targetHeightOwed", before: proposedContentOffset.y,
                            after: y, note: "owed height")
            }
#endif
            return CGPoint(x: proposedContentOffset.x, y: y)
        }
        lastReturnedContentOffset = proposedContentOffset.y
        return proposedContentOffset
    }

    override func prepare(forCollectionViewUpdates updateItems: [UICollectionViewUpdateItem]) {
        super.prepare(forCollectionViewUpdates: updateItems)
        prepareForUpdatesCallCount += 1
        // A new transaction starts with no owed offset. A target left from an
        // update UIKit never finalized (navigation interruption) must not
        // answer this update's queries.
        heightOwedToUpdate = nil
        if let state = host?.layoutInteractionState() {
            followBottomDuringUpdate = state.bottomFollowTracksInPlace
                && !state.suppressContentOffsetAdjustment
        } else {
            followBottomDuringUpdate = false
        }
#if AA_TIMELINE_PROBE
        AnchorDeviceProbe.shared.recordLayout(
            "prepareForUpdates follow=\(followBottomDuringUpdate ? 1 : 0) content=\(Int(contentHeight))")
#endif
        isInsideUpdate = true
    }

    override func finalizeCollectionViewUpdates() {
        super.finalizeCollectionViewUpdates()
        finalizeUpdatesCallCount += 1
        isInsideUpdate = false
#if AA_TIMELINE_PROBE
        AnchorDeviceProbe.shared.recordLayout(
            "finalize follow=\(followBottomDuringUpdate ? 1 : 0) off=\(Int(collectionView?.contentOffset.y ?? -1)) content=\(Int(contentHeight))")
#endif
        if var owed = insertionOwed {
            if owed.expectedFirstRowID == host?.layoutFirstRowID {
                if let fallback = owed.finalizeFallback() {
                    insertionOwed = owed
                    applyOffsetFallback(fallback)
                }
                insertionOwed = nil
            }
            // Otherwise this update belongs to an earlier page; keep the
            // target for the update that actually carries the prepend.
        }
        // Official `offsetOwedToUpdate` exit for the follow answer: when UIKit
        // never asked for the target, land the new end here. If the offered
        // target was used the offset already matches and this is a no-op.
        // The new bottom subsumes any height owed for this update.
        if followBottomDuringUpdate {
            followBottomDuringUpdate = false
            heightOwedToUpdate = nil
            if let view = collectionView {
                let bottom = TimelineOffsetTarget.bottomOffset(
                    contentHeight: contentHeight,
                    containerHeight: view.bounds.height,
                    topInset: view.adjustedContentInset.top,
                    bottomInset: view.adjustedContentInset.bottom)
                if abs(view.contentOffset.y - bottom) > 0.5 {
#if AA_TIMELINE_PROBE
                    AnchorDeviceProbe.shared.recordLayout("finalizeFollow bottom=\(Int(bottom))")
#endif
                    applyOffsetFallback(bottom)
                }
            }
        }
        // Official `offsetOwedToUpdate` exit: when UIKit never asked for the
        // target, the layout applies the absolute offset itself. An offered
        // value was already used for the update's target.
        if var owed = heightOwedToUpdate {
            heightOwedToUpdate = nil
            if let fallback = owed.takeAfterFinalize() {
                applyOffsetFallback(fallback)
            }
        }
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
#if DEBUG
        traceOffset("offsetFallback", before: collectionView.contentOffset.y,
                    after: y)
#endif
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

    /// A measurement completed — a controller read, or the hosting geometry
    /// report (official `rowMeasured`, `CANONICAL/05-layout-scroll.md` §2.2).
    /// The fixed height is the truth; the decision says whether the reader's
    /// content must move, and a deferred change parks the value itself until
    /// the gesture settles. `commit` bypasses that park for a height the
    /// reader already sees (a row-height animation's final frame): its caller
    /// removes the display override right after, and a parked value would
    /// make that removal fall back to the pre-animation height.
    /// `suppressOffsetAdjustment` is for a height that lands while another
    /// owner drives the offset (the programmatic-return spring re-reads the
    /// live bottom every frame): the size change lands, the offset does not
    /// move. Official `rowMeasured` writes the height regardless of the
    /// scroll motion and lets the Mover answer the placement.
    /// `probeSource` names the writer in the timeline probe. The hosting
    /// geometry report uses `rowMeasured` so a device acceptance run can tell
    /// it apart from the controller's own measurements (the probe coalesces
    /// records with the same source).
    func applyMeasuredHeight(_ height: CGFloat, for itemID: String, key: TimelineHeightKey,
                             commit: Bool = false,
                             suppressOffsetAdjustment: Bool = false,
                             probeSource: String = "measured") {
        guard heights.currentKey(for: itemID) == key else { return }
        // Item-level, like the cell's `isMeasured`: a same-width re-key must
        // keep treating this as an already-displayed row (official
        // 0x101a3ff20).
        let hadCommittedHeight = heights.isMeasured(itemID: itemID, width: key.width)
        guard let attributes = attributesByItemID[itemID] else {
            heights.set(height, for: key, tier: .measured)
            heights.resolvePending(itemID)
            heights.noteDisplayedHeight(height, for: itemID)
            return
        }
        guard attributes.heightKey == key else {
            // The layout can still carry an older key when a width/typography
            // change has not reached a prepare yet. The measured height is the
            // newest truth; keep it as the item's displayed fallback so the
            // next prepare uses it even under the new key. Rebuild so the row
            // takes the measured height instead of the stale estimate.
            heights.set(height, for: key, tier: .measured)
            heights.resolvePending(itemID)
            heights.noteDisplayedHeight(height, for: itemID)
            collectionView?.collectionViewLayout.invalidateLayout()
            return
        }
        // Compare with the height the layout currently displays through the
        // same resolver `prepare` used, not the raw attribute frame. A
        // previous application can write the cache before the next `prepare`
        // rebuilds the frame (two geometry reports in one runloop, a report
        // during an update transaction); using the stale frame would count
        // the same delta twice and post a doubled size/offset adjustment.
        // Official 0x101a4081c also accepts only a *changed* height
        // (`fcmp; cset ne`).
        //
        // `commit` is the exception: its caller (a row-height animation's
        // final frame) has already grown the content size frame by frame, so
        // the frame is the displayed height and the cache is still the
        // pre-animation value. Comparing against the cache there would post
        // the whole change a second time.
        let baseline = commit
            ? attributes.frame.height
            : displayedHeight(for: itemID, key: key, attributes: attributes)
        let delta = height - baseline
        if abs(delta) <= 0.5 {
            // Same value: not a new measurement event for the offset, but it
            // still latches `isMeasured` (official 0x1019e0b10 sets it
            // unconditionally; only the `starts` prefix sum is conditional).
            heights.set(height, for: key, tier: .measured)
            heights.resolvePending(itemID)
            heights.noteDisplayedHeight(height, for: itemID)
            attributes.isMeasured = true
            return
        }
        let state = host?.layoutInteractionState() ?? TimelineLayoutInteractionState()
        let decision = TimelinePreferredAttributesDecision.pendingMeasurement(
            delta: delta,
            cellMaxY: attributes.frame.maxY,
            viewportTop: viewportTop,
            isStreaming: state.streamingItemIDs.contains(itemID),
            isAutoScrollPinning: state.isAutoScrollPinning,
            isTracking: state.isTracking,
            isDecelerating: state.isDecelerating,
            keyboardTransition: state.keyboardTransition,
            suppressContentOffsetAdjustment: state.suppressContentOffsetAdjustment,
            hasCachedHeight: hadCommittedHeight)
        if decision.height == .deferUntilSettled {
            guard commit else {
                // Park the value itself, not just the correction: writing the
                // measurement now would let the next `prepare` display the new
                // height while its offset compensation is still parked.
                deferredHeights[itemID] = DeferredHeight(key: key, height: height)
                return
            }
            // The caller already shows this height (a row-height animation's
            // final frame). Parking it would let the following
            // `clearStreamingHeight` fall back to the pre-animation displayed
            // height and collapse the row under the finger; this is not an
            // unseen correction, so it lands now.
        }
        heights.set(height, for: key, tier: .measured)
        heights.resolvePending(itemID)
        heights.noteDisplayedHeight(height, for: itemID)
        attributes.isMeasured = true
        invalidateHeight(itemID: itemID, attributes: attributes,
                         correction: suppressOffsetAdjustment ? nil : decision.correction,
                         contentSizeDelta: delta,
                         state: state, probeSource: probeSource)
    }

    /// The changed item plus the visible rows below it. A height change moves
    /// every following row, and UIKit only re-queries the items named in an
    /// invalidation context; naming just the changed item leaves the rows
    /// below their cells at the previous frames, so their content draws over
    /// the next row (device report: overlapping tool rows and messages).
    private func cellUpdatesAffected(
        by attributes: TimelineListLayoutAttributes
    ) -> [IndexPath] {
        var affected: [IndexPath] = [attributes.indexPath]
        let top = viewportTop - 400
        let bottom = viewportBottom + 400
        let start = attributes.indexPath.item + 1
        guard start < attributesByIndex.count else { return affected }
        for candidate in attributesByIndex[start...] {
            if candidate.frame.minY > bottom { break }
            // Rows between a far-above change and the viewport do not need a
            // cell update; only what can be on screen (plus a margin).
            if candidate.frame.maxY < top { continue }
            affected.append(candidate.indexPath)
        }
        return affected
    }

    /// The rows to invalidate for a height change, bounded by the item count
    /// the current snapshot can serve. A commit can run while a diffable
    /// update has already changed that count; invalidating an index path that
    /// no longer exists traps inside UIKit (`_setNeedsVisibleCellsUpdate`).
    private func invalidatablePaths(by attributes: TimelineListLayoutAttributes) -> [IndexPath] {
        let liveCount = host?.layoutItemCount ?? attributesByIndex.count
        return cellUpdatesAffected(by: attributes).filter { $0.item < liveCount }
    }

    /// Folds one height correction into the update's single absolute offset.
    /// Official `offsetOwedToUpdate`: repeated changes in the same transaction
    /// accumulate on the target instead of posting adjustments.
    private func addHeightOwed(_ delta: CGFloat) {
        guard delta != 0, let collectionView else { return }
        let base = heightOwedToUpdate?.target ?? collectionView.contentOffset.y
        heightOwedToUpdate = TimelineOneShotOwed(target: base + delta)
    }

    /// The official layout ships offset and size adjustments together
    /// (`setContentOffsetAdjustment:` + `setContentSizeAdjustment:`), so the
    /// offset is interpreted against the corrected content size instead of
    /// the old one. Without the size half, a correction near the bottom can
    /// be clamped by the stale maximum offset. Inside an update transaction
    /// only the absolute owed offset is written; UIKit already knows the new
    /// content size from the update.
    private func invalidateHeight(itemID: String, attributes: TimelineListLayoutAttributes,
                                  correction: CGFloat?, contentSizeDelta: CGFloat,
                                  state: TimelineLayoutInteractionState,
                                  probeSource: String) {
        guard let collectionView else { return }
#if DEBUG
        if let state = host?.layoutInteractionState(),
           state.isTracking || state.isDecelerating {
            debugHeightApplicationsDuringGesture += 1
        }
#endif
#if AA_TIMELINE_PROBE
        if !probeSource.isEmpty {
            TimelineProbeStore.shared.noteHeightChange(
                itemID: itemID, item: attributes.item,
                old: attributes.frame.height,
                new: attributes.frame.height + contentSizeDelta,
                source: probeSource)
        }
#endif
        let context = UICollectionViewLayoutInvalidationContext()
        context.invalidateItems(at: invalidatablePaths(by: attributes))
#if DEBUG
        let traceBefore = collectionView.contentOffset.y
        traceOffset("invalidate", itemID: itemID, delta: contentSizeDelta,
                    correction: correction, before: traceBefore,
                    note: isInsideUpdate ? "inside" : "outside")
#endif
        if isInsideUpdate {
            if let correction, correction != 0 {
                if insertionOwed != nil,
                   insertionOwed?.expectedFirstRowID == host?.layoutFirstRowID {
                    insertionOwed?.adjustTarget(by: correction)
                } else {
                    addHeightOwed(correction)
                }
            }
        } else {
            if contentSizeDelta != 0 {
                context.contentSizeAdjustment = CGSize(width: 0, height: contentSizeDelta)
            }
            if let correction, correction != 0, !state.suppressContentOffsetAdjustment {
                context.contentOffsetAdjustment = CGPoint(x: 0, y: correction)
            }
        }
        collectionView.collectionViewLayout.invalidateLayout(with: context)
#if DEBUG
        traceOffset("invalidateApplied", itemID: itemID,
                    after: collectionView.contentOffset.y)
#endif
    }

    // MARK: - Cell self-sizing exceptions (category B)

    /// Controller-driven preferred-height application for the controlled
    /// exceptions (fold/notice/tail). Unlike the hosted-contract rows, these
    /// keep the legacy path: the controller asks the visible cell for its
    /// fitting height after a reconfiguration and feeds it here. The decision
    /// and invalidation match the category-B rules.
    private(set) var preferredHeightDiagnostics: [String: Int] = [:]
    private(set) var prepareCount = 0
    private(set) var lastPreferredAppliedHeight: [String: CGFloat] = [:]
    private(set) var lastPreparedHeight: [String: CGFloat] = [:]
    private(set) var lastPreparedKeyRevision: [String: Int] = [:]
#if DEBUG
    /// Gate counter: a height change applied while the reader's finger is down
    /// or the list is coasting. Must stay zero once the official contract is
    /// in place (`TimelineAutoRun.gestureFreeze`).
    private(set) var debugHeightApplicationsDuringGesture = 0
    /// Accepted `preferredLayoutAttributesFitting` self-measures. The gate
    /// asserts an unmeasured row measures itself once, never again after the
    /// cache says measured.
    private(set) var debugSelfMeasureCount = 0
    /// Accepted self-measure heights in order, with the height the layout
    /// actually wrote (`ceil`ed). The first-fit seed gate reads this to prove
    /// a row's first fitted value is the structured seed and never a smaller
    /// pre-parse placeholder. Kept to the most recent 64 entries.
    private(set) var debugSelfMeasureHeights: [(itemID: String, height: CGFloat)] = []
    func clearDebugSelfMeasureHeights() { debugSelfMeasureHeights.removeAll() }
    /// Why the offset moved during a height application. The gate reads this
    /// instead of guessing which path took the reader's scroll.
    private(set) var debugOffsetTrace: [[String: Any]] = []
    func clearDebugOffsetTrace() { debugOffsetTrace.removeAll() }
    /// Height batches that do not go through `invalidateHeight`, with the
    /// offset they planned to apply. The gesture gate reads this to name the
    /// writer when a height application moves the reader's scroll.
    private(set) var debugHeightUpdateTrace: [[String: Any]] = []
    func clearDebugHeightUpdateTrace() { debugHeightUpdateTrace.removeAll() }
    private func traceHeightUpdate(_ kind: String, itemIDs: [String],
                                   contentSize: CGFloat, offset: CGFloat?,
                                   inside: Bool, before: CGFloat, after: CGFloat? = nil) {
        if debugHeightUpdateTrace.count >= 12 { debugHeightUpdateTrace.removeFirst() }
        var entry: [String: Any] = ["kind": kind, "items": itemIDs,
                                    "contentSize": Double(contentSize),
                                    "inside": inside, "before": Double(before)]
        if let offset { entry["offset"] = Double(offset) }
        if let after { entry["after"] = Double(after) }
        debugHeightUpdateTrace.append(entry)
    }
    private func traceOffset(_ kind: String, itemID: String = "",
                             delta: CGFloat = 0, correction: CGFloat? = nil,
                             before: CGFloat? = nil, after: CGFloat? = nil,
                             note: String = "") {
        if debugOffsetTrace.count >= 24 { debugOffsetTrace.removeFirst() }
        var entry: [String: Any] = ["kind": kind]
        if !itemID.isEmpty { entry["item"] = itemID }
        if delta != 0 { entry["delta"] = Double(delta) }
        if let correction { entry["correction"] = Double(correction) }
        if let before { entry["before"] = Double(before) }
        if let after { entry["after"] = Double(after) }
        if !note.isEmpty { entry["note"] = note }
        debugOffsetTrace.append(entry)
    }
#endif

    private func notePreferred(_ key: String) {
        preferredHeightDiagnostics[key, default: 0] += 1
    }

    /// The caller passes the key it fitted the cell for, because a same-width
    /// content change keeps the row measured but replaces the key; reading
    /// the retired key off the attributes would reject the one report this
    /// path has. `staleKey` still drops a report from a replaced snapshot.
    func applyPreferredHeight(_ height: CGFloat, for itemID: String, key: TimelineHeightKey) {
        notePreferred("call")
        guard let attributes = attributesByItemID[itemID] else {
            notePreferred("noAttributes"); return
        }
        guard attributes.policy.acceptsPreferredHeight else {
            notePreferred("notInteractive"); return
        }
        guard heights.currentKey(for: itemID) == key else {
            notePreferred("staleKey"); return
        }
        let delta = height - attributes.frame.height
        guard abs(delta) > 0.5 else {
            notePreferred("noDelta"); return
        }
        notePreferred("delta")
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
            hasCachedHeight: heights.isMeasured(itemID: itemID, width: key.width))
        if decision.height == .deferUntilSettled {
            notePreferred("deferred")
            deferredHeights[itemID] = DeferredHeight(key: key, height: height)
            return
        }
        notePreferred("applied")
        lastPreferredAppliedHeight[itemID] = height
        heights.set(height, for: key, tier: .measured)
        heights.noteDisplayedHeight(height, for: itemID)
        attributes.isMeasured = true
        invalidateHeight(itemID: itemID, attributes: attributes,
                         correction: decision.correction, contentSizeDelta: delta,
                         state: state, probeSource: "preferred")
    }

    // MARK: - Streaming reveal height (per frame)

    /// The reveal's clamped bottom, in row coordinates. This is a display
    /// override, not a measurement: it is used by `prepare` but never written
    /// to the height cache, so clearing it restores the measured height.
    /// `adjustOffset` is false while the controller's spring follower owns
    /// the scroll: the height changes without the layout correcting the
    /// offset underneath it.
    func applyStreamingHeight(_ height: CGFloat, for itemID: String,
                              adjustOffset: Bool = true) {
        guard height.isFinite, height > 0 else { return }
        let previous = streamingHeights[itemID]
        streamingHeights[itemID] = height
        guard previous == nil || abs((previous ?? 0) - height) > 0.5 else { return }
        guard let collectionView = collectionView,
              let attributes = attributesByItemID[itemID] else { return }
        let delta = height - attributes.frame.height
        guard abs(delta) > 0.5 else { return }
        let state = host?.layoutInteractionState() ?? TimelineLayoutInteractionState()
        let decision = TimelinePreferredAttributesDecision.selfSizing(
            delta: delta,
            cellMinY: attributes.frame.minY,
            cellMaxY: attributes.frame.maxY,
            viewportTop: viewportTop,
            viewportBottom: viewportBottom,
            isStreaming: true,
            isAutoScrollPinning: state.isAutoScrollPinning,
            isTracking: state.isTracking,
            isDecelerating: state.isDecelerating,
            keyboardTransition: state.keyboardTransition,
            hasCachedHeight: true)
        if decision.height == .deferUntilSettled { return }
#if DEBUG
        traceOffset("streaming", itemID: itemID, delta: delta,
                    correction: adjustOffset ? decision.correction : nil,
                    before: collectionView.contentOffset.y,
                    note: adjustOffset ? "\(decision.height)" : "noAdjust")
#endif
        invalidateHeight(itemID: itemID, attributes: attributes,
                         correction: adjustOffset ? decision.correction : nil,
                         contentSizeDelta: delta, state: state, probeSource: "")
    }

    /// Drop the override without invalidating. The controller calls this
    /// while measuring a handed-over row, before the next `prepare` reads it;
    /// invalidating there would race the apply.
    func discardStreamingHeight(for itemID: String) {
        streamingHeights.removeValue(forKey: itemID)
    }

    /// Whether the row is currently showing a per-frame reveal height. The
    /// controller's settle pass leaves such a row alone: its visible height is
    /// the reveal, not the stored measurement.
    func hasStreamingHeight(for itemID: String) -> Bool {
        streamingHeights[itemID] != nil
    }

    /// The reveal finished (or the cell left the display). The row returns to
    /// the cached measurement.
    ///
    /// The height change moves every following row, exactly like a measurement
    /// correction; invalidating only this item left the rows below at their
    /// previous frames, which is the overlapping-band report. A streaming row
    /// that scrolls out at the top is the common trigger (device probe
    /// 2026-10-23: a 42 pt cell overlap that survived seven samples).
    func clearStreamingHeight(for itemID: String) {
        guard streamingHeights.removeValue(forKey: itemID) != nil else { return }
        guard let collectionView = collectionView,
              let attributes = attributesByItemID[itemID],
              let key = attributes.heightKey else { return }
        // Cell-reported rows never carry a reveal override; the layout owns
        // their height through the hosted path and must not second-guess it
        // with a cache lookup here.
        guard !attributes.usesCellReportedHeight else { return }
        let fallback = attributes.item.map {
            host?.layoutEstimateKind(for: $0) ?? .row
        } ?? .row
        let resolved = heights.resolvedHeight(for: key, itemID: itemID, fallback: fallback)
        let delta = resolved - attributes.frame.height
#if AA_TIMELINE_PROBE
        TimelineProbeStore.shared.noteHeightChange(
            itemID: itemID, item: attributes.item,
            old: attributes.frame.height, new: resolved, source: "streamEnd")
#endif
        if heights.isMeasured(itemID: itemID, width: key.width) {
            attributes.isMeasured = true
        }
        let state = host?.layoutInteractionState() ?? TimelineLayoutInteractionState()
        // The legacy streaming row returns to its measured height through the
        // same category-A decision as a pending measurement: only a row whose
        // top is above the viewport moves the text the reader sees.
        let decision = TimelinePreferredAttributesDecision.pendingMeasurement(
            delta: delta,
            cellMaxY: attributes.frame.maxY,
            viewportTop: viewportTop,
            isStreaming: false,
            isAutoScrollPinning: state.isAutoScrollPinning,
            isTracking: state.isTracking,
            isDecelerating: state.isDecelerating,
            keyboardTransition: state.keyboardTransition,
            suppressContentOffsetAdjustment: state.suppressContentOffsetAdjustment,
            hasCachedHeight: heights.isMeasured(itemID: itemID, width: key.width))
        let context = UICollectionViewLayoutInvalidationContext()
        context.invalidateItems(at: invalidatablePaths(by: attributes))
        if abs(delta) > 0.5 {
            context.contentSizeAdjustment = CGSize(width: 0, height: delta)
        }
        if decision.height == .accept, let correction = decision.correction,
           !state.suppressContentOffsetAdjustment {
            context.contentOffsetAdjustment = CGPoint(x: 0, y: correction)
        }
        collectionView.collectionViewLayout.invalidateLayout(with: context)
    }

    /// The official contract: an unmeasured cell may surface its one
    /// self-measure; once the row has a real height the layout owns it and
    /// rejects any further preferred height. A parked measurement (deferred
    /// under the finger) also rejects, so the content cannot apply its height
    /// before the matching compensation can.
    override func shouldInvalidateLayout(forPreferredLayoutAttributes preferredAttributes: UICollectionViewLayoutAttributes,
                                         withOriginalAttributes originalAttributes: UICollectionViewLayoutAttributes) -> Bool {
        guard let original = originalAttributes as? TimelineListLayoutAttributes,
              // Phase 1 migrates the Code rows only. The Chat rows still use
              // the controller's visible-cell polling; letting their async
              // Markdown self-measure here as well would race that path (the
              // first pass often reports pre-parse stack spacing).
              original.usesCellReportedHeight,
              original.item.map({ deferredHeights[$0.itemID] == nil }) ?? false,
              !original.isMeasured else {
            notePreferred("uikitPreferredRejected")
            return false
        }
        // The official first materialization: an unmeasured cell fits its real
        // content once. Later changes never come through this path; they
        // arrive as the hosting geometry report and go through
        // `applyMeasuredHeight`'s changed-only gate.
        notePreferred("uikitPreferredAccepted")
        return true
    }

    /// Carries the row and the fitted height into `invalidateLayout(with:)`.
    /// UIKit's default context has neither, and the layout is the only writer
    /// of the height cache.
    override func invalidationContext(
        forPreferredLayoutAttributes preferredAttributes: UICollectionViewLayoutAttributes,
        withOriginalAttributes originalAttributes: UICollectionViewLayoutAttributes
    ) -> UICollectionViewLayoutInvalidationContext {
        let context = TimelinePreferredHeightInvalidationContext()
        if let original = originalAttributes as? TimelineListLayoutAttributes {
            context.itemID = original.item?.itemID
            context.heightKey = original.heightKey
            // The custom context replaces the default one, so name the row
            // explicitly: the changed row and the visible rows below it.
            context.invalidateItems(at: invalidatablePaths(by: original))
        }
        context.preferredHeight = preferredAttributes.frame.height
        return context
    }

    override func invalidateLayout(with context: UICollectionViewLayoutInvalidationContext) {
        if let preferred = context as? TimelinePreferredHeightInvalidationContext {
            applySelfMeasuredHeight(from: preferred)
        }
        super.invalidateLayout(with: context)
    }

    /// The cell fitted its real content for an unmeasured row. Write the
    /// measurement and move the reader's content by the same rules as a
    /// controller measurement; the next `prepare` uses the new height.
    private func applySelfMeasuredHeight(from context: TimelinePreferredHeightInvalidationContext) {
        guard let itemID = context.itemID,
              let height = context.preferredHeight,
              height.isFinite, height > 0,
              let attributes = attributesByItemID[itemID],
              isCurrent(attributes),
              let key = context.heightKey,
              attributes.heightKey == key,
              heights.currentKey(for: itemID) == key else { return }
#if DEBUG
        debugSelfMeasureCount += 1
#endif
        // Official first-fit (0x101a39244): the value is rounded up before it
        // reaches the cache, so every writer sees the same number. The settle
        // path already ceils its fit; the self-measure path must do the same
        // or the two writers trade 52.0 ↔ 51.3 forever.
        let measured = ceil(height)
#if DEBUG
        debugSelfMeasureHeights.append((itemID: itemID, height: measured))
        if debugSelfMeasureHeights.count > 64 {
            debugSelfMeasureHeights.removeFirst(debugSelfMeasureHeights.count - 64)
        }
#endif
        let delta = measured - displayedHeight(for: itemID, key: key, attributes: attributes)
        lastAppliedHeight[itemID] = AppliedHeight(key: key, height: measured)
        if abs(delta) <= 0.5 {
            heights.set(measured, for: key, tier: .measured)
            heights.resolvePending(itemID)
            heights.noteDisplayedHeight(measured, for: itemID)
            attributes.isMeasured = true
            return
        }
        let correction = TimelinePreferredAttributesDecision.heightChangeCorrection(
            delta: delta, cellMaxY: attributes.frame.maxY, viewportTop: viewportTop)
#if DEBUG
        traceHeightUpdate("selfMeasure", itemIDs: [itemID],
                          contentSize: delta, offset: correction,
                          inside: isInsideUpdate,
                          before: collectionView?.contentOffset.y ?? 0)
#endif
        applyHeightUpdates([
            HeightUpdate(itemID: itemID, key: key, height: measured,
                         attributes: attributes, offsetDelta: correction,
                         contentSizeDelta: delta, source: "selfMeasure")
        ], reusing: context)
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
        heightOwedToUpdate = nil
        insertionOwed?.cancel()
        insertionOwed = nil
    }

    /// A window replacement drops the rows and the offset the parked heights
    /// belong to; they must not land on another window's snapshot.
    func discardParkedHeights() {
        deferredHeights.removeAll()
        heightOwedToUpdate = nil
    }

    /// The attribute object still belongs to the snapshot the layout is
    /// describing. A recycled cell can deliver a report after a prepare
    /// replaced the attribute; writing that height would target a row that no
    /// longer exists (or an index path of another item).
    private func isCurrent(_ attributes: TimelineListLayoutAttributes) -> Bool {
        let index = attributes.indexPath.item
        guard attributesByIndex.indices.contains(index),
              let item = attributes.item else { return false }
        // Compare the item, not the object: UIKit may hand a copy back for
        // `preferredLayoutAttributesFitting`, and an item can change its key
        // between the report and the prepare that catches up with it.
        return attributesByIndex[index].item == item
    }

    /// The attribute flag is written by the last `prepare`; the host call
    /// covers a report that arrives after the content changed but before the
    /// new snapshot rebuilt the attributes.
    private func rowUsesCellReportedHeight(
        _ attributes: TimelineListLayoutAttributes
    ) -> Bool {
        if attributes.usesCellReportedHeight { return true }
        guard let item = attributes.item,
              let host = host as? TimelineListLayoutCellReportedHeightHost else { return false }
        return host.layoutUsesCellReportedHeight(for: item)
    }

    /// The height the layout currently displays for this row. The cache wins
    /// over the attribute frame: an application writes the cache immediately,
    /// while the frame is rebuilt on the next `prepare`. Without this, two
    /// reports in one runloop (a streaming row grows twice) would both count
    /// their delta from the same old frame and double the compensation.
    ///
    /// This uses the same resolver as `prepare` so a report's delta is always
    /// measured against the height the row actually shows. The frame height is
    /// only the last resort (a row the cache no longer knows).
    private func displayedHeight(for itemID: String, key: TimelineHeightKey,
                                 attributes: TimelineListLayoutAttributes) -> CGFloat {
        heights.resolvedHeight(for: key, itemID: itemID,
                               fallback: .fixed(attributes.frame.height))
    }

    /// Does a height change on this row move anything the reader can see?
    private func heightChangeAffectsVisibleRows(
        _ attributes: TimelineListLayoutAttributes
    ) -> Bool {
        TimelinePreferredAttributesDecision.heightChangeAffectsVisibleRows(
            cellMinY: attributes.frame.minY,
            cellMaxY: attributes.frame.maxY,
            contentHeight: contentHeight,
            viewportTop: viewportTop,
            viewportBottom: viewportBottom)
    }

    // MARK: - Applying parked heights

    private struct HeightUpdate {
        let itemID: String
        let key: TimelineHeightKey
        let height: CGFloat
        let attributes: TimelineListLayoutAttributes
        /// Offset compensation chosen by the decision; nil means the height
        /// applies without moving the content.
        let offsetDelta: CGFloat?
        let contentSizeDelta: CGFloat
        let source: String
    }

    /// One context for one settled gesture: every parked height lands
    /// together with a single size/offset compensation, the same shape the
    /// official layout uses for its `rowMeasured` batch.
    ///
    /// `reusing` lets the preferred-attributes path write its adjustments
    /// into the context UIKit is already invalidating with, instead of
    /// starting a second invalidation inside the same update.
    private func applyHeightUpdates(
        _ updates: [HeightUpdate],
        reusing existingContext: UICollectionViewLayoutInvalidationContext? = nil
    ) {
        guard !updates.isEmpty, let collectionView else { return }
        let state = host?.layoutInteractionState() ?? TimelineLayoutInteractionState()
        let context = existingContext ?? UICollectionViewLayoutInvalidationContext()
        var affected: Set<IndexPath> = []
        var offset: CGFloat = 0
        var contentSize: CGFloat = 0
        var changed = false
        for update in updates {
            heights.set(update.height, for: update.key, tier: .measured)
            heights.resolvePending(update.itemID)
            heights.noteDisplayedHeight(update.height, for: update.itemID)
            update.attributes.isMeasured = true
            lastAppliedHeight[update.itemID] = AppliedHeight(key: update.key,
                                                             height: update.height)
            guard abs(update.contentSizeDelta) > 0.5 else { continue }
            changed = true
            contentSize += update.contentSizeDelta
            if let offsetDelta = update.offsetDelta { offset += offsetDelta }
            affected.formUnion(cellUpdatesAffected(by: update.attributes))
#if AA_TIMELINE_PROBE
            TimelineProbeStore.shared.noteHeightChange(
                itemID: update.itemID, item: update.attributes.item,
                old: update.attributes.frame.height, new: update.height,
                source: update.source)
#endif
        }
        guard changed else { return }
#if DEBUG
        let traceBefore = collectionView.contentOffset.y
        traceHeightUpdate("applyUpdates", itemIDs: updates.map(\.itemID),
                          contentSize: contentSize,
                          offset: abs(offset) > 0.5 ? offset : nil,
                          inside: isInsideUpdate, before: traceBefore)
#endif
        let liveCount = host?.layoutItemCount ?? attributesByIndex.count
        context.invalidateItems(at: affected.filter { $0.item < liveCount })
        if isInsideUpdate {
            if abs(offset) > 0.5 {
                if insertionOwed != nil,
                   insertionOwed?.expectedFirstRowID == host?.layoutFirstRowID {
                    insertionOwed?.adjustTarget(by: offset)
                } else {
                    addHeightOwed(offset)
                }
            }
        } else {
            if abs(contentSize) > 0.5 {
                context.contentSizeAdjustment = CGSize(width: 0, height: contentSize)
            }
            if abs(offset) > 0.5, !state.suppressContentOffsetAdjustment {
                context.contentOffsetAdjustment = CGPoint(x: 0, y: offset)
            }
        }
        if existingContext == nil {
            collectionView.collectionViewLayout.invalidateLayout(with: context)
        }
#if DEBUG
        traceHeightUpdate("applyUpdatesApplied", itemIDs: updates.map(\.itemID),
                          contentSize: 0, offset: nil, inside: isInsideUpdate,
                          before: traceBefore, after: collectionView.contentOffset.y)
#endif
    }

    private func apply(_ application: TimelinePullDeferOrdering.Application) {
        var updates: [HeightUpdate] = []
        for effect in application.effects {
            switch effect {
            case .settlePull:
                host?.layoutDidSettlePull()
            case .apply(let correction):
                guard let deferred = deferredHeights.removeValue(forKey: correction.itemID),
                      heights.currentKey(for: correction.itemID) == deferred.key,
                      let attributes = attributesByItemID[correction.itemID] else { continue }
                let contentSizeDelta = deferred.height
                    - displayedHeight(for: correction.itemID, key: deferred.key,
                                      attributes: attributes)
                let offset = TimelinePreferredAttributesDecision.heightChangeCorrection(
                    delta: contentSizeDelta, cellMaxY: attributes.frame.maxY,
                    viewportTop: viewportTop)
                updates.append(HeightUpdate(itemID: correction.itemID, key: deferred.key,
                    height: deferred.height, attributes: attributes,
                    offsetDelta: offset, contentSizeDelta: contentSizeDelta,
                    source: "deferred"))
            }
        }
        // A parked legacy height that never reached `TimelinePullDeferOrdering`
        // (the layout stores the value itself) must still land on settle.
        for (itemID, deferred) in deferredHeights.sorted(by: { $0.key < $1.key }) {
            guard heights.currentKey(for: itemID) == deferred.key,
                  let attributes = attributesByItemID[itemID] else { continue }
            let contentSizeDelta = deferred.height
                - displayedHeight(for: itemID, key: deferred.key, attributes: attributes)
            let offset = TimelinePreferredAttributesDecision.heightChangeCorrection(
                delta: contentSizeDelta, cellMaxY: attributes.frame.maxY,
                viewportTop: viewportTop)
            updates.append(HeightUpdate(itemID: itemID, key: deferred.key,
                height: deferred.height, attributes: attributes,
                offsetDelta: offset, contentSizeDelta: contentSizeDelta,
                source: "deferred"))
        }
        deferredHeights.removeAll()
        applyHeightUpdates(updates)
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

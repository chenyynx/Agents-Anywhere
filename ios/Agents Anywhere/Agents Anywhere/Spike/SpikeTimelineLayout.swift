import UIKit

/// Throwaway layout for the 6b spike. It now mirrors the shape the real plan
/// needs: an absolute `owedTarget`, an in-update gate, self-sizing
/// compensation for both "fully above" and "partially visible above" rows, and
/// a same-transaction bottom pin.
final class SpikeTimelineLayout: UICollectionViewLayout {
    enum CompensationMode: String {
        case fullyAboveOnly
        case aboveOrPartial
    }

    var itemIDs: [String] = []
    var estimates: [String: CGFloat] = [:]

    private(set) var measured: [String: CGFloat] = [:]
    private var itemAttributes: [UICollectionViewLayoutAttributes] = []
    private var totalHeight: CGFloat = 0
    private let spacing: CGFloat = 8

    /// Absolute target offset, not a delta. Official shape: `offsetOwed ?? proposed`.
    private(set) var owedTarget: CGFloat?
    private var owedConsumed = false
    private var isInsideUpdate = false

    var compensationMode: CompensationMode = .aboveOrPartial
    var isPinning = false

    var onTargetOffset: ((_ proposed: CGFloat, _ returned: CGFloat) -> Void)?
    var onPrepareForUpdates: (() -> Void)?
    var onFinalizeUpdates: (() -> Void)?
    var onInvalidationContext: ((_ delta: CGFloat) -> Void)?
    var onShouldInvalidate: (() -> Void)?
    var onAdjustment: ((_ delta: CGFloat) -> Void)?
    var onPinAdjustment: (() -> Void)?

    override var collectionViewContentSize: CGSize {
        CGSize(width: collectionView?.bounds.width ?? 0, height: totalHeight)
    }

    override func prepare() {
        super.prepare()
        guard let collectionView else { return }
        let width = collectionView.bounds.width
        itemAttributes.removeAll(keepingCapacity: true)
        itemAttributes.reserveCapacity(itemIDs.count)
        var y: CGFloat = 0
        for (index, id) in itemIDs.enumerated() {
            let height = measured[id] ?? estimates[id] ?? 200
            let attributes = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: index, section: 0))
            attributes.frame = CGRect(x: 0, y: y, width: width, height: height)
            itemAttributes.append(attributes)
            y += height + spacing
        }
        totalHeight = y
    }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        guard !itemAttributes.isEmpty else { return nil }
        var result: [UICollectionViewLayoutAttributes] = []
        for attributes in itemAttributes {
            if attributes.frame.maxY < rect.minY { continue }
            if attributes.frame.minY > rect.maxY { break }
            result.append(attributes)
        }
        return result
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard indexPath.item >= 0, indexPath.item < itemAttributes.count else { return nil }
        return itemAttributes[indexPath.item]
    }

    // MARK: Self-sizing

    override func shouldInvalidateLayout(
        forPreferredLayoutAttributes preferredAttributes: UICollectionViewLayoutAttributes,
        withOriginalAttributes originalAttributes: UICollectionViewLayoutAttributes
    ) -> Bool {
        onShouldInvalidate?()
        return true
    }

    override func invalidationContext(
        forPreferredLayoutAttributes preferredAttributes: UICollectionViewLayoutAttributes,
        withOriginalAttributes originalAttributes: UICollectionViewLayoutAttributes
    ) -> UICollectionViewLayoutInvalidationContext {
        let context = super.invalidationContext(
            forPreferredLayoutAttributes: preferredAttributes,
            withOriginalAttributes: originalAttributes
        )
        let index = preferredAttributes.indexPath.item
        guard index >= 0, index < itemIDs.count else { return context }

        let id = itemIDs[index]
        let oldHeight = originalAttributes.size.height
        let newHeight = preferredAttributes.size.height
        measured[id] = newHeight
        let delta = newHeight - oldHeight
        onInvalidationContext?(delta)

        // Official `isInsideAnUpdate` gate: during an update transaction the
        // owed target is the only compensation; do not also adjust the offset.
        guard !isInsideUpdate, abs(delta) > 0.5, let collectionView,
              !collectionView.isTracking, !collectionView.isDecelerating else {
            return context
        }

        if isPinning, index == itemIDs.count - 1 {
            context.contentOffsetAdjustment = CGPoint(x: 0, y: delta)
            onPinAdjustment?()
            onAdjustment?(delta)
            return context
        }

        let frame = originalAttributes.frame
        let offsetY = collectionView.contentOffset.y
        let shouldAdjust: Bool
        switch compensationMode {
        case .fullyAboveOnly:
            shouldAdjust = frame.maxY <= offsetY
        case .aboveOrPartial:
            shouldAdjust = frame.minY < offsetY
        }
        if shouldAdjust {
            context.contentOffsetAdjustment = CGPoint(x: 0, y: delta)
            onAdjustment?(delta)
        }
        return context
    }

    // MARK: Insertion compensation

    override func prepare(forCollectionViewUpdates updateItems: [UICollectionViewUpdateItem]) {
        super.prepare(forCollectionViewUpdates: updateItems)
        isInsideUpdate = true
        onPrepareForUpdates?()
    }

    override func finalizeCollectionViewUpdates() {
        super.finalizeCollectionViewUpdates()
        isInsideUpdate = false
        // Official fallback: if UIKit never queried the target during this
        // transaction, land the owed offset here instead of silently dropping it.
        if let target = owedTarget, !owedConsumed {
            collectionView?.setContentOffset(CGPoint(x: 0, y: target), animated: false)
        }
        owedTarget = nil
        owedConsumed = false
        onFinalizeUpdates?()
    }

    override func targetContentOffset(forProposedContentOffset proposedContentOffset: CGPoint) -> CGPoint {
        guard let target = owedTarget else {
            onTargetOffset?(proposedContentOffset.y, proposedContentOffset.y)
            return proposedContentOffset
        }
        // Absolute and idempotent: every query in the same transaction returns
        // the same target, no matter what `proposedContentOffset` carries.
        owedConsumed = true
        onTargetOffset?(proposedContentOffset.y, target)
        return CGPoint(x: proposedContentOffset.x, y: target)
    }

    // MARK: Helpers

    /// Height sum before `index` using the same rule as `prepare()`.
    func yOffset(of index: Int, ids: [String], estimates: [String: CGFloat]) -> CGFloat {
        var y: CGFloat = 0
        for offset in 0..<min(index, ids.count) {
            let id = ids[offset]
            y += (measured[id] ?? estimates[id] ?? 200) + spacing
        }
        return y
    }

    func estimate(for item: SpikeModel.Item) -> CGFloat {
        let lines = item.text.split(separator: "\n", omittingEmptySubsequences: false).count
        return CGFloat(lines) * 20 + 24
    }

    /// Read-only access for the auto-run probe; `measured` itself stays private.
    func measuredHeight(of id: String) -> CGFloat? {
        measured[id]
    }

    func setOwedTarget(_ value: CGFloat?) {
        owedTarget = value
        owedConsumed = false
    }

    /// The auto-run uses this to prove the absolute target is idempotent when
    /// UIKit queries `targetContentOffset` more than once per transaction.
    func debugSetOwedTarget(_ value: CGFloat?) {
        setOwedTarget(value)
    }
}

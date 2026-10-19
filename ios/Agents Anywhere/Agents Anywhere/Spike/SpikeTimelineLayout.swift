import UIKit

/// Throwaway layout for the 6b spike. It exists to answer four runtime questions:
/// does `targetContentOffset` fire on a non-animated apply, does a one-shot owed
/// offset land, do self-sizing invalidations arrive, and what happens to the
/// content height while the finger is down.
final class SpikeTimelineLayout: UICollectionViewLayout {
    var itemIDs: [String] = []
    var estimates: [String: CGFloat] = [:]

    private(set) var measured: [String: CGFloat] = [:]
    private var itemAttributes: [UICollectionViewLayoutAttributes] = []
    private var totalHeight: CGFloat = 0
    private let spacing: CGFloat = 8

    /// One-shot offset owed to the reader after a prepend. Cleared at finalize.
    var owed: CGFloat = 0
    var anchorID: String?
    private(set) var anchorAfterY: CGFloat = 0

    var onTargetOffset: ((_ proposed: CGFloat, _ returned: CGFloat) -> Void)?
    var onPrepareForUpdates: (() -> Void)?
    var onFinalizeUpdates: (() -> Void)?
    var onInvalidationContext: ((_ delta: CGFloat) -> Void)?
    var onShouldInvalidate: (() -> Void)?

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
        if let anchorID, let index = itemIDs.firstIndex(of: anchorID), index < itemAttributes.count {
            anchorAfterY = itemAttributes[index].frame.minY
        }
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

        if abs(delta) > 0.5, let collectionView,
           !collectionView.isTracking, !collectionView.isDecelerating {
            let frame = originalAttributes.frame
            if frame.maxY <= collectionView.contentOffset.y {
                context.contentOffsetAdjustment = CGPoint(x: 0, y: delta)
            }
        }
        return context
    }

    // MARK: Insertion compensation

    override func prepare(forCollectionViewUpdates updateItems: [UICollectionViewUpdateItem]) {
        super.prepare(forCollectionViewUpdates: updateItems)
        onPrepareForUpdates?()
    }

    override func finalizeCollectionViewUpdates() {
        super.finalizeCollectionViewUpdates()
        onFinalizeUpdates?()
        owed = 0
    }

    override func targetContentOffset(forProposedContentOffset proposedContentOffset: CGPoint) -> CGPoint {
        let returned = CGPoint(x: proposedContentOffset.x, y: proposedContentOffset.y + owed)
        onTargetOffset?(proposedContentOffset.y, returned.y)
        return returned
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
}

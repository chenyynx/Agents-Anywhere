import Foundation

/// A one-shot absolute offset that `targetContentOffset(forProposedContentOffset:)`
/// may hand to UIKit exactly once per update, with a finalize fallback for the
/// update that never asked.
///
/// The value returned is absolute, not `proposed + delta`, because UIKit may
/// query the target more than once in one transaction; an absolute value is
/// idempotent (the spike measured 9140/9140 on a double query).
nonisolated struct TimelineOneShotOwed: Equatable {
    private(set) var target: CGFloat?
    /// Set when the layout's target query consumed the owed value. Finalize
    /// only applies a fallback when the query never happened.
    private(set) var hasBeenOffered = false

    init(target: CGFloat? = nil) {
        self.target = target
    }

    var isEmpty: Bool { target == nil }

    mutating func replace(target: CGFloat?) {
        self.target = target
        hasBeenOffered = false
    }

    /// Returns the absolute target unchanged for every query in the same
    /// transaction, or the proposed offset when nothing is owed.
    mutating func offer(proposed: CGFloat) -> CGFloat {
        guard let target else { return proposed }
        hasBeenOffered = true
        return target
    }

    /// Finalize fallback: if the update never queried, the controller must
    /// apply this offset itself. Always clears; a nil result means there is
    /// nothing to apply.
    mutating func takeAfterFinalize() -> CGFloat? {
        defer { clear() }
        guard let target, !hasBeenOffered else { return nil }
        return target
    }

    mutating func clear() {
        target = nil
        hasBeenOffered = false
    }
}

/// Absolute prepend compensation for one history request.
///
/// The origin is captured when the request starts:
/// `originOffset = max(-topInset, offsetY)` — an outward pull can still be
/// bouncing, and restoring `-135` instead of the resting inset would leave the
/// page over-scrolled (existing `TimelineHistoryPosition` test: 920).
///
/// The correction direction is "a page actually arrived": compare
/// `layout.firstRowID` with the origin's. Equal means no insertion (a tail
/// append, a re-layout); returning early there is what keeps repeated layout
/// passes from accumulating. Completion waiting is a different question and
/// lives in `TimelineHistoryPosition.isReadyToFinish` (`== expected`).
nonisolated struct TimelineInsertionOwed: Equatable {
    let generation: Int
    let origin: TimelineHistoryLayout?
    let originOffset: CGFloat
    private var owed = TimelineOneShotOwed()
    private(set) var isCancelled = false

    init(generation: Int, origin: TimelineHistoryLayout?, offsetY: CGFloat, topInset: CGFloat) {
        self.generation = generation
        self.origin = origin
        self.originOffset = max(-topInset, offsetY)
    }

    var target: CGFloat? { owed.target }
    var hasOwed: Bool { !isCancelled && !owed.isEmpty }
    /// True once no correction can still be applied: either the target was
    /// consumed/cleared or the request was cancelled.
    var isSettled: Bool { isCancelled || owed.isEmpty }

    /// Records a newly measured layout. Returns the absolute target when it is
    /// a real prepend, nil for a tail append/re-layout or a mismatch.
    @discardableResult
    mutating func update(layout new: TimelineHistoryLayout) -> CGFloat? {
        guard !isCancelled, let origin,
              new.anchorRowID == origin.anchorRowID,
              new.edge == origin.edge,
              new.firstRowID != origin.firstRowID else { return nil }
        let target = originOffset + new.y - origin.y
        owed.replace(target: target)
        return target
    }

    /// The layout's `targetContentOffset` entry point.
    mutating func targetOffset(proposed: CGFloat) -> CGFloat {
        guard !isCancelled else { return proposed }
        return owed.offer(proposed: proposed)
    }

    /// A measurement correction that lands inside the same update transaction
    /// folds into the absolute target instead of posting a second
    /// `contentOffsetAdjustment` (v7 §3.4.5 transaction gate).
    mutating func adjustTarget(by delta: CGFloat) {
        guard !isCancelled, let target = owed.target, delta != 0 else { return }
        owed.replace(target: target + delta)
    }

    /// `finalizeCollectionViewUpdates` fallback for an update UIKit never
    /// asked about. The controller applies it with animations disabled and
    /// retries once on the next runloop if the old content size clamped it.
    mutating func finalizeFallback() -> CGFloat? {
        guard !isCancelled else { owed.clear(); return nil }
        return owed.takeAfterFinalize()
    }

    /// A reader gesture, the bottom pill, `loadLatest`, or a navigation
    /// generation change takes over: a slow response must not move them.
    mutating func cancel() {
        isCancelled = true
        owed.clear()
    }

    mutating func clear() { owed.clear() }
}

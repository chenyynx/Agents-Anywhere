import Foundation

/// Orders the two things that happen when a browsing gesture settles: the
/// pull decision must be made first, then parked height corrections applied.
///
/// This is only about ordering and parking. The pull's own thresholds
/// (2pt content-height tolerance, 24pt release movement, `wasInteracting`) stay
/// in `TimelineHistoryPull` and are deliberately not duplicated here. A
/// concurrent streaming growth larger than 2pt still cancels the pull — the
/// current behavior — so this type must not be read as "the pull never
/// cancels".
///
/// Parking follows OpenMinis: while dragging/decelerating, a cached row's
/// shrink or stable correction waits; growth applies immediately so the row
/// cannot clip; an uncached row may take its first measurement.
nonisolated struct TimelinePullDeferOrdering: Equatable {
    enum Phase: Equatable {
        case idle
        case dragging
        case decelerating
    }

    enum HeightChange: Equatable {
        case growth
        case shrink
        case stable
    }

    enum HeightDecision: Equatable {
        case applyNow
        case park
    }

    struct Correction: Equatable {
        let itemID: String
        let delta: CGFloat
        let change: HeightChange
    }

    /// The settle effects in execution order. `settlePull` always comes
    /// first; corrections follow in a deterministic item order.
    enum Effect: Equatable {
        case settlePull
        case apply(Correction)
    }

    struct Application: Equatable {
        let effects: [Effect]

        var corrections: [Correction] {
            effects.compactMap { effect in
                guard case .apply(let correction) = effect else { return nil }
                return correction
            }
        }
    }

    private(set) var phase = Phase.idle
    private(set) var deferred: [String: Correction] = [:]

    mutating func beginDrag() {
        phase = .dragging
    }

    /// `willDecelerate == false` means the gesture is already over, so the
    /// pull settles now. `true` waits for `endDeceleration()`: applying
    /// deferred corrections mid-flight would be suppressed by the
    /// `!isDecelerating` guard and silently lost.
    @discardableResult
    mutating func endDrag(willDecelerate: Bool) -> Application? {
        guard phase == .dragging else { return nil }
        if willDecelerate {
            phase = .decelerating
            return nil
        }
        phase = .idle
        return takeApplication()
    }

    @discardableResult
    mutating func endDeceleration() -> Application? {
        guard phase == .decelerating else { return nil }
        phase = .idle
        return takeApplication()
    }

    /// Navigation suspension cancels the browse session; deferred corrections
    /// belong to the old viewport and must not land later.
    mutating func cancel() {
        phase = .idle
        deferred.removeAll()
    }

    mutating func heightChange(itemID: String, delta: CGFloat,
                               hasCachedHeight: Bool) -> HeightDecision {
        let change: HeightChange = delta > 0 ? .growth : (delta < 0 ? .shrink : .stable)
        guard phase != .idle else { return .applyNow }
        guard hasCachedHeight, change != .growth else { return .applyNow }
        deferred[itemID] = Correction(itemID: itemID, delta: delta, change: change)
        return .park
    }

    private mutating func takeApplication() -> Application {
        let corrections = deferred.values.sorted { $0.itemID < $1.itemID }
        deferred.removeAll()
        return Application(effects: [.settlePull] + corrections.map { .apply($0) })
    }
}

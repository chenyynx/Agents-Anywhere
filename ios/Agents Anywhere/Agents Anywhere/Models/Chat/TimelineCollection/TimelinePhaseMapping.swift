import Foundation

/// Maps native scroll callbacks onto the shared `TimelineScrollState.Phase`.
///
/// The collection controller receives `UIScrollViewDelegate` events instead of
/// SwiftUI's `onScrollPhaseChange`. This type is the one translation point, so
/// the phase rules can be unit-tested as an event sequence:
///
/// - a drag begins as `.interacting`; `.tracking` has no native source and is
///   never produced;
/// - `didEndDragging(willDecelerate:)` decides `.decelerating` vs `.idle`;
/// - animated returns and status-bar scroll-to-top both surface as `.animating`,
///   and their completion as `.idle`;
/// - a no-op animated scroll never calls `scrollViewDidEndScrollingAnimation`
///   (measured 0 in the spike), so the controller must also advance the
///   mapping with a bounded watchdog event.
nonisolated struct TimelinePhaseMapping: Equatable {
    enum Event: Equatable {
        case willBeginDragging
        case didEndDragging(willDecelerate: Bool)
        case didEndDecelerating
        case animationBegan
        case animationEnded
        case scrollToTopBegan
        case scrollToTopEnded
        /// The controller's animation-duration-plus-one-frame fallback.
        case watchdogExpired
    }

    struct Transition: Equatable {
        let previous: TimelineScrollState.Phase
        let current: TimelineScrollState.Phase
        /// The reader took the page; callers cancel restoration and release
        /// any programmatic target on this edge.
        let gestureBegan: Bool
        /// An animation the page was waiting on has ended (real callback or
        /// watchdog). False when a late completion arrives outside an
        /// animation.
        let animationCompleted: Bool
    }

    private(set) var phase: TimelineScrollState.Phase = .idle

    @discardableResult
    mutating func apply(_ event: Event) -> Transition {
        let previous = phase
        var gestureBegan = false
        var animationCompleted = false
        switch event {
        case .willBeginDragging:
            gestureBegan = previous != .interacting
            phase = .interacting
        case .didEndDragging(let willDecelerate):
            phase = willDecelerate ? .decelerating : .idle
        case .didEndDecelerating:
            phase = .idle
        case .animationBegan, .scrollToTopBegan:
            phase = .animating
        case .animationEnded, .scrollToTopEnded:
            animationCompleted = previous == .animating
            phase = .idle
        case .watchdogExpired:
            if previous == .animating {
                animationCompleted = true
                phase = .idle
            }
        }
        return Transition(previous: previous, current: phase,
                          gestureBegan: gestureBegan, animationCompleted: animationCompleted)
    }
}

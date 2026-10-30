import Foundation

/// The timeline's paging/return guards as one pure state machine.
///
/// The rules that decide *whether* a load or a return may run live here so
/// they are testable without UIKit: the collection controller feeds it facts
/// (viewport, reader actions, page completions) and asks it before firing.
/// The controller still owns the gesture/geometry; this type only owns the
/// guards that previously scattered across five closures.
struct TimelinePagingPolicy: Equatable, Sendable {
    /// The near-top auto-load latch: one shot per reader gesture.
    private(set) var olderArmed = true
    /// Opening holds the top-edge trigger until the bottom is observed.
    private(set) var openingBottomPending = false
    /// Counts reader-driven position changes; an armed return from before one
    /// must not land.
    private(set) var readerIntentGeneration = 0
    /// The generation an armed bottom return was taken under, or nil when no
    /// return is armed.
    private(set) var armedReturnGeneration: Int?

    /// The near-top trigger may fire. Pure: the caller owns the viewport.
    func mayAutoLoadOlder(contentIsTallerThanViewport: Bool) -> Bool {
        guard !openingBottomPending, olderArmed else { return false }
        return contentIsTallerThanViewport
    }

    /// Firing consumes the shot until the next gesture re-arms it.
    mutating func didAutoLoadOlder() { olderArmed = false }

    /// The viewport left the near-top band; the latch re-arms on its own.
    /// Distinct from `readerMoved()`: no intent generation bump, so a layout
    /// change cannot void an armed bottom return.
    mutating func noteViewportLeftTop() {
        olderArmed = true
    }

    /// A new reader gesture: re-arm the near-top shot and count the intent.
    mutating func readerMoved() {
        olderArmed = true
        readerIntentGeneration &+= 1
        openingBottomPending = false
    }

    /// A history page request counts as reader intent but must not re-arm the
    /// near-top shot or release the opening gate.
    mutating func noteHistoryPaging() {
        readerIntentGeneration &+= 1
    }

    /// The opening asked for the bottom; hold the top trigger until it lands.
    mutating func beginOpening() {
        openingBottomPending = true
    }

    /// The opening's bottom landing was observed (only real content counts).
    mutating func noteLanding(contentIsTallerThanViewport: Bool, atBottom: Bool) {
        guard openingBottomPending, contentIsTallerThanViewport, atBottom else { return }
        openingBottomPending = false
    }

    /// The opening's bounded fallback expired; the trigger is free again.
    mutating func openingFallbackExpired() {
        openingBottomPending = false
    }

    /// A request wants a window replacement to land at the bottom.
    mutating func armBottomReturn() {
        armedReturnGeneration = readerIntentGeneration
    }

    /// The window replaced; whether the armed return may still land.
    mutating func resolveBottomReturn() -> Bool {
        guard let generation = armedReturnGeneration else { return false }
        armedReturnGeneration = nil
        return generation == readerIntentGeneration
    }

    /// The window replacement resolved without a landing (reader moved on).
    mutating func disarmBottomReturn() {
        armedReturnGeneration = nil
    }
}

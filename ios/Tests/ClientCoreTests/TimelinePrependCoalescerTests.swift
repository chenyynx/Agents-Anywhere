import Foundation
import Testing
@testable import ClientCore

/// The opening-flood governance's pure half: history-page prepends land once
/// per capped hold — one repaint for a flood inside the window, at most one
/// per window while pages keep arriving — and the flush is never starved.
/// Self-contained so the same file runs in the Linux shadow sandbox.
@Suite struct TimelinePrependCoalescerTests {
    @Test func afreshPrependStageOpensAShortHold() {
        var coalescer = TimelinePrependCoalescer()
        #expect(coalescer.until == 0)
        coalescer.notePrependStage(now: 10)
        #expect(coalescer.until == 10 + TimelinePrependCoalescer.step)
        #expect(coalescer.holds(at: 10 + TimelinePrependCoalescer.step - 0.01))
        #expect(!coalescer.holds(at: 10 + TimelinePrependCoalescer.step))
    }

    @Test func aFloodOfPagesMergesIntoBoundedWindows() {
        var coalescer = TimelinePrependCoalescer()
        // 27 pages arriving every 30 ms, as the local backfill loop does.
        var lastNote = 0.0
        for page in 0..<27 {
            let now = Double(page) * 0.03
            coalescer.notePrependStage(now: now)
            lastNote = now
        }
        // The hold extends with every page but never past its cap, so a
        // continuous stream cannot starve the flush.
        #expect(coalescer.until <= TimelinePrependCoalescer.maxWindow + 0.001)
        #expect(coalescer.until > lastNote)
        // The pages all land together once the (capped) hold expires.
        #expect(coalescer.flushEarliest(nextBatchAt: 0) == coalescer.until)
    }

    @Test func stagedPagesArrivingAfterExpiryStartAFreshHold() {
        var coalescer = TimelinePrependCoalescer()
        coalescer.notePrependStage(now: 0)
        let firstUntil = coalescer.until
        // A late page (after the first hold expired) starts a fresh window.
        coalescer.notePrependStage(now: firstUntil + 0.5)
        #expect(coalescer.until == firstUntil + 0.5 + TimelinePrependCoalescer.step)
    }

    @Test func flushResetsTheHoldAndTheRevealClockStaysTheLaterOfTheTwo() {
        var coalescer = TimelinePrependCoalescer()
        coalescer.notePrependStage(now: 5)
        #expect(coalescer.flushEarliest(nextBatchAt: 100) == 100, "a reveal batch still wins when it is later")
        coalescer.didFlush()
        #expect(coalescer.until == 0)
        #expect(coalescer.flushEarliest(nextBatchAt: 7) == 7)
    }

    // MARK: the hold gates its own batch (M1)

    /// A fixture-free timeline item: enough for `stage`, which keeps whatever
    /// is visible in chat.
    private func item(_ id: String) throws -> V2TimelineItem {
        let object: [String: Any] = ["id": id, "sessionId": "session",
            "type": "message", "status": "done", "content": ["text": "row \(id)"]]
        return try JSONDecoder().decode(V2TimelineItem.self, from: JSONSerialization.data(withJSONObject: object))
    }

    /// The hold exists so the backfill's page flood repaints once, not so it
    /// delays everything staged underneath it: the verdict is per batch, and a
    /// live append staged while a backfill hold is open publishes on the
    /// reveal clock alone (the projection can re-limit its oldest rows out of
    /// the window, so the batch that follows a prepend need not prepend too).
    @Test @MainActor func aLiveBatchIsNotDelayedByAnOpenPrependHold() throws {
        let presentation = SessionTimelinePresentation()
        presentation.stage([try item("a"), try item("b")], animate: false, now: 0)
        presentation.flush(now: 0)
        #expect(presentation.rows.map(\.id) == ["a", "b"])
        // A history page prepends above everything: the hold opens.
        presentation.stage([try item("h"), try item("a"), try item("b")], animate: false, now: 10)
        #expect(presentation.pendingIsPrepend)
        #expect(presentation.pendingPublishAt >= 10 + TimelinePrependCoalescer.step,
            "a prepend batch waits the hold out")
        // A live append staged while that hold is open is not gated by it.
        presentation.stage([try item("a"), try item("b"), try item("c")], animate: false, now: 10.05)
        #expect(!presentation.pendingIsPrepend)
        #expect(presentation.pendingPublishAt == presentation.nextBatchAt)
        #expect(presentation.pendingPublishAt < 10 + TimelinePrependCoalescer.step)
        // …and publishing it clears both the batch and the hold it never used.
        presentation.flush(now: 10.06)
        #expect(presentation.rows.map(\.id) == ["a", "b", "c"])
        #expect(!presentation.pendingIsPrepend)
    }
}

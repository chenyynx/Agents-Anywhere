import Foundation
import Testing
@testable import ClientCore

/// The opening-flood governance's pure half: history-page prepends land as
/// few repaints as possible without ever starving the flush. Self-contained
/// so the same file runs in the Linux shadow sandbox.
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
}

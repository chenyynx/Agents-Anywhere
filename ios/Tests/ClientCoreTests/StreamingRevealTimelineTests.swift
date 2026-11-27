import Foundation
import Testing
@testable import ClientCore

@Suite struct StreamingRevealTimelineTests {
    private func makeTimeline(total: Int) -> StreamingRevealTimeline {
        var timeline = StreamingRevealTimeline()
        timeline.retarget(total: total, at: 0)
        return timeline
    }

    @Test func normalSpeedBeforeTheBacklogThreshold() {
        let timeline = makeTimeline(total: 320)
        #expect(timeline.shownThrough(at: 0.5) == 160)
        #expect(timeline.shownThrough(at: 0.99) == 316)
        #expect(timeline.shownThrough(at: 1.0) == 320)
        #expect(timeline.shownThrough(at: 2.0) == 320)
    }

    @Test func catchesUpAtDoubleSpeedWhenTextIsBacklogged() {
        let timeline = makeTimeline(total: 2000)
        // remaining 2000 > 640, tail 1280, bulk 720, tBulk 1.125 s.
        #expect(timeline.shownThrough(at: 0.5) == 320)
        #expect(timeline.shownThrough(at: 1.0) == 640)
        #expect(timeline.shownThrough(at: 1.125) == 720)
    }

    @Test func exponentialAndLinearTailAreContinuousAtTheSwitch() {
        let timeline = makeTimeline(total: 2000)
        let tBulk = 720.0 / 640.0
        let ln = log(1280.0 / 640.0)
        let switchAt = tBulk + 2.0 * ln
        let before = timeline.shownThrough(at: switchAt - 0.0001)
        let after = timeline.shownThrough(at: switchAt + 0.0001)
        #expect(abs(before - after) <= 1)
        #expect(abs(after - 1360) <= 1)
    }

    @Test func lastWindowFinishesLinearlyInTwoSeconds() {
        let timeline = makeTimeline(total: 2000)
        let tBulk = 720.0 / 640.0
        let ln = log(1280.0 / 640.0)
        let switchAt = tBulk + 2.0 * ln
        #expect(abs(timeline.shownThrough(at: switchAt) - 1360) <= 1)
        #expect(abs(timeline.shownThrough(at: switchAt + 1.0) - 1680) <= 1)
        #expect(timeline.shownThrough(at: switchAt + 2.0) == 2000)
    }

    @Test func retargetNeverMovesTheCursorBackwards() {
        var timeline = StreamingRevealTimeline()
        timeline.retarget(total: 100, at: 0)
        #expect(timeline.shownThrough(at: 1.0) == 100)
        timeline.retarget(total: 200, at: 1.0)
        #expect(timeline.shownThrough(at: 1.0) == 100)
        #expect(timeline.shownThrough(at: 1.5) == 200)
    }

    @Test func floorWithTheOfficialEpsilon() {
        var timeline = StreamingRevealTimeline()
        timeline.retarget(total: 1, at: 0)
        #expect(timeline.shownThrough(at: 0.001) == 0)
        #expect(timeline.shownThrough(at: 0.003125) == 1)
    }

    @Test func resetDropsTheTimelineAndStartsFromZero() {
        var timeline = StreamingRevealTimeline()
        timeline.retarget(total: 10, at: 0)
        #expect(timeline.shownThrough(at: 0.1) == 10)
        timeline.reset()
        #expect(timeline.shownThrough(at: 10) == 0)
        timeline.retarget(total: 3, at: 11)
        #expect(timeline.shownThrough(at: 11) == 0)
        #expect(timeline.shownThrough(at: 12) == 3)
    }

    @Test func runLengthsStayInTheOfficialRangeAndAreDeterministic() {
        var first = StreamingRevealRunGenerator(seed: 42)
        var second = StreamingRevealRunGenerator(seed: 42)
        var firstSamples: [Int] = []
        var secondSamples: [Int] = []
        for _ in 0..<200 {
            firstSamples.append(first.nextRun())
            secondSamples.append(second.nextRun())
        }
        #expect(firstSamples == secondSamples)
        #expect(firstSamples.allSatisfy { (24...64).contains($0) })
    }

    @Test func runPolicyWaitsForPatienceOrAFullRun() {
        let policy = StreamingRevealRunPolicy()
        #expect(policy.decision(released: 0, target: 20, nextRun: 24,
                                waitingSince: nil, now: 0) == .wait)
        #expect(policy.decision(released: 0, target: 20, nextRun: 24,
                                waitingSince: 0, now: 0.34) == .wait)
        #expect(policy.decision(released: 0, target: 20, nextRun: 24,
                                waitingSince: 0, now: 0.35) == .advance)
        #expect(policy.decision(released: 0, target: 24, nextRun: 24,
                                waitingSince: nil, now: 0) == .advance)
        #expect(policy.decision(released: 10, target: 10, nextRun: 24,
                                waitingSince: 0, now: 1) == .wait)
    }

    // MARK: - Hidden-page freeze (official RevealDriver, CANONICAL/29 §18)

    @Test func revealClockStopsWhileHiddenAndResumesFromTheSameInstant() {
        var clock = StreamingRevealClock()
        #expect(clock.now(at: 10) == 10)
        clock.setVisible(false, at: 10)
        #expect(clock.now(at: 12) == 10)
        #expect(clock.now(at: 30) == 10)
        clock.setVisible(true, at: 12)
        #expect(clock.now(at: 12) == 10)
        #expect(clock.now(at: 13) == 11)
        // A second hidden span accumulates on top of the first.
        clock.setVisible(false, at: 20)
        #expect(clock.now(at: 21) == 18)
        clock.setVisible(true, at: 21)
        #expect(clock.now(at: 22) == 19)
    }

    @Test func cursorShowsEverythingOnFirstSight() {
        // Opening a page mid-stream must not replay the answer from its start.
        var cursor = StreamingRevealCursor()
        let text = String(repeating: "a", count: 500)
        #expect(cursor.reveal(text, at: 0) == text)
        #expect(cursor.revealedCount(total: 500, at: 0) == 500)
    }

    @Test func visibleGrowthRevealsAtTheOfficialCharacterRate() {
        var cursor = StreamingRevealCursor()
        #expect(cursor.revealedCount(total: 100, at: 0) == 100)
        // 320 characters arrive at t = 1; the cursor reveals them at 320/s.
        #expect(cursor.revealedCount(total: 420, at: 1) == 100)
        #expect(cursor.revealedCount(total: 420, at: 1.5) == 260)
        #expect(cursor.revealedCount(total: 420, at: 2.0) == 420)
    }

    @Test func hiddenBacklogFreezesAndReplaysFromTheOldCount() {
        var cursor = StreamingRevealCursor()
        #expect(cursor.revealedCount(total: 100, at: 0) == 100)
        cursor.setVisible(false, at: 1)
        // Text grows to 500 while hidden; sampling keeps the frozen count.
        #expect(cursor.revealedCount(total: 500, at: 1.5) == 100)
        #expect(cursor.revealedCount(total: 500, at: 3) == 100)
        cursor.setVisible(true, at: 3)
        #expect(cursor.revealedCount(total: 500, at: 3) == 100)
        // Half a second after returning: 160 more characters, not all 400.
        #expect(cursor.revealedCount(total: 500, at: 3.5) == 260)
        #expect(cursor.revealedCount(total: 500, at: 4.25) == 500)
    }

    @Test func longestLagCapSkipsStaleBacklogButKeepsTheTail() {
        var cursor = StreamingRevealCursor(longestLagSeconds: 1) // 320 characters
        #expect(cursor.revealedCount(total: 0, at: 0) == 0)
        cursor.setVisible(false, at: 0)
        #expect(cursor.revealedCount(total: 2000, at: 5) == 1680)
        cursor.setVisible(true, at: 5)
        #expect(cursor.revealedCount(total: 2000, at: 5.5) == 1840)
        #expect(cursor.revealedCount(total: 2000, at: 6) == 2000)
    }

    @Test func cursorNeverOverrunsAShorterCorrection() {
        var cursor = StreamingRevealCursor()
        #expect(cursor.revealedCount(total: 100, at: 0) == 100)
        #expect(cursor.revealedCount(total: 50, at: 0.5) == 50)
        // New text after the correction reveals from the clamped position.
        #expect(cursor.revealedCount(total: 80, at: 1) == 50)
        #expect(cursor.revealedCount(total: 80, at: 1.1) == 80)
    }

    @Test func tailStartShowsOnlyTheLongestLagWindowThenDrains() {
        var cursor = StreamingRevealCursor(longestLagSeconds: 1) // 320 chars
        cursor.setVisible(false, at: 0)
        // The message first appeared while the page was hidden: skip all but
        // the last 320 characters, then reveal those at the usual pace.
        cursor.startFromTail(total: 1000, at: 1)
        #expect(cursor.revealedCount(total: 1000, at: 1) == 680)
        cursor.setVisible(true, at: 1)
        #expect(cursor.revealedCount(total: 1000, at: 1.5) == 840)
        #expect(cursor.revealedCount(total: 1000, at: 2) == 1000)
    }

    @Test func shortMessageThatArrivedWhileHiddenStartsEmpty() {
        var cursor = StreamingRevealCursor(longestLagSeconds: 1)
        cursor.startFromTail(total: 100, at: 0)
        #expect(cursor.revealedCount(total: 100, at: 0) == 0)
        #expect(cursor.revealedCount(total: 100, at: 0.1) == 32)
        #expect(cursor.revealedCount(total: 100, at: 1) == 100)
    }

    @Test func replayPolicyOnlyReplaysMessagesThatArrivedWhileAway() {
        // The 18 old rows already in the window before a hide: seen text,
        // never a replay (pp 2026-11-27, backlog 9698 on one return).
        #expect(!StreamingRevealReplayPolicy.shouldReplay(
            isAssistantText: true, hasSampledVisible: true, isKnownRow: true,
            hasCursor: false, isResuming: true, textEmpty: false))
        // A row first seen after the hide: replay.
        #expect(StreamingRevealReplayPolicy.shouldReplay(
            isAssistantText: true, hasSampledVisible: true, isKnownRow: false,
            hasCursor: false, isResuming: true, textEmpty: false))
        // A page never sampled while visible cannot tell new from existing.
        #expect(!StreamingRevealReplayPolicy.shouldReplay(
            isAssistantText: true, hasSampledVisible: false, isKnownRow: false,
            hasCursor: false, isResuming: true, textEmpty: false))
        #expect(!StreamingRevealReplayPolicy.shouldReplay(
            isAssistantText: false, hasSampledVisible: true, isKnownRow: false,
            hasCursor: false, isResuming: true, textEmpty: false))
        #expect(!StreamingRevealReplayPolicy.shouldReplay(
            isAssistantText: true, hasSampledVisible: true, isKnownRow: false,
            hasCursor: true, isResuming: true, textEmpty: false))
        #expect(!StreamingRevealReplayPolicy.shouldReplay(
            isAssistantText: true, hasSampledVisible: true, isKnownRow: false,
            hasCursor: false, isResuming: false, textEmpty: false))
        #expect(!StreamingRevealReplayPolicy.shouldReplay(
            isAssistantText: true, hasSampledVisible: true, isKnownRow: false,
            hasCursor: false, isResuming: true, textEmpty: true))
    }

    @Test func emptyAssistantRowIsNotSeenText() {
        // A turn can have an assistant row before any text exists (or while
        // only tool calls are running). That row must not be remembered as
        // seen: the reply that fills it may arrive while the reader is on
        // another tab and has to replay on return.
        #expect(!StreamingRevealReplayPolicy.hasSeenText(
            isAssistantText: true, textEmpty: true))
        #expect(StreamingRevealReplayPolicy.hasSeenText(
            isAssistantText: true, textEmpty: false))
        #expect(!StreamingRevealReplayPolicy.hasSeenText(
            isAssistantText: false, textEmpty: false))
    }
}

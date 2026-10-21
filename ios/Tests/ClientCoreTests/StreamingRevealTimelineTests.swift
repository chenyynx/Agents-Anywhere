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
}

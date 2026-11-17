import Foundation
import Testing
@testable import ClientCore

/// The SubAgent toolbar mark's idle motion (2026-11-18): the blobatar blink
/// and saccade columns, re-expressed for the mark's 24-unit viewBox. These
/// pin the two windows that make the mark read as alive — the 2.8 % blink and
/// the six-fixation saccade — plus the bounds that keep the eyes inside the
/// badge and the pose the Reduce Motion path falls back to.
@Suite struct SubAgentMarkMotionTests {
    private let motion = SubAgentMarkMotion()

    // MARK: - Blink

    @Test func blinkStaysOpenOutsideItsClosingWindow() {
        #expect(motion.blink(at: 0) == 1)
        #expect(motion.blink(at: 0.97 * motion.blinkPeriod) == 1)
    }

    @Test func blinkReachesTheClosedPoseAtTheWindowEdge() {
        let closed = motion.blink(at: 0.986 * motion.blinkPeriod)
        #expect(abs(closed - 0.08) < 0.001)
    }

    @Test func blinkClosesThenOpensAcrossTheWindow() {
        // The two halves are sampled on their own: the closing half (0.972 →
        // 0.986) must fall and the opening half (0.986 → 1) must rise. They
        // are mirror images, so comparing across the seam would assert float
        // bits rather than behaviour.
        let closing = [0.9755, 0.979, 0.9825].map {
            motion.blink(at: $0 * motion.blinkPeriod)
        }
        let opening = [0.9895, 0.993, 0.9965].map {
            motion.blink(at: $0 * motion.blinkPeriod)
        }
        let closed = motion.blink(at: 0.986 * motion.blinkPeriod)

        #expect(closing[0] > closing[1])
        #expect(closing[1] > closing[2])
        #expect(closing[2] > closed)
        #expect(closed < 0.1)
        #expect(opening[0] > closed)
        #expect(opening[0] < opening[1])
        #expect(opening[1] < opening[2])
        #expect(opening[2] < 1)
    }

    @Test func blinkNeverLeavesItsBoundedRange() {
        var time = 0.0
        while time < motion.blinkPeriod {
            let value = motion.blink(at: time)
            #expect(value >= 0.08 - 1e-9)
            #expect(value <= 1)
            time += 7
        }
    }

    // MARK: - Saccade

    @Test func saccadeHoldsTheOpeningFixation() {
        let offset = motion.saccade(at: 0)
        #expect(offset == .zero)
        #expect(motion.saccade(at: 0.1 * motion.saccadePeriod) == .zero)
    }

    @Test func saccadeJumpsToTheFirstFixation() {
        let offset = motion.saccade(at: 0.2 * motion.saccadePeriod)
        #expect(abs(offset.x - (-0.8 * motion.glanceX)) < 1e-9)
        #expect(abs(offset.y - (-0.9 * motion.glanceY)) < 1e-9)
    }

    @Test func saccadeRestsAtTheMiddleFixation() {
        let offset = motion.saccade(at: 0.5 * motion.saccadePeriod)
        #expect(abs(offset.x - (-0.15 * motion.glanceX)) < 1e-9)
        #expect(abs(offset.y - (0.85 * motion.glanceY)) < 1e-9)
    }

    @Test func saccadeReturnsToCentreAtTheLoopsEnd() {
        #expect(motion.saccade(at: motion.saccadePeriod) == .zero)
        #expect(motion.saccade(at: 2 * motion.saccadePeriod) == .zero)
    }

    @Test func saccadeStaysInsideTheBadge() {
        var time = 0.0
        while time < motion.saccadePeriod {
            let offset = motion.saccade(at: time)
            #expect(abs(offset.x) <= motion.glanceX + 1e-9)
            #expect(abs(offset.y) <= motion.glanceY + 1e-9)
            time += 11
        }
    }

    // MARK: - Frame

    @Test func frameLoopsAfterBothClocksWrap() {
        let lcm = 16_800.0  // 4 × 4.2 s and 3 × 5.6 s
        // Tolerant on purpose: the two clocks divide the time separately, so
        // the wrapped sample can differ in the last float bits.
        for start in [0.0, 1_234.0] {
            let a = motion.frame(at: start)
            let b = motion.frame(at: lcm + start)
            #expect(abs(a.blink - b.blink) < 1e-9)
            #expect(abs(a.eyeOffset.x - b.eyeOffset.x) < 1e-9)
            #expect(abs(a.eyeOffset.y - b.eyeOffset.y) < 1e-9)
        }
    }

    @Test func stillFrameIsOpenEyesAtCentre() {
        #expect(SubAgentMarkMotion.Frame.still.blink == 1)
        #expect(SubAgentMarkMotion.Frame.still.eyeOffset == .zero)
    }

    @Test func bezierHitsItsEndpoints() {
        #expect(SubAgentMarkMotion.bezier(0.42, 0, 1, 1, 0) == 0)
        #expect(abs(SubAgentMarkMotion.bezier(0.42, 0, 1, 1, 1) - 1) < 1e-9)
    }
}

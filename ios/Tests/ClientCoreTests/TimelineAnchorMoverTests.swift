import Foundation
import Testing
@testable import ClientCore

/// Pins the Mover as a stateful spring: it follows a live target, arrives
/// inside one pixel, and a stalled frame is clamped. The official constants
/// live in `TimelineSpringFollow`; these tests only assert the integration
/// behaviour the driver depends on.

@Suite struct TimelineAnchorMoverTests {
    private let scale: CGFloat = 3

    @Test func aStoppedMoverDoesNotMove() {
        var mover = TimelineAnchorMover(position: 42)
        let step = mover.step(target: 500, dt: 1.0 / 60, displayScale: scale)
        #expect(step.position == 42)
        #expect(!step.arrived)
        #expect(!step.moved)
    }

    @Test func easeConvergesAndArrives() {
        var mover = TimelineAnchorMover(position: 0)
        mover.start(at: 0, spring: .ease)
        var frames = 0
        var arrived = false
        while frames < 300 {
            let step = mover.step(target: 100, dt: 1.0 / 60, displayScale: scale)
            frames += 1
            if step.arrived {
                arrived = true
                break
            }
        }
        #expect(arrived)
        #expect(frames < 120)
        #expect(mover.position == 100)
        #expect(!mover.isRunning)
    }

    @Test func aGrowingTargetIsFollowedWithoutARestart() {
        var mover = TimelineAnchorMover(position: 0)
        mover.start(at: 0, spring: .ease)
        for _ in 0..<10 {
            _ = mover.step(target: 100, dt: 1.0 / 60, displayScale: scale)
        }
        // The streaming row grows: same motion, new destination.
        mover.retarget(spring: .ease)
        var frames = 0
        var arrived = false
        while frames < 300 {
            let step = mover.step(target: 200, dt: 1.0 / 60, displayScale: scale)
            frames += 1
            if step.arrived {
                arrived = true
                break
            }
        }
        #expect(arrived)
        #expect(mover.position == 200)
    }

    @Test func flyCoversALongDistance() {
        var mover = TimelineAnchorMover(position: 0)
        mover.start(at: 0, spring: .fly)
        var frames = 0
        var arrived = false
        while frames < 300 {
            let step = mover.step(target: 1000, dt: 1.0 / 60, displayScale: scale)
            frames += 1
            if step.arrived {
                arrived = true
                break
            }
        }
        #expect(arrived)
        #expect(frames < 150)
        #expect(mover.position == 1000)
    }

    @Test func aStalledFrameIsClampedToAThirtieth() {
        var mover = TimelineAnchorMover(position: 0)
        mover.start(at: 0, spring: .ease)
        let stalled = mover.step(target: 100, dt: 1.0, displayScale: scale)
        #expect(stalled.position.isFinite)
        #expect(abs(stalled.position) <= 100)
        #expect(!stalled.arrived)
    }

    /// Official `Ease.Pace`: a growing stream must be tracked, not chased. A
    /// plain critically damped spring trails a target moving at `v` by
    /// `duration/π · v` (≈ 36 pt at 300 pt/s), which is what read as a soft,
    /// slow drift on device.
    @Test func aSteadilyGrowingTargetIsTrackedWithinOnePixel() {
        var mover = TimelineAnchorMover(position: 0)
        mover.start(at: 0, spring: .ease)
        let dt = 1.0 / 120
        var target: CGFloat = 0
        _ = mover.step(target: target, dt: dt, displayScale: scale)
        var worst: CGFloat = 0
        for _ in 0..<240 {
            target += 300 * CGFloat(dt)
            let step = mover.step(target: target, dt: dt, displayScale: scale)
            #expect(!step.arrived)
            worst = max(worst, abs(target - step.position))
        }
        #expect(worst < TimelineSpringFollow.pixel(displayScale: scale))
    }

    /// When the stream stops the pace leaves no accumulated gap, so the next
    /// still frame is already at the target — no tail swing after the reply.
    @Test func aStoppedTargetLandsWithoutATailSwing() {
        var mover = TimelineAnchorMover(position: 0)
        mover.start(at: 0, spring: .ease)
        let dt = 1.0 / 120
        var target: CGFloat = 0
        _ = mover.step(target: target, dt: dt, displayScale: scale)
        for _ in 0..<120 {
            target += 300 * CGFloat(dt)
            _ = mover.step(target: target, dt: dt, displayScale: scale)
        }
        var frames = 0
        var arrived = false
        while frames < 120 {
            let step = mover.step(target: target, dt: dt, displayScale: scale)
            frames += 1
            #expect(step.position <= target + 0.001)
            if step.arrived { arrived = true; break }
        }
        #expect(arrived)
        #expect(frames <= 2)
    }

    /// The initial gap of a motion is still animated; the pace must not turn
    /// an explicit return into a teleport.
    @Test func anInitialGapIsStillClosedByTheSpring() {
        var mover = TimelineAnchorMover(position: 0)
        mover.start(at: 0, spring: .ease)
        let first = mover.step(target: 100, dt: 1.0 / 60, displayScale: scale)
        #expect(first.position < 100)
        #expect(!first.arrived)
    }

    /// A UIKit write already moved the page; the same distance must not be
    /// applied a second time by the pace shift.
    @Test func anExternalWriteIsNotShiftedTwice() {
        var mover = TimelineAnchorMover(position: 0)
        mover.start(at: 0, spring: .ease)
        _ = mover.step(target: 0, dt: 1.0 / 120, displayScale: scale)
        mover.reseed(at: 120)
        let step = mover.step(target: 120, dt: 1.0 / 120, displayScale: scale)
        #expect(abs(step.position - 120) < 0.001)
    }

    /// A fly is a deliberate long jump and never carries the target's motion.
    @Test func aFlyIsNotRedirectedByThePaceShift() {
        var mover = TimelineAnchorMover(position: 0)
        mover.start(at: 0, spring: .fly)
        _ = mover.step(target: 1000, dt: 1.0 / 120, displayScale: scale)
        _ = mover.step(target: 1300, dt: 1.0 / 120, displayScale: scale)
        #expect(mover.position < 100)
    }
}

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
        let mover = TimelineAnchorMover(position: 42)
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
}

import Testing
@testable import ClientCore

@Suite struct TimelineSpringFollowTests {
    @Test func springStartsAtRest() {
        for spring in [TimelineSpringFollow.Spring.ease, .fly] {
            #expect(abs(spring.progress(at: 0)) < 1e-9)
            #expect(abs(spring.velocity(at: 0)) < 1e-9)
        }
    }

    @Test func criticallyDampedSpringApproachesTheTarget() {
        let spring = TimelineSpringFollow.Spring.ease
        #expect(abs(spring.progress(at: 2.0) - 1) < 1e-3)
        // ζ = 1 has no overshoot.
        var previous = -1.0
        for step in 0...120 {
            let value = spring.progress(at: Double(step) / 60)
            #expect(value + 1e-9 >= previous)
            #expect(value <= 1 + 1e-9)
            previous = value
        }
    }

    @Test func flySpringOvershootsThenSettles() {
        let spring = TimelineSpringFollow.Spring.fly
        var peak = 0.0
        var settled = false
        for step in 0...180 {
            let value = spring.progress(at: Double(step) / 60)
            peak = max(peak, value)
            if step > 0, abs(value - 1) < 1e-3, abs(spring.velocity(at: Double(step) / 60)) < 1e-2 {
                settled = true
            }
        }
        #expect(peak > 1.0)
        #expect(settled)
    }

    @Test func whiteNoiseDistanceIsOnePhysicalPixel() {
        #expect(abs(TimelineSpringFollow.pixel(displayScale: 3) - 1.0 / 3) < 1e-9)
        #expect(abs(TimelineSpringFollow.pixel(displayScale: 2) - 0.5) < 1e-9)
        #expect(!TimelineSpringFollow.shouldMove(target: 10, current: 10.3, displayScale: 3))
        #expect(TimelineSpringFollow.shouldMove(target: 10, current: 10.4, displayScale: 3))
    }

    @Test func catchUpAndPreplaceUseOneViewport() {
        #expect(TimelineSpringFollow.catchUpDistance(visibleHeight: 700) == 1400)
        // A jump beyond one screen is pre-placed one screen short.
        #expect(TimelineSpringFollow.preplacedOffset(
            target: 3000, current: 0, visibleHeight: 700) == 2300)
        // A short jump takes off from where the reader is.
        #expect(TimelineSpringFollow.preplacedOffset(
            target: 500, current: 0, visibleHeight: 700) == 0)
        #expect(TimelineSpringFollow.spring(
            target: 3000, current: 0, visibleHeight: 700) == .fly)
        #expect(TimelineSpringFollow.spring(
            target: 500, current: 0, visibleHeight: 700) == .ease)
    }

    @Test func endOffsetClampsAtTheTop() {
        #expect(TimelineSpringFollow.endOffset(
            contentHeight: 2000, containerHeight: 800,
            topInset: 50, bottomInset: 34, anchorPad: 0) == 1234)
        #expect(TimelineSpringFollow.endOffset(
            contentHeight: 100, containerHeight: 800,
            topInset: 50, bottomInset: 34, anchorPad: 0) == -50)
        // Sending pads the end by one visible viewport.
        #expect(TimelineSpringFollow.endOffset(
            contentHeight: 2000, containerHeight: 800,
            topInset: 50, bottomInset: 34, anchorPad: 716) == 1950)
    }

    @Test func rearmNeedsOnePixelAndNoAnchorPad() {
        let end: CGFloat = 1000
        #expect(TimelineSpringFollow.shouldRearmEnd(
            endTarget: end, offset: 999.8, anchorPad: 0,
            topInset: 0, displayScale: 3))
        #expect(!TimelineSpringFollow.shouldRearmEnd(
            endTarget: end, offset: 999.5, anchorPad: 0,
            topInset: 0, displayScale: 3))
        #expect(!TimelineSpringFollow.shouldRearmEnd(
            endTarget: end, offset: 999.9, anchorPad: 700,
            topInset: 0, displayScale: 3))
    }

    @Test func arrivalChecksPositionAndVelocity() {
        #expect(TimelineSpringFollow.hasArrived(
            target: 100, position: 99.9, velocity: 0, dt: 1.0 / 60,
            displayScale: 3))
        #expect(!TimelineSpringFollow.hasArrived(
            target: 100, position: 99, velocity: 0, dt: 1.0 / 60,
            displayScale: 3))
        #expect(!TimelineSpringFollow.hasArrived(
            target: 100, position: 99.9, velocity: 100, dt: 1.0 / 60,
            displayScale: 3))
    }
}

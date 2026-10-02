import Foundation
import Testing
@testable import ClientCore

/// Pins the composer gesture's own release-velocity estimate (round 1.1): a
/// difference quotient over the last in-flight span, refused when the span is
/// not a usable duration. Expectations are literals so a sign or bound change
/// turns these red.

@Suite struct ComposerGestureKinematicsTests {
    private func sample(_ time: TimeInterval, _ translationY: CGFloat) -> ComposerGestureKinematics.Sample {
        ComposerGestureKinematics.Sample(time: time, translationY: translationY)
    }

    @Test func velocityIsTheDifferenceQuotientOverTheLastSpan() {
        // -30pt over 0.25s is -120pt/s upward (time values chosen exact in
        // binary so the literal pins the arithmetic, not rounding).
        #expect(ComposerGestureKinematics.velocityY(previous: sample(1.00, 0), current: sample(1.25, -30)) == -120)
        // Sign follows the travel: downward is positive.
        #expect(ComposerGestureKinematics.velocityY(previous: sample(1.00, 10), current: sample(1.25, 40)) == 120)
        // The spec's fast flick: -30pt in 0.02s is about -1500pt/s.
        let fast = ComposerGestureKinematics.velocityY(previous: sample(1.00, 0), current: sample(1.02, -30))
        #expect(abs((fast ?? 0) - (-1500)) < 0.01)
    }

    @Test func aNonPositiveSpanHasNoVelocity() {
        // A release in the same tick as the last sample has no span to divide.
        #expect(ComposerGestureKinematics.velocityY(previous: sample(1.00, 0), current: sample(1.00, 30)) == nil)
        // Out-of-order timestamps are not a usable pair either.
        #expect(ComposerGestureKinematics.velocityY(previous: sample(1.02, 0), current: sample(1.00, 30)) == nil)
    }

    @Test func aStaleSpanHasNoVelocity() {
        // The last in-flight sample predates the release by more than the
        // estimate window: the finger rested, so its motion is not a flick.
        #expect(ComposerGestureKinematics.velocityY(previous: sample(1.00, 0), current: sample(1.2501, 30)) == nil)
        // 0.25s exactly is still a usable span (the boundary is pinned).
        #expect(ComposerGestureKinematics.velocityY(previous: sample(1.00, 0), current: sample(1.25, 30)) == 120)
    }
}

import Foundation
import Testing
@testable import ClientCore

/// Pins the phone drawer's release rules against the official 60 pt/s
/// threshold, the half-way fallback, and the ±10π normalized-velocity clamp.
/// Expectations are literals so a sign, boundary, or clamp change turns these
/// red.

@Suite struct SidebarDrawerGestureRulesTests {
    @Test func slowReleaseUsesTheRestingPosition() {
        #expect(SidebarDrawerGestureRules.targetProgress(progress: 0.49, velocityX: 0) == 0)
        #expect(SidebarDrawerGestureRules.targetProgress(progress: 0.51, velocityX: 0) == 1)
        // Half-way exactly counts as open (>= 0.5).
        #expect(SidebarDrawerGestureRules.targetProgress(progress: 0.50, velocityX: 0) == 1)
    }

    @Test func flickDirectionWinsAboveTheThreshold() {
        // A small rightward flick opens even though the resting position says
        // close, and a large leftward flick closes a mostly-open drawer.
        #expect(SidebarDrawerGestureRules.targetProgress(progress: 0.1, velocityX: 61) == 1)
        #expect(SidebarDrawerGestureRules.targetProgress(progress: 0.9, velocityX: -61) == 0)
        #expect(SidebarDrawerGestureRules.targetProgress(progress: 0.9, velocityX: 61) == 1)
    }

    @Test func theThresholdIsStrictlyGreaterThanSixty() {
        // 60 pt/s is still the position branch: sign is ignored there.
        #expect(SidebarDrawerGestureRules.targetProgress(progress: 0.49, velocityX: 60) == 0)
        #expect(SidebarDrawerGestureRules.targetProgress(progress: 0.51, velocityX: -60) == 1)
    }

    @Test func normalizedVelocityIsPortionOfRemainingDistancePerSecond() {
        // 300 pt/s with 300 pt left is exactly 1.0 of the remaining distance.
        #expect(SidebarDrawerGestureRules.normalizedVelocity(
            velocityX: 300, progress: 0, targetProgress: 1, revealWidth: 300
        ) == 1)
        // Closing from 80%: 240 pt left, -480 pt/s moves toward the target,
        // so the normalized value is +2.0.
        #expect(SidebarDrawerGestureRules.normalizedVelocity(
            velocityX: -480, progress: 0.8, targetProgress: 0, revealWidth: 300
        ) == 2)
    }

    @Test func normalizedVelocityClampsToTenPi() {
        #expect(SidebarDrawerGestureRules.normalizedVelocity(
            velocityX: 12_000, progress: 0, targetProgress: 1, revealWidth: 300
        ) == 10 * Double.pi)
        // Moving away from the close target while the remaining offset is
        // negative flips the sign into the downward clamp.
        #expect(SidebarDrawerGestureRules.normalizedVelocity(
            velocityX: 12_000, progress: 1, targetProgress: 0, revealWidth: 300
        ) == -10 * Double.pi)
    }

    @Test func normalizedVelocityIsZeroWhenTheTargetIsAlreadyReached() {
        // Half a point left is below the one-point guard.
        #expect(SidebarDrawerGestureRules.normalizedVelocity(
            velocityX: 300, progress: 1 - 0.5 / 300, targetProgress: 1, revealWidth: 300
        ) == 0)
        // Two points left accepts the velocity: 2 pt/s over 2 pt is 1.0.
        let velocity = SidebarDrawerGestureRules.normalizedVelocity(
            velocityX: 2, progress: 1 - 2.0 / 300, targetProgress: 1, revealWidth: 300
        )
        #expect(abs(velocity - 1) < 1e-9)
    }

    @Test func snapTargetUsesTheHalfWayBoundary() {
        #expect(SidebarDrawerGestureRules.snapTarget(progress: 0.49) == 0)
        #expect(SidebarDrawerGestureRules.snapTarget(progress: 0.50) == 1)
    }

    @Test func shouldBeginPrefersAccumulatedTranslationOverTheStartVelocity() {
        // The velocity points left, but the finger has already accumulated
        // 20 pt of rightward travel: the translation wins.
        #expect(SidebarDrawerGestureRules.shouldBegin(
            progress: 0,
            translationX: 20, translationY: 5,
            velocityX: -200, velocityY: -30
        ))
        // A leftward start cannot open a closed drawer.
        #expect(!SidebarDrawerGestureRules.shouldBegin(
            progress: 0,
            translationX: -20, translationY: 5,
            velocityX: 200, velocityY: 30
        ))
        // Vertical travel is rejected before the scroll view is disturbed.
        #expect(!SidebarDrawerGestureRules.shouldBegin(
            progress: 0,
            translationX: 5, translationY: 20,
            velocityX: 200, velocityY: 300
        ))
        // Open: only a leftward drag may close.
        #expect(!SidebarDrawerGestureRules.shouldBegin(
            progress: 1,
            translationX: 20, translationY: 5,
            velocityX: 200, velocityY: 30
        ))
        #expect(SidebarDrawerGestureRules.shouldBegin(
            progress: 1,
            translationX: -20, translationY: 5,
            velocityX: -200, velocityY: -30
        ))
        // Mid-drag both directions are allowed.
        #expect(SidebarDrawerGestureRules.shouldBegin(
            progress: 0.5,
            translationX: 20, translationY: 5,
            velocityX: 200, velocityY: 30
        ))
    }

    @Test func shouldBeginFallsBackToVelocityBelowTenPoints() {
        #expect(SidebarDrawerGestureRules.shouldBegin(
            progress: 0,
            translationX: 2, translationY: 1,
            velocityX: 100, velocityY: 10
        ))
        #expect(!SidebarDrawerGestureRules.shouldBegin(
            progress: 0,
            translationX: 2, translationY: 1,
            velocityX: 10, velocityY: 100
        ))
    }

    @Test func shouldBeginRejectsAnExactDirectionTie() {
        #expect(!SidebarDrawerGestureRules.shouldBegin(
            progress: 0.5,
            translationX: 20, translationY: 20,
            velocityX: 0, velocityY: 0
        ))
    }

    @Test func estimatedVelocityUsesOnlyUsableSpans() {
        // 30 pt over 0.25 s is 120 pt/s; the upper bound is inclusive.
        #expect(SidebarDrawerGestureRules.estimatedVelocityX(
            previousTranslationX: 0, previousTime: 1.00,
            currentTranslationX: 30, currentTime: 1.25
        ) == 120)
        #expect(SidebarDrawerGestureRules.estimatedVelocityX(
            previousTranslationX: 0, previousTime: 1.00,
            currentTranslationX: -30, currentTime: 1.25
        ) == -120)
        // No span, a backwards span, or a stale span cannot estimate a flick.
        #expect(SidebarDrawerGestureRules.estimatedVelocityX(
            previousTranslationX: 0, previousTime: 1.00,
            currentTranslationX: 30, currentTime: 1.00
        ) == nil)
        #expect(SidebarDrawerGestureRules.estimatedVelocityX(
            previousTranslationX: 0, previousTime: 1.02,
            currentTranslationX: 30, currentTime: 1.00
        ) == nil)
        #expect(SidebarDrawerGestureRules.estimatedVelocityX(
            previousTranslationX: 0, previousTime: 1.00,
            currentTranslationX: 30, currentTime: 1.2501
        ) == nil)
    }
}

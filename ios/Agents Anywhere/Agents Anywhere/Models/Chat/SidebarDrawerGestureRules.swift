import Foundation

/// Begin/release rules for the phone drawer. Kept pure so the gesture wiring
/// and the tests share one definition of "may this drag start?" and "where
/// does it land?".
enum SidebarDrawerGestureRules {
    /// Below this speed the resting position decides; above it the flick
    /// direction decides. Matches the official drawer's 60 pt/s threshold.
    static let commitVelocity: CGFloat = 60

    /// The spring receives a velocity normalized by the remaining distance.
    /// Cap it at 10π (the official clamp) so a very fast flick cannot push the
    /// solver past its stable range.
    static let normalizedVelocityLimit = 10 * Double.pi

    /// The resting position decides where a slow release lands.
    static func snapTarget(progress: CGFloat) -> CGFloat {
        progress >= 0.5 ? 1 : 0
    }

    /// - Parameters:
    ///   - progress: current drawer progress in `0 ... 1`.
    ///   - velocityX: horizontal release velocity in points per second.
    static func targetProgress(progress: CGFloat, velocityX: CGFloat) -> CGFloat {
        if abs(velocityX) > commitVelocity {
            return velocityX > 0 ? 1 : 0
        }
        return snapTarget(progress: progress)
    }

    /// Whether a pan may begin at this touch. The accumulated translation is
    /// steadier than the single start-velocity sample (a thumb arc can point
    /// the wrong way); the velocity is only the fallback while the pan has
    /// barely travelled.
    static func shouldBegin(
        progress: CGFloat,
        translationX: CGFloat,
        translationY: CGFloat,
        velocityX: CGFloat,
        velocityY: CGFloat
    ) -> Bool {
        let useTranslation = abs(translationX) + abs(translationY) >= 10
        let dx = useTranslation ? translationX : velocityX
        let dy = useTranslation ? translationY : velocityY

        guard abs(dx) > abs(dy) else { return false }
        if progress <= 0.001 { return dx > 0 }
        if progress >= 0.999 { return dx < 0 }
        return true
    }

    /// Difference quotient for the release velocity when SwiftUI's coordinate
    /// converter does not provide one (fast flicks often outrun it). Spans
    /// outside `(0, 0.25]` seconds are not a usable flick sample.
    static func estimatedVelocityX(
        previousTranslationX: CGFloat,
        previousTime: TimeInterval,
        currentTranslationX: CGFloat,
        currentTime: TimeInterval
    ) -> CGFloat? {
        let span = currentTime - previousTime
        guard span > 0, span <= 0.25 else { return nil }
        return (currentTranslationX - previousTranslationX) / CGFloat(span)
    }

    /// Converts a release velocity in points per second into the
    /// "fraction of the remaining distance per second" value SwiftUI's
    /// interpolating spring expects.
    static func normalizedVelocity(
        velocityX: CGFloat,
        progress: CGFloat,
        targetProgress: CGFloat,
        revealWidth: CGFloat
    ) -> Double {
        let remainingOffset = Double((targetProgress - progress) * revealWidth)
        guard abs(remainingOffset) > 1 else { return 0 }
        return min(
            max(Double(velocityX) / remainingOffset, -normalizedVelocityLimit),
            normalizedVelocityLimit
        )
    }
}

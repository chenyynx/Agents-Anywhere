import Foundation

/// Release rules for the phone drawer. Kept pure so the gesture wiring and the
/// tests share one definition of "did the drag commit?".
enum SidebarDrawerGestureRules {
    /// Below this speed the resting position decides; above it the flick
    /// direction decides. Matches the official drawer's 60 pt/s threshold.
    static let commitVelocity: CGFloat = 60

    /// The spring receives a velocity normalized by the remaining distance.
    /// Cap it at 10π (the official clamp) so a very fast flick cannot push the
    /// solver past its stable range.
    static let normalizedVelocityLimit = 10 * Double.pi

    /// - Parameters:
    ///   - progress: current drawer progress in `0 ... 1`.
    ///   - velocityX: horizontal release velocity in points per second.
    static func targetProgress(progress: CGFloat, velocityX: CGFloat) -> CGFloat {
        if abs(velocityX) > commitVelocity {
            return velocityX > 0 ? 1 : 0
        }
        return progress >= 0.5 ? 1 : 0
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

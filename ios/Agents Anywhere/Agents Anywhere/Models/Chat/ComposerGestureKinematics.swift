import Foundation

/// Own velocity estimation for the composer keyboard gesture: the
/// coordinate converter's release velocity can be missing, and a fast flick
/// travels less than the displacement threshold, so the release decision
/// needs a velocity it can always trust. Pure so ClientCore tests pin it.
nonisolated enum ComposerGestureKinematics {
    struct Sample: Equatable {
        let time: TimeInterval
        let translationY: CGFloat
    }

    /// Difference quotient over the last in-flight span; `nil` when there is
    /// no usable pair (non-positive or stale span).
    static func velocityY(previous: Sample, current: Sample) -> CGFloat? {
        let dt = current.time - previous.time
        guard dt > 0, dt <= 0.25 else { return nil }
        return (current.translationY - previous.translationY) / CGFloat(dt)
    }
}

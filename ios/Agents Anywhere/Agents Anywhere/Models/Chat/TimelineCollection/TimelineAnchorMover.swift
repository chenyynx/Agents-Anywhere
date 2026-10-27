import CoreGraphics

/// The official Mover (`CANONICAL/05-layout-scroll.md` §7.1): a stateful
/// spring stepped once per display frame against a target that is re-read
/// every frame.
///
/// This is deliberately not `TimelineSpringFollow`: that helper computes an
/// analytic progress from a fixed takeoff and target, which is right for a
/// reveal that only grows but wrong for a moving target (a frame that re-seeds
/// the analytic phase restarts the motion). The Mover integrates velocity
/// instead, so a target that grows during a stream is followed without a
/// restart.
///
/// Official constants come from `TimelineSpringFollow.Spring`
/// (`ease = 0.4 s / bounce 0`, `fly = 0.36 s / bounce 0.15`); the movement
/// dead band is one physical pixel.
nonisolated struct TimelineAnchorMover: Equatable {
    struct Step: Equatable {
        var position: CGFloat
        var arrived: Bool
        var moved: Bool
    }

    private(set) var position: CGFloat
    private(set) var velocity: CGFloat = 0
    private(set) var spring: TimelineSpringFollow.Spring = .ease
    private(set) var isRunning = false

    init(position: CGFloat) {
        self.position = position
    }

    /// Takes over at `position` (the live offset) and starts stepping.
    mutating func start(at position: CGFloat, spring: TimelineSpringFollow.Spring) {
        self.position = position
        self.spring = spring
        velocity = 0
        isRunning = true
    }

    /// A new target arrived without wanting a new motion (the spring, the
    /// takeoff and the phase stay; only the destination moved).
    mutating func retarget(spring newSpring: TimelineSpringFollow.Spring) {
        spring = newSpring
    }

    mutating func stop() {
        isRunning = false
        velocity = 0
    }

    /// An external writer (a UIKit layout correction) moved the scroll view.
    /// Continue the same spring from the live position instead of writing the
    /// stale integrated one back.
    mutating func reseed(at position: CGFloat) {
        guard isRunning else { return }
        self.position = position
        velocity = 0
    }

    /// One display frame. `dt` is clamped to a 30 fps step so a stalled link
    /// cannot overshoot; the target is whatever the placement resolves to at
    /// this instant.
    mutating func step(target: CGFloat, dt: Double, displayScale: CGFloat) -> Step {
        guard isRunning else {
            return Step(position: position, arrived: false, moved: false)
        }
        let step = min(max(dt, 0), 1.0 / 30.0)
        guard step > 0 else {
            return Step(position: position, arrived: false, moved: false)
        }
        let omega = spring.omega
        let zeta = spring.zeta
        let acceleration = omega * omega * Double(target - position)
            - 2 * zeta * omega * Double(velocity)
        velocity += CGFloat(acceleration * step)
        position += CGFloat(Double(velocity) * step)

        let pixel = 1 / max(1, displayScale)
        if abs(target - position) < pixel,
           abs(velocity * CGFloat(step)) < pixel {
            position = target
            velocity = 0
            isRunning = false
            return Step(position: position, arrived: true, moved: true)
        }
        return Step(position: position, arrived: false, moved: true)
    }
}

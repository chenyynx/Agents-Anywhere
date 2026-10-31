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
    /// The target the current motion last saw. The official Mover re-reads the
    /// target every frame and tracks its movement through `Ease.Pace`
    /// (`CANONICAL/05-layout-scroll.md` §7.1, part-ag §1.5; the type, fields
    /// and constants are EVIDENCE, the wiring is INFERENCE). AA takes the
    /// flat reading — shift the motion by the target's own delta — instead of
    /// the official `pace.interval/step` + exponential smoothing. Either way
    /// a plain critically damped spring would trail a target moving at `v` by
    /// `2ζ/ω·v = duration/π·v`, which is the drift this removes.
    private(set) var paceTarget: CGFloat?
    /// Whether a moving target is carried 1:1. Explicit motions keep it; a
    /// content-driven follow turns it off — pp 2026-10-28 found the 1:1
    /// shifts made streamed text step chunk-by-chunk, while the plain 0.4 s
    /// spring of build 614 read smoother.
    private(set) var usesPace = true

    init(position: CGFloat) {
        self.position = position
    }

    /// Takes over at `position` (the live offset) and starts stepping.
    mutating func start(at position: CGFloat, spring: TimelineSpringFollow.Spring,
                        usesPace: Bool = true) {
        self.position = position
        self.spring = spring
        self.usesPace = usesPace
        velocity = 0
        // A fresh motion closes its initial gap with the spring; the first
        // tick establishes the pace baseline. Shifting by that first target
        // would teleport the page instead of animating it.
        paceTarget = nil
        isRunning = true
    }

    /// A new target arrived without wanting a new motion (the spring, the
    /// takeoff and the phase stay; only the destination moved).
    mutating func retarget(spring newSpring: TimelineSpringFollow.Spring,
                           usesPace: Bool? = nil) {
        spring = newSpring
        if let usesPace { self.usesPace = usesPace }
    }

    mutating func stop() {
        isRunning = false
        velocity = 0
        paceTarget = nil
    }

    /// An external writer (a UIKit layout correction) moved the scroll view.
    /// Continue the same spring from the live position instead of writing the
    /// stale integrated one back.
    mutating func reseed(at position: CGFloat) {
        guard isRunning else { return }
        self.position = position
        velocity = 0
        // The external write already accounts for whatever the target did;
        // keeping the old baseline would shift that distance a second time.
        paceTarget = nil
    }

    /// One display frame. `dt` is clamped to a 30 fps step so a stalled link
    /// cannot overshoot; the target is whatever the placement resolves to at
    /// this instant.
    ///
    /// The spring is integrated in substeps of at most `min(1/120, 0.25/ω)`.
    /// A single semi-implicit Euler step is only stable while `ω·h` is small:
    /// at the 1/30 clamp the 0.2 s content spring (`ω ≈ 31.4`) has
    /// `ω·h ≈ 1.05`, whose discrete eigenvalues are 0.63 and −1.82 — the
    /// critically damped continuous response becomes a growing every-other-
    /// frame oscillation (device report 2026-10-31 07:10: the offset swung
    /// ±56 pt around a stable bottom whenever a streaming layout pass dropped
    /// frames). Substepping converges to the same continuous response, so the
    /// chosen 0.2 s feel is unchanged; only the unstable integration is gone.
    mutating func step(target: CGFloat, dt: Double, displayScale: CGFloat) -> Step {
        guard isRunning else {
            return Step(position: position, arrived: false, moved: false)
        }
        let frame = min(max(dt, 0), 1.0 / 30.0)
        guard frame > 0 else {
            return Step(position: position, arrived: false, moved: false)
        }
        let pixel = 1 / max(1, displayScale)
        // Official Pace: an ease carries the target's own movement; only the
        // gap this motion started with is left for the spring. Without it a
        // growing stream leaves a permanent `duration/π · v` trail and the
        // final catch-up reads as a tail swing. A fly (bounce > 0) is a
        // deliberate long jump and never shifts.
        let targetMoved = paceTarget.map { abs(target - $0) >= pixel } ?? false
        if usesPace, spring.bounce == 0, let previous = paceTarget, targetMoved {
            position += target - previous
        }
        paceTarget = target
        let omega = spring.omega
        let zeta = spring.zeta
        let substepLimit = omega > 0
            ? min(1.0 / 120.0, 0.25 / omega)
            : 1.0 / 120.0
        var remaining = frame
        while remaining > 0 {
            let h = min(substepLimit, remaining)
            let acceleration = omega * omega * Double(target - position)
                - 2 * zeta * omega * Double(velocity)
            velocity += CGFloat(acceleration * h)
            position += CGFloat(Double(velocity) * h)
            remaining -= h
        }

        // A target that moved this frame is a live stream: the motion must
        // stay running (the official catch-up) even though the Pace shift
        // leaves a zero gap. Arrival is only judged against a still target.
        if !targetMoved, abs(target - position) < pixel,
           abs(velocity * CGFloat(frame)) < pixel {
            position = target
            velocity = 0
            isRunning = false
            return Step(position: position, arrived: true, moved: true)
        }
        return Step(position: position, arrived: false, moved: true)
    }
}

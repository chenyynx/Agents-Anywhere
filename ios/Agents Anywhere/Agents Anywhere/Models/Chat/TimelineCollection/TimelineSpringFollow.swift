import Foundation

/// The official transcript's programmatic scroll sprung motion, reduced to the
/// parts AA's streaming follow needs. Pure so the curve, thresholds and
/// pre-place rule can be unit tested without a scroll view.
///
/// Official values: `ease = Spring(duration 0.4, bounce 0)`,
/// `fly = Spring(duration 0.36, bounce 0.15)`, `ω = 2π/duration`,
/// `ζ = 1 − bounce`, and every distance threshold is one physical pixel
/// (`1 / displayScale`).
nonisolated enum TimelineSpringFollow {
    struct Spring: Equatable {
        var duration: Double
        var bounce: Double

        static let ease = Spring(duration: 0.4, bounce: 0)
        static let fly = Spring(duration: 0.36, bounce: 0.15)

        var omega: Double { 2 * Double.pi / duration }
        var zeta: Double { 1 - bounce }

        /// Unit step response: 0 at t=0, approaching 1 as t grows.
        func progress(at elapsed: Double) -> Double {
            guard duration > 0 else { return 1 }
            let t = max(0, elapsed)
            let w = omega
            let z = zeta
            if z < 1 {
                let wd = w * (1 - z * z).squareRoot()
                guard wd > 0 else { return 1 }
                let decay = exp(-z * w * t)
                return 1 - decay * (cos(wd * t) + (z * w / wd) * sin(wd * t))
            }
            // Critically damped (bounce 0 is exactly ζ = 1).
            let decay = exp(-w * t)
            return 1 - decay * (1 + w * t)
        }

        /// d(progress)/dt, in 1/s.
        func velocity(at elapsed: Double) -> Double {
            guard duration > 0 else { return 0 }
            let t = max(0, elapsed)
            let w = omega
            let z = zeta
            if z < 1 {
                let wd = w * (1 - z * z).squareRoot()
                guard wd > 0 else { return 0 }
                return exp(-z * w * t) * (w * w / wd) * sin(wd * t)
            }
            return w * w * t * exp(-w * t)
        }
    }

    static func pixel(displayScale: CGFloat) -> CGFloat {
        1 / max(1, displayScale)
    }

    /// The official movement dead band: less than one physical pixel is a
    /// no-op.
    static func shouldMove(target: CGFloat, current: CGFloat,
                           displayScale: CGFloat) -> Bool {
        guard target.isFinite, current.isFinite else { return false }
        return abs(target - current) >= pixel(displayScale: displayScale)
    }

    /// Catch-up distance: two usable viewports.
    static func catchUpDistance(visibleHeight: CGFloat) -> CGFloat {
        2 * max(0, visibleHeight)
    }

    /// A jump longer than one visible viewport is pre-placed one viewport
    /// short of the target before flying; shorter jumps take off from the
    /// current offset.
    static func preplacedOffset(target: CGFloat, current: CGFloat,
                                visibleHeight: CGFloat) -> CGFloat {
        guard visibleHeight > 0, abs(target - current) > visibleHeight else {
            return current
        }
        return target > current ? target - visibleHeight : target + visibleHeight
    }

    static func spring(target: CGFloat, current: CGFloat,
                       visibleHeight: CGFloat) -> Spring {
        abs(target - current) > visibleHeight ? .fly : .ease
    }

    /// `placement == .end` target: content bottom plus the optional anchor pad,
    /// clamped so the viewport never scrolls above the first row.
    static func endOffset(contentHeight: CGFloat,
                          containerHeight: CGFloat,
                          topInset: CGFloat,
                          bottomInset: CGFloat,
                          anchorPad: CGFloat) -> CGFloat {
        let target = contentHeight + anchorPad + bottomInset - containerHeight
        return max(target, -topInset)
    }

    /// Dragging back to the bottom re-arms `.end` only when the offset is
    /// within one physical pixel of the end target and no anchor pad is owed.
    static func shouldRearmEnd(endTarget: CGFloat, offset: CGFloat,
                               anchorPad: CGFloat, topInset: CGFloat,
                               displayScale: CGFloat) -> Bool {
        guard anchorPad == 0, endTarget > -topInset else { return false }
        return endTarget - offset < pixel(displayScale: displayScale)
    }

    /// Arrival needs both the position error and this frame's displacement
    /// under one physical pixel.
    static func hasArrived(target: CGFloat, position: CGFloat,
                           velocity: CGFloat, dt: Double,
                           displayScale: CGFloat) -> Bool {
        let px = pixel(displayScale: displayScale)
        return abs(target - position) < px
            && abs(velocity * CGFloat(max(0, dt))) < px
    }
}

import UIKit

/// The working mark's body poses, mirroring the official `WorkingMarkBody`
/// tag table (`CANONICAL/20-working-mark.md` §3).
///
/// Only the `think` flipbook is rebuilt here. `WorkingMarkRenderer` falls back
/// to it for every other pose until that pose's frames are drawn as well
/// (`docs/perf-6b-c5-code-profile-task.md` §6).
nonisolated enum WorkingMarkBody: String, CaseIterable, Sendable {
    case think
    case generic
    case search
    case read
    case code
    case write
    case blocked
}

/// The three segments every official body sprite carries
/// (`CANONICAL/20-working-mark.md` §1).
nonisolated enum WorkingMarkPhase: String, Sendable {
    case opening
    case looping
    case closing
}

/// One dot in the 20 x 20 design canvas.
nonisolated struct WorkingMarkDot: Equatable, Sendable {
    /// Centre after this frame's vertical lift, in canvas points.
    var center: CGPoint
    /// Radius at `scale == 1`.
    var radius: CGFloat
    /// Uniform dot scale for this frame.
    var scale: CGFloat
    /// Fill alpha for this frame.
    var opacity: Double
}

/// One flipbook frame: the state of all three dots at a single 1/30 s step.
nonisolated struct WorkingMarkFrame: Equatable, Sendable {
    var phase: WorkingMarkPhase
    /// Index inside `phase`, `0 ..< frameCount - 1`.
    var index: Int
    var dots: [WorkingMarkDot]
}

/// Rebuilds the official 20 x 20 working mark with Core Graphics.
///
/// The official sprite sheets cannot be redistributed, so the flipbook is
/// generated instead of shipped: three dots whose opacity, scale and a small
/// vertical lift are a pure function of the frame index. Timing follows the
/// official model (`CANONICAL/20-working-mark.md` §1):
///
/// - think: opening 16 frames, looping 110 frames, closing 15 frames at 30 fps
///   — 0.53 s / 3.67 s / 0.50 s.
/// - `isStill` (Reduce Motion) is a single frame, as in the official app.
///
/// The geometry is [I], never [E]: the sprite art is not available, so every
/// value below is inferred from the 2026-10-22 screenshot at
/// `/home/ubuntu/.agents-anywhere-moonveil/attachments/sess_W6JkIc1Jh6PwbQ/file_Daj1ZqByuk14ZB0x-Photo-9F31958B.jpeg`
/// (three warm-brown dots forming a left-to-right rising wave).
nonisolated enum WorkingMarkRenderer {

    // MARK: - Canvas

    /// [E] `CANONICAL/20-working-mark.md` §5 — the host's fixed square.
    static var canvasSize: CGFloat { CodePageTheme.workingMarkSize }

    // MARK: - Inferred dot geometry ([I], not [E])

    // Source for every [I] value in this section: the 2026-10-22 screenshot
    // `file_Daj1ZqByuk14ZB0x-Photo-9F31958B.jpeg` under
    // `/home/ubuntu/.agents-anywhere-moonveil/attachments/sess_W6JkIc1Jh6PwbQ/`.
    // None of these come from the binary; they are redrawn approximations.

    /// [I] `file_Daj1ZqByuk14ZB0x-Photo-9F31958B.jpeg` — the dots sit on the
    /// canvas's optical centre line (canvas centre 10).
    private static let dotCenterY: CGFloat = 10

    /// [I] `file_Daj1ZqByuk14ZB0x-Photo-9F31958B.jpeg` — the three centres
    /// span about 15 pt of the 20 pt box; 6 pt spacing is their measured
    /// average.
    private static let dotCenterXs: [CGFloat] = [4, 10, 16]

    /// [I] `file_Daj1ZqByuk14ZB0x-Photo-9F31958B.jpeg` — captured dots are
    /// 10–11 px wide at 3x (3.3–3.7 pt); a 2 pt radius at the rest scale is
    /// about 3.5 pt across.
    private static let dotRadius: CGFloat = 2

    /// [I] `file_Daj1ZqByuk14ZB0x-Photo-9F31958B.jpeg` — all three dot cores
    /// back-solve to roughly 90 % alpha against the theme tint, so the loop
    /// only nudges opacity from this rest value to 1.
    private static let restOpacity: Double = 0.90

    /// [I] `file_Daj1ZqByuk14ZB0x-Photo-9F31958B.jpeg` — captured dot widths
    /// differ by about half a point, so the pulse swings scale only from this
    /// rest value to 1.
    private static let restScale: CGFloat = 0.88

    /// [I] `file_Daj1ZqByuk14ZB0x-Photo-9F31958B.jpeg` — the captured pose
    /// rises left to right; 3 pt reproduces that visible lift while keeping
    /// the crest clear of the canvas edge.
    private static let liftAmplitude: CGFloat = 3

    /// [I] `file_Daj1ZqByuk14ZB0x-Photo-9F31958B.jpeg` — the capture is one
    /// loop frame, so the opening choreography is not observable. This
    /// stagger is a design inference that lands on the captured rest pose.
    private static let openingStagger = 0.10

    /// [I] `file_Daj1ZqByuk14ZB0x-Photo-9F31958B.jpeg` — per-dot opening ramp
    /// length (in loop-phase units); same inference as `openingStagger`.
    private static let openingRamp = 0.60

    /// [I] `file_Daj1ZqByuk14ZB0x-Photo-9F31958B.jpeg` — the capture shows the
    /// left dot resting, the middle rising and the right at its crest. This
    /// start offset reproduces that phase relationship; it is not measured
    /// frame timing.
    private static let loopStagger = 0.11

    /// [I] `file_Daj1ZqByuk14ZB0x-Photo-9F31958B.jpeg` — pulse width as a
    /// fraction of the 110-frame loop, chosen to match the captured pose and
    /// leave a short rest between waves. Not measured frame timing.
    private static let loopPulse = 0.34

    /// [I] `file_Daj1ZqByuk14ZB0x-Photo-9F31958B.jpeg` — closing is not
    /// captured; its stagger mirrors the inferred opening.
    private static let closingStagger = 0.08

    /// [I] `file_Daj1ZqByuk14ZB0x-Photo-9F31958B.jpeg` — closing ramp length,
    /// mirroring the inferred opening.
    private static let closingRamp = 0.60

    /// [I] `file_Daj1ZqByuk14ZB0x-Photo-9F31958B.jpeg` — closing is not
    /// captured; the dots shrink by this fraction on the way out, mirroring
    /// the inferred opening.
    private static let closingShrink: CGFloat = 0.3

    // MARK: - Frame model

    /// Official frame counts. Only `.think` is generated today; every other
    /// pose shares its timings until its own flipbook is drawn.
    static func frameCount(for body: WorkingMarkBody, phase: WorkingMarkPhase) -> Int {
        switch body {
        case .think, .generic, .search, .read, .code, .write, .blocked:
            switch phase {
            case .opening: return CodePageTheme.workingMarkThinkOpeningFrames
            case .looping: return CodePageTheme.workingMarkThinkLoopFrames
            case .closing: return CodePageTheme.workingMarkThinkClosingFrames
            }
        }
    }

    /// One phase's duration at the official 30 fps.
    static func duration(of phase: WorkingMarkPhase) -> TimeInterval {
        Double(frameCount(for: .think, phase: phase)) / CodePageTheme.workingMarkFrameRate
    }

    /// Exact frame `index` of `phase`; out-of-range indices clamp to the phase.
    static func frame(body: WorkingMarkBody, phase: WorkingMarkPhase, index: Int) -> WorkingMarkFrame {
        let count = frameCount(for: body, phase: phase)
        let clamped = min(max(index, 0), count - 1)
        switch phase {
        case .opening:
            return makeOpeningFrame(index: clamped, count: count)
        case .looping:
            return makeLoopingFrame(index: clamped, count: count)
        case .closing:
            return makeClosingFrame(index: clamped, count: count)
        }
    }

    /// The frame shown `elapsed` seconds after the mark appeared.
    ///
    /// Opening plays once and looping repeats; `closing` is deliberately not
    /// part of this timeline — the official removal path plays the 0.4 s
    /// scale/opacity group instead (`CANONICAL/20-working-mark.md` §6). Use
    /// `closingFrame(body:progress:)` for a body swap that needs the sprite's
    /// own closing frames.
    static func frame(body: WorkingMarkBody, elapsed: TimeInterval, isStill: Bool) -> WorkingMarkFrame {
        if isStill {
            // Official `isStill` plays one sprite frame; its index is [U].
            // Loop frame 0 is the rest pose and reads as a clean `...`.
            return frame(body: body, phase: .looping, index: 0)
        }
        let openingCount = frameCount(for: body, phase: .opening)
        let openingDuration = Double(openingCount) / CodePageTheme.workingMarkFrameRate
        let elapsed = max(elapsed, 0)
        if elapsed < openingDuration {
            let index = Int(elapsed * CodePageTheme.workingMarkFrameRate)
            return frame(body: body, phase: .opening, index: min(index, openingCount - 1))
        }
        let loopCount = frameCount(for: body, phase: .looping)
        let loopIndex = Int((elapsed - openingDuration) * CodePageTheme.workingMarkFrameRate) % loopCount
        return frame(body: body, phase: .looping, index: loopIndex)
    }

    /// Closing sprite frame for normalized progress in `0 ... 1`
    /// (15 frames, 0.50 s).
    static func closingFrame(body: WorkingMarkBody, progress: Double) -> WorkingMarkFrame {
        let count = frameCount(for: body, phase: .closing)
        let progress = min(max(progress, 0), 0.999_999)
        return frame(body: body, phase: .closing, index: Int(progress * Double(count)))
    }

    // MARK: - Drawing

    /// Renders `frame` into a 20 x 20 image at `scale` (pass the display
    /// scale). The caller resolves the tint; `WorkingMarkView` passes
    /// `CodePageTheme.workingMarkTint` for the current colour scheme.
    static func image(for frame: WorkingMarkFrame, tint: UIColor, scale: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = max(scale, 1)
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: canvasSize, height: canvasSize),
            format: format)
        return renderer.image { context in
            let cg = context.cgContext
            for dot in frame.dots where dot.opacity > 0.001 && dot.scale > 0.001 {
                let radius = dot.radius * dot.scale
                cg.setFillColor(tint.withAlphaComponent(CGFloat(dot.opacity)).cgColor)
                cg.fillEllipse(in: CGRect(
                    x: dot.center.x - radius,
                    y: dot.center.y - radius,
                    width: radius * 2,
                    height: radius * 2))
            }
        }
    }

    /// Time-driven convenience wrapper around `image(for:tint:scale:)`.
    static func image(body: WorkingMarkBody,
                      elapsed: TimeInterval,
                      isStill: Bool,
                      tint: UIColor,
                      scale: CGFloat) -> UIImage {
        image(for: frame(body: body, elapsed: elapsed, isStill: isStill),
              tint: tint,
              scale: scale)
    }

    // MARK: - Frame construction

    private static func makeOpeningFrame(index: Int, count: Int) -> WorkingMarkFrame {
        let progress = Double(index + 1) / Double(count)
        let dots = dotCenterXs.enumerated().map { position, x in
            let local = unitRamp(progress,
                                 start: Double(position) * openingStagger,
                                 length: openingRamp)
            let eased = smoothstep(local)
            return WorkingMarkDot(
                center: CGPoint(x: x, y: dotCenterY),
                radius: dotRadius,
                scale: restScale * CGFloat(eased),
                opacity: restOpacity * eased)
        }
        return WorkingMarkFrame(phase: .opening, index: index, dots: dots)
    }

    /// The loop pose captured in the 2026-10-22 screenshot: the rightmost dot
    /// is at its crest, the middle one is rising, the leftmost one rests.
    private static func makeLoopingFrame(index: Int, count: Int) -> WorkingMarkFrame {
        let progress = Double(index) / Double(count)
        let dots = dotCenterXs.enumerated().map { position, x in
            var local = progress - Double(position) * loopStagger
            local -= floor(local)  // wrap into 0 ..< 1
            let pulse = local < loopPulse ? sin(Double.pi * local / loopPulse) : 0
            return WorkingMarkDot(
                center: CGPoint(x: x, y: dotCenterY - liftAmplitude * CGFloat(pulse)),
                radius: dotRadius,
                scale: restScale + (1 - restScale) * CGFloat(pulse),
                opacity: restOpacity + (1 - restOpacity) * pulse)
        }
        return WorkingMarkFrame(phase: .looping, index: index, dots: dots)
    }

    private static func makeClosingFrame(index: Int, count: Int) -> WorkingMarkFrame {
        let progress = Double(index + 1) / Double(count)
        let dots = dotCenterXs.enumerated().map { position, x in
            let local = unitRamp(progress,
                                 start: Double(position) * closingStagger,
                                 length: closingRamp)
            let eased = smoothstep(local)
            return WorkingMarkDot(
                center: CGPoint(x: x, y: dotCenterY),
                radius: dotRadius,
                scale: restScale * (1 - closingShrink * CGFloat(eased)),
                opacity: restOpacity * (1 - eased))
        }
        return WorkingMarkFrame(phase: .closing, index: index, dots: dots)
    }

    private static func unitRamp(_ value: Double, start: Double, length: Double) -> Double {
        min(max((value - start) / length, 0), 1)
    }

    /// [I] `file_Daj1ZqByuk14ZB0x-Photo-9F31958B.jpeg` — the capture is one
    /// loop frame, so opening and closing are unobserved. Their inferred
    /// arrival/departure uses a smoothstep to avoid visible corners.
    private static func smoothstep(_ value: Double) -> Double {
        value * value * (3 - 2 * value)
    }
}

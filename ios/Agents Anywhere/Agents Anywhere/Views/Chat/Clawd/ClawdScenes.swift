import Foundation

/// Clawd's pre-rendered scene timelines, rebuilt from Claude iOS's scene
/// builders (addresses in `clawd-scenes*.md`).
///
/// Each scene is a list of poses at 12 fps; `hold(n)` repeats the current pose
/// n times and `padTo(m)` resets to the resting pose before padding. Accent
/// frames are the haptic trigger points (`SensoryFeedback.impact(weight:
/// .light, intensity:)` in `ClawdAccentFeedback`).
enum ClawdScenes {
    typealias Pose = ClawdRenderer.Pose

    /// Scene order matches `ClawdScene` in the binary.
    enum Scene: Int, CaseIterable {
        case jumping, dancing, laptop, guitar, noddingOff, sleeping, wakingUp
        case rocket, heart, snow, leaves, sunglasses, blooming, atLaptop, typingAgain
    }

    struct Timeline {
        let frames: [Pose]
        /// `(frame, intensity)` — the official accent table per scene.
        let accents: [(frame: Int, intensity: Double)]
    }

    static func timeline(for scene: Scene) -> Timeline {
        switch scene {
        case .jumping: return jumping
        case .dancing: return dancing
        case .noddingOff: return noddingOff
        case .sleeping: return sleeping
        case .rocket: return rocket
        case .heart: return heart
        default: return jumping
        }
    }

    // MARK: - Poses

    private static let base = ClawdRenderer.restingPose

    private static func closedEyes(_ p: Pose) -> Pose {
        var p = p
        p.eyes = ClawdRenderer.Eyes(top: 2, width: 2, height: 0, gap: 8,
                                    dx: 0, tilt: 0, slideNear: 0, slideFar: 0,
                                    left: nil, right: nil)
        return p
    }

    private static func withEyes(_ p: Pose, top: Int, width: Int, height: Int,
                                 gap: Int) -> Pose {
        var p = p
        p.eyes = ClawdRenderer.Eyes(top: top, width: width, height: height, gap: gap,
                                    dx: 0, tilt: 0, slideNear: 0, slideFar: 0,
                                    left: nil, right: nil)
        return p
    }

    private static func withLeftArm(_ p: Pose, dx: Int, dy: Int,
                                    width: Int, height: Int) -> Pose {
        var p = p
        p.leftArm = ClawdRenderer.ArmBlock(dx: dx, dy: dy, width: width,
                                           height: height, shade: nil)
        return p
    }

    // MARK: - Timelines

    /// 21 frames, resting pose throughout; accent on frame 4.
    private static let jumping = Timeline(
        frames: Array(repeating: base, count: 21),
        accents: [(4, 0.6)])

    /// 10 frames: 4 resting + eyes(3,2,1,8) + leftArm(0,5,4,4) ×2
    /// + eyes(5,2,1,8) ×2 + closed ×2.
    private static let noddingOff: Timeline = {
        var f: [Pose] = []
        f += Array(repeating: base, count: 4)
        let a = withLeftArm(withEyes(base, top: 3, width: 2, height: 1, gap: 8),
                            dx: 0, dy: 5, width: 4, height: 4)
        f += Array(repeating: a, count: 2)
        f += Array(repeating: withEyes(base, top: 5, width: 2, height: 1, gap: 8), count: 2)
        f += Array(repeating: closedEyes(base), count: 2)
        return Timeline(frames: f, accents: [])
    }()

    /// 45 frames, 11/6/11/6/11; sleeping pose = closed eyes + left arm.
    private static let sleeping: Timeline = {
        let sleep = withLeftArm(closedEyes(base), dx: 0, dy: 7, width: 4, height: 4)
        var f: [Pose] = []
        f += Array(repeating: base, count: 11)
        f += Array(repeating: sleep, count: 6)
        f += Array(repeating: base, count: 11)
        f += Array(repeating: sleep, count: 6)
        f += Array(repeating: base, count: 11)
        return Timeline(frames: f, accents: [])
    }()

    /// 40 frames: 4 resting; eyes top1 ×15; closed ×1; eyes top1 ×14; resting ×6.
    private static let rocket: Timeline = {
        let look = withEyes(base, top: 1, width: 4, height: 4, gap: 20)
        var f: [Pose] = []
        f += Array(repeating: base, count: 4)
        f += Array(repeating: look, count: 15)
        f += [closedEyes(base)]
        f += Array(repeating: look, count: 14)
        f += Array(repeating: base, count: 6)
        return Timeline(frames: f, accents: [])
    }()

    /// 44 frames: 8 / 2 / 17 / 2 / 15; middle sections use eyes(3,2,1,8).
    private static let heart: Timeline = {
        let look = withEyes(base, top: 3, width: 2, height: 1, gap: 8)
        var f: [Pose] = []
        f += Array(repeating: base, count: 8)
        f += Array(repeating: look, count: 2)
        f += Array(repeating: base, count: 17)
        f += Array(repeating: look, count: 2)
        f += Array(repeating: base, count: 15)
        return Timeline(frames: f, accents: [])
    }()

    /// 36 frames; accents are confirmed from the builder table, but the
    /// per-frame poses are not fully translated yet — keep the resting pose
    /// rather than inventing motion.
    private static let dancing: Timeline = Timeline(
        frames: Array(repeating: base, count: 36),
        accents: [(10, 0.5), (14, 0.5), (18, 0.5), (26, 0.5),
                  (30, 0.5), (34, 0.5), (22, 0.7), (38, 0.7)])
}

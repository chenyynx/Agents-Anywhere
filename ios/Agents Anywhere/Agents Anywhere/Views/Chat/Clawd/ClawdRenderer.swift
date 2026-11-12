import Foundation

/// Rebuilds Clawd's pixel frames from `ClawdPose`, matching Claude iOS's
/// renderer.
///
/// Shape and offsets were recovered from the decrypted Claude 1.261109.19
/// binary (see `clawd-re-26110919.md` in the reverse-engineering archive):
///
/// - `ClawdPose` is 0x148 bytes; `x/lift/turn` at 0x00/0x08/0x10, `torso` at
///   0x18, `eyes` at 0x30, `leftArm` 0xB8, `rightArm` 0xE8, `legs` 0x118.
/// - `rectFill` is `0x101550920`: shade 0 → palette cell 1, shade 1 → cell 2,
///   shade 0x1B → erase.
/// - Eyes are `Cx + 2 + dx + near` (left) and right-aligned on the far side;
///   `eyeY = ground − lift − legsH − torsoH + eyes.top` (`0x101554b50..bc0`).
/// - Leg rows draw a `width`-wide bar in palette 1 with an optional
///   `shade`-wide darker band in palette 2.
/// - Arms with `block` draw two rects; `art` blits an optional mirrored sprite.
///
/// The 55×37 reference grid was validated cell-by-cell against the official
/// Code screen at 99.6% (the 9 remaining cells are the fourth leg's left edge,
/// still UNKNOWN).
enum ClawdRenderer {

    // MARK: - Pose

    struct Eyes {
        var top = 0
        var width = 4
        var height = 4
        var gap = 20
        var dx = 0
        var tilt = 0
        /// `near`/`far` shift each eye when `slide` is present; when absent the
        /// renderer synthesises them from `turn`.
        var slideNear: Int?
        var slideFar: Int?
        var left: EyeShape?
        var right: EyeShape?
    }

    struct EyeShape {
        var width: Int
        var height: Int
        var drop = 0
    }

    struct ArmBlock {
        var dx = 0
        var dy = 0
        var width = 0
        var height = 0
        /// Width of the darker band; 0 draws only the body.
        var shade: Int?
    }

    struct Leg {
        var x: Int
        /// Negative values place the darker band on the left edge.
        var shade: Int?
    }

    struct Pose {
        var x = 0
        var lift = 0
        var turn = 0
        var torsoHeight = 28
        var eyes = Eyes()
        var leftArm: ArmBlock?
        var rightArm: ArmBlock?
        var legsHeight = 9
        var legsWidth = 5
        var legs: [Leg] = []
    }

    // MARK: - Palette

    /// ARGB values from the official 27-entry palette at `0x1054825e8`.
    static let palette: [UInt32] = [
        0xFFD97757, 0xFFBE684D, 0xFF141413, 0xFF191817, 0xFF2F2F2D,
        0xFF72716B, 0xFF8B8B8B, 0xFFBABABA, 0xFFFFFFFF, 0xFF817CBC,
        0xFFF1C877, 0xFFD55450, 0xFF86B6EF, 0xFFF9F8F4, 0xFF3A6B1D,
        0xFF7DB557, 0xFF82304B, 0xFF852928, 0xFFAD3D3B, 0xFFD66D90,
        0xFFEBB2B2, 0xFFE1907E, 0xFFE6A198, 0xFFDE8871, 0xFFBF8534,
        0xFF918BD6, 0xFF5750A1,
    ]

    static let width = 55
    static let height = 37
    /// The tail is drawn in stage space past the framing width (x up to 69).
    static let stageWidth = 72

    // MARK: - Grid

    struct Grid {
        var cells: [UInt8]

        init() {
            cells = [UInt8](repeating: 0, count: ClawdRenderer.stageWidth * ClawdRenderer.height)
        }

        /// `0x101550920` — shade 0 → cell 1, 1 → cell 2, 0x1B → clear.
        mutating func rect(_ x: Int, _ y: Int, _ w: Int, _ h: Int, shade: Int) {
            let value: UInt8 = shade == 0x1B ? 0 : UInt8(shade + 1)
            let y0 = max(y, 0), y1 = min(y + h, ClawdRenderer.height)
            let x0 = max(x, 0), x1 = min(x + w, ClawdRenderer.stageWidth)
            guard y0 < y1, x0 < x1 else { return }
            for row in y0..<y1 {
                let base = row * ClawdRenderer.stageWidth
                for col in x0..<x1 { cells[base + col] = value }
            }
        }

        /// `0x101550a30` — 0 skips, 0xFF erases, everything else writes.
        mutating func blit(_ sprite: [UInt8], _ w: Int, _ h: Int, _ dx: Int, _ dy: Int) {
            for row in 0..<h {
                let ty = dy + row
                guard ty >= 0, ty < ClawdRenderer.height else { continue }
                for col in 0..<w {
                    let tx = dx + col
                    guard tx >= 0, tx < ClawdRenderer.stageWidth else { continue }
                    let value = sprite[row * w + col]
                    if value == 0 { continue }
                    cells[ty * ClawdRenderer.stageWidth + tx] = value == 0xFF ? 0 : value
                }
            }
        }
    }

    // MARK: - Rendering

    /// The resting pose measured from the official Code screen.
    static let restingPose = Pose(
        x: -6, lift: 0, turn: 0,
        torsoHeight: 28,
        eyes: Eyes(top: 5, width: 4, height: 4, gap: 20, dx: 0, tilt: 0,
                   slideNear: 0, slideFar: 0,
                   left: nil,
                   right: EyeShape(width: 5, height: 4, drop: 0)),
        leftArm: ArmBlock(dx: 16, dy: 9, width: 28, height: 10, shade: nil),
        rightArm: ArmBlock(dx: 0, dy: 9, width: 27, height: 10, shade: nil),
        legsHeight: 9,
        legsWidth: 5,
        legs: [Leg(x: 9), Leg(x: 18), Leg(x: 32), Leg(x: 42)])

    /// Tail cells in stage space (x 48…69); grey palette index 6.
    static let tail: [(x: Int, y: Int, w: Int, h: Int)] = [
        (68, 23, 2, 3), (66, 26, 4, 2), (64, 28, 4, 2), (61, 30, 5, 2),
        (59, 32, 5, 2), (59, 34, 4, 1), (48, 35, 14, 2),
    ]
    static let tailCell: UInt8 = 7

    static func render(_ pose: Pose) -> Grid {
        var grid = Grid()
        let ground = height

        // Torso: `torsoLeft` is the half width (27.5 ± 18 → x 9…45).
        let torsoX = width / 2 - 18
        let torsoY = ground - pose.legsHeight - pose.torsoHeight
        grid.rect(torsoX, torsoY, 37, pose.torsoHeight, shade: 0)

        // Eyes. `near`/`far` fall back to values derived from turn; the resting
        // pose (turn 0) uses 12 / 12.
        let cx = stageOriginX + pose.x
        let eyeY = ground - pose.lift - pose.legsHeight - pose.torsoHeight + pose.eyes.top
        var near = 12
        var far = 12
        if let slideNear = pose.eyes.slideNear { near = slideNear }
        if let slideFar = pose.eyes.slideFar { far = slideFar }
        if pose.turn < 0 { swap(&near, &far) }
        let leftWidth = pose.eyes.left?.width ?? pose.eyes.width
        let leftHeight = pose.eyes.left?.height ?? pose.eyes.height
        let leftDrop = pose.eyes.left?.drop ?? 0
        let rightWidth = pose.eyes.right?.width ?? pose.eyes.width
        let rightHeight = pose.eyes.right?.height ?? pose.eyes.height
        let rightDrop = pose.eyes.right?.drop ?? 0
        grid.rect(cx + 2 + pose.eyes.dx + near,
                  eyeY + leftDrop, leftWidth, leftHeight, shade: 2)
        grid.rect(cx + 2 + pose.eyes.dx + pose.eyes.width + pose.eyes.gap + far
                    + pose.eyes.width - rightWidth,
                  eyeY + pose.eyes.tilt + rightDrop, rightWidth, rightHeight, shade: 2)

        // Legs: `width`-wide bar in palette 1 plus a `|shade|` band in palette 2.
        let legY = ground - pose.legsHeight
        for leg in pose.legs {
            // Legs clip at the torso's right edge (x=46); the fourth leg is
            // x=42 with width 5, which the official frame shows as 4 cells.
            grid.rect(leg.x, legY, min(pose.legsWidth, 46 - leg.x), pose.legsHeight, shade: 0)
            if let shade = leg.shade, shade != 0 {
                let band = min(abs(shade), pose.legsWidth)
                let bandX = shade > 0 ? leg.x + pose.legsWidth - band : leg.x
                grid.rect(bandX, legY, band, pose.legsHeight, shade: 1)
            }
        }

        // Arms.
        if let arm = pose.leftArm {
            drawArm(arm, into: &grid, poseX: pose.x, isLeft: true)
        }
        if let arm = pose.rightArm {
            drawArm(arm, into: &grid, poseX: pose.x, isLeft: false)
        }

        // Tail.
        for cell in tail {
            grid.rect(cell.x, cell.y, cell.w, cell.h, shade: Int(tailCell) - 1)
        }
        return grid
    }

    /// `x4 = 18` is `ClawdFraming.torsoLeft`; `x28 = x4 + pose.x` (`0x101554b50`).
    /// Arm anchors (`0x101555138` left / `0x1015551e4` right), with no lean
    /// steps: left `f − width + dx`, right `f + 16 − dx`, where `f = 18 + pose.x`.
    private static let stageOriginX = 18

    private static func drawArm(_ arm: ArmBlock, into grid: inout Grid,
                                poseX: Int, isLeft: Bool) {
        let f = stageOriginX + poseX
        let anchor = isLeft ? f - arm.width + arm.dx : f + 16 - arm.dx
        grid.rect(anchor, arm.dy, arm.width, arm.height, shade: 0)
        if let shade = arm.shade, shade >= 1 {
            grid.rect(anchor + arm.width - shade, arm.dy,
                      shade, arm.height, shade: 1)
        }
    }
}

extension ClawdRenderer.Pose {
    /// `lean` shifts the whole body horizontally; the resting pose has none.
    var leanShift: Int { 0 }
}

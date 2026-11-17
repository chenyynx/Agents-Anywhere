//
//  BlobatarPose.swift
//
//  Ported from blobatar 2.8.0 (https://github.com/Alain00/blobatar),
//  MIT License. Copyright (c) 2026 Alain.
//
//  The fourteen expressions are channel vectors over one shared bake, not
//  fourteen drawings. A pose changes eye scale, tilt, offsets, body lift and
//  (for four of them) a tint; the geometry below is the same for every face.
//

import Foundation

struct BlobatarPose {
    var esx: Double = 1
    var esy: Double = 1
    var tilt: Double = 0
    var edy: Double = 0
    var edx: Double = 0
    var esx2: Double = 0
    var esy2: Double = 0
    var tilt2: Double = 0
    var edy2: Double = 0
    var lock: Double = 0
    var heat: Double = 0
    var shake: Double = 0
    var rock: Double = 0
    var bdy: Double = 0

    var tint: BlobatarTint? = nil

    /// Applies the eye channels to a laid-out eye pair.
    ///
    /// `rockp` is `thinking`'s seesaw phase, +1…−1. At +1 the static
    /// differential is reproduced exactly, which is why a still `thinking` face
    /// is frame zero of the loop rather than an approximation of it.
    func baked(_ eyes: [BlobatarEye], rockp: Double = 1) -> [BlobatarEye] {
        eyes.enumerated().map { index, eye in
            let side = index == 1 ? 1.0 : -1.0
            let selected = index == 1 ? 1.0 : 0.0
            let phase = selected * (1 - rock) + rock * ((1 + side * rockp) / 2)
            var posed = eye
            posed.cx = eye.cx + edx * side
            posed.cy = eye.cy + edy + phase * edy2
            posed.rx = eye.rx * (esx + (index == 1 ? esx2 : 0))
            posed.ry = eye.ry * (esy + (index == 1 ? esy2 : 0))
            posed.rot = eye.rot * (1 - lock) + (tilt + (index == 1 ? tilt2 : 0)) * side
            return posed
        }
    }

    static func lerp(_ a: BlobatarPose, _ b: BlobatarPose, _ t: Double) -> BlobatarPose {
        // `from·(1 − t) + to·t`, not `from + (to − from)·t`: at t = 1 this
        // returns the target's numbers exactly, which is what makes a settled
        // morph the static pose rather than merely a resemblance of it.
        func mix(_ x: Double, _ y: Double) -> Double { x * (1 - t) + y * t }
        var pose = BlobatarPose()
        pose.esx = mix(a.esx, b.esx)
        pose.esy = mix(a.esy, b.esy)
        pose.tilt = mix(a.tilt, b.tilt)
        pose.edy = mix(a.edy, b.edy)
        pose.edx = mix(a.edx, b.edx)
        pose.esx2 = mix(a.esx2, b.esx2)
        pose.esy2 = mix(a.esy2, b.esy2)
        pose.tilt2 = mix(a.tilt2, b.tilt2)
        pose.edy2 = mix(a.edy2, b.edy2)
        pose.lock = mix(a.lock, b.lock)
        pose.heat = mix(a.heat, b.heat)
        pose.shake = mix(a.shake, b.shake)
        pose.rock = mix(a.rock, b.rock)
        pose.bdy = mix(a.bdy, b.bdy)
        // Tint targets do not interpolate; the heat channel carries the blend.
        pose.tint = t < 0.5 ? a.tint : b.tint
        return pose
    }
}

enum BlobatarExpressions {
    static let idle = BlobatarPose()

    static let happy = BlobatarPose(esx: 1.72, esy: 0.3, tilt: 8, edy: -1.5, edx: 1.5,
                                    esx2: 0.08, esy2: 0.05, tilt2: -16, edy2: 0,
                                    lock: 1, heat: 0, shake: 0, rock: 0, bdy: -2.2)

    static let sad = BlobatarPose(esx: 0.6, esy: 0.56, tilt: 26, edy: 3.6, edx: 1.9,
                                  esx2: -0.05, esy2: -0.07, tilt2: -7, edy2: 0,
                                  lock: 1, heat: 0, shake: 0, rock: 0, bdy: 2.6)

    static let mad = BlobatarPose(esx: 1.85, esy: 0.26, tilt: -33, edy: 0.4, edx: 0.6,
                                  esx2: 0, esy2: -0.03, tilt2: 5, edy2: 0,
                                  lock: 1, heat: 0.62, shake: 0.55, rock: 0, bdy: 0.8,
                                  tint: BlobatarColor.hot)

    static let surprised = BlobatarPose(esx: 1.34, esy: 1.2, tilt: -6, edy: -1.05, edx: 0.5,
                                        esx2: 0.05, esy2: 0.07, tilt2: 3, edy2: 0,
                                        lock: 1, heat: 0, shake: 0, rock: 0, bdy: -1.4)

    static let wink = BlobatarPose(esx: 1.32, esy: 0.76, tilt: 5, edy: -0.6, edx: 0.8,
                                   esx2: 0.26, esy2: -0.56, tilt2: -11, edy2: 0,
                                   lock: 1, heat: 0, shake: 0, rock: 0, bdy: -1.1)

    static let sleepy = BlobatarPose(esx: 1.14, esy: 0.22, tilt: 0, edy: 2.4, edx: 0.3,
                                     esx2: -0.04, esy2: 0.03, tilt2: 4, edy2: 0,
                                     lock: 1, heat: 0, shake: 0, rock: 0, bdy: 1.2)

    static let smug = BlobatarPose(esx: 1.3, esy: 0.42, tilt: 18, edy: -0.5, edx: 0.5,
                                   esx2: 0.06, esy2: -0.06, tilt2: -36, edy2: 0,
                                   lock: 1, heat: 0, shake: 0, rock: 0, bdy: -1)

    static let unsure = BlobatarPose(esx: 0.95, esy: 1.02, tilt: 4, edy: -0.2, edx: 0.3,
                                     esx2: 0.24, esy2: -0.44, tilt2: -18, edy2: 0,
                                     lock: 1, heat: 0, shake: 0, rock: 0, bdy: 0)

    static let scared = BlobatarPose(esx: 0.78, esy: 0.96, tilt: -12, edy: -1.5, edx: -0.8,
                                     esx2: -0.04, esy2: 0.05, tilt2: 4, edy2: 0,
                                     lock: 1, heat: 0, shake: 0.35, rock: 0, bdy: -0.6)

    static let love = BlobatarPose(esx: 0.86, esy: 1.28, tilt: -14, edy: -0.5, edx: -0.35,
                                   esx2: 0.05, esy2: 0.06, tilt2: 6, edy2: 0,
                                   lock: 1, heat: 0.6, shake: 0, rock: 0, bdy: -1.6,
                                   tint: BlobatarColor.rose)

    static let shy = BlobatarPose(esx: 0.62, esy: 0.5, tilt: 10, edy: 1.4, edx: -0.2,
                                  esx2: -0.05, esy2: -0.04, tilt2: -8, edy2: 0,
                                  lock: 1, heat: 0.55, shake: 0, rock: 0, bdy: 0.9,
                                  tint: BlobatarColor.blush)

    static let sick = BlobatarPose(esx: 1.25, esy: 0.34, tilt: 20, edy: 1.8, edx: 0.8,
                                   esx2: 0.05, esy2: -0.05, tilt2: -6, edy2: 0,
                                   lock: 1, heat: 0.6, shake: 0.18, rock: 0, bdy: 1.4,
                                   tint: BlobatarColor.bile)

    static let thinking = BlobatarPose(esx: 1.15, esy: 0.62, tilt: 0, edy: 4.2, edx: 0.4,
                                       esx2: 0.02, esy2: 0.06, tilt2: 0, edy2: -8.4,
                                       lock: 1, heat: 0, shake: 0, rock: 0.8, bdy: -0.4)

    /// Every pose, for the tap picker.
    static let roster: [BlobatarPose] = [
        happy, sad, mad, surprised, wink, sleepy, smug, unsure, scared,
        love, shy, sick, thinking,
    ]
}

//
//  BlobatarShapes.swift
//
//  Ported from blobatar 2.8.0 (https://github.com/Alain00/blobatar),
//  MIT License. Copyright (c) 2026 Alain.
//
//  The ten gen-2 silhouettes. A shape owns its geometry and its safe face
//  region; the band table in BlobatarLayout owns how often each comes up.
//

import Foundation

struct BlobatarBody {
    var cx: Double
    var cy: Double
    var rx: Double
    var ry: Double
    var n: Double
    var rot: Double
    var radii: [Double]
    /// Polygon-only.
    var sides: Int?
    var round: Double?
}

struct BlobatarEllipse {
    var cx: Double
    var cy: Double
    var rx: Double
    var ry: Double
}

struct BlobatarPetal {
    var cx: Double
    var cy: Double
    var r: Double
}

struct BlobatarDeco {
    var petals: [BlobatarPetal] = []
    var extra: [BlobatarPath] = []
}

struct BlobatarShape {
    let name: String
    /// How much of the frame the core body takes.
    let core: Double
    var body: ((BlobatarTraits, inout BlobatarBody) -> Void)? = nil
    var face: ((BlobatarBody) -> BlobatarEllipse)? = nil
    var decorate: ((BlobatarTraits, BlobatarBody, inout BlobatarDeco) -> Void)? = nil
    var path: ((BlobatarBody) -> BlobatarPath)? = nil
}

enum BlobatarShapes {
    static let round = BlobatarShape(name: "round", core: 1)

    static let organic = BlobatarShape(name: "organic", core: 0.98,
                                       face: splineFace, path: spline)

    /// `round`, squared off and tilted. Same path, different parameters.
    static let boxy = BlobatarShape(name: "boxy", core: 0.86, body: { traits, body in
        body.n = traits.num("body.n", 3.4, 6)
        body.rot = traits.num("body.rot", -20, 20)
    })

    static let capsule = BlobatarShape(
        name: "capsule", core: 1.02,
        body: { traits, body in
            body.ry *= traits.num("capsule.squat", 0.55, 0.68)
        },
        face: shrunk(0.94),
        decorate: { _, body, deco in
            for side in [-1.0, 1.0] {
                deco.petals.append(BlobatarPetal(cx: body.cx + side * (body.rx - body.ry),
                                                 cy: body.cy,
                                                 r: body.ry))
            }
        },
        path: { body in
            BlobatarPathBuilder.box(cx: body.cx, cy: body.cy,
                                    rx: body.rx - body.ry, ry: body.ry)
        })

    static let nub = BlobatarShape(
        name: "nub", core: 0.88,
        decorate: { traits, body, deco in
            let count = traits.int("nub.n", 1, 2)
            for index in 0..<count {
                let angle = traits.num("nub.a\(index)", 0, 2 * .pi)
                deco.petals.append(BlobatarPetal(
                    cx: body.cx + cos(angle) * body.rx * 0.88,
                    cy: body.cy + sin(angle) * body.rx * 0.88,
                    r: body.rx * traits.num("nub.r\(index)", 0.24, 0.4)))
            }
        })

    /// `organic`, with lobes on the upper half.
    static let cloud = BlobatarShape(
        name: "cloud", core: 0.78,
        face: splineFace,
        decorate: { traits, body, deco in
            let count = traits.int("cloud.n", 4, 6)
            for index in 0..<count {
                let angle = .pi + (.pi * (Double(index) + 0.5)) / Double(count)
                deco.petals.append(BlobatarPetal(
                    cx: body.cx + cos(angle) * body.rx * 0.8,
                    cy: body.cy + sin(angle) * body.rx * 0.5,
                    r: body.rx * traits.num("cloud.r\(index)", 0.44, 0.62)))
            }
        },
        path: spline)

    static let droplet = BlobatarShape(
        name: "droplet", core: 0.78,
        body: { _, body in
            // Shifted down by what the taper adds above, so head and point
            // together sit centred in the frame.
            body.cy += 0.22 * body.ry
            body.n = 2
        },
        face: { body in
            BlobatarEllipse(cx: body.cx, cy: body.cy + body.ry * 0.05,
                            rx: body.rx * 0.88, ry: body.ry * 0.88)
        },
        decorate: { traits, body, deco in
            deco.extra.append(BlobatarPathBuilder.taper(
                cx: body.cx, cy: body.cy, rx: body.rx, ry: body.ry,
                tip: traits.num("droplet.tip", 1.4, 1.65)))
        })

    static let hexagon = BlobatarShape(
        name: "hexagon", core: 1.05,
        body: { traits, body in
            body.sides = 6
            body.rot = traits.num("body.rot", -12, 12)
            body.round = traits.num("poly.round", 0.24, 0.5)
        },
        face: polyFace,
        path: poly)

    static let sun = BlobatarShape(
        name: "sun", core: 0.7,
        decorate: { traits, body, deco in
            let count = traits.int("sun.n", 6, 9)
            let distance = body.rx * traits.num("sun.dist", 1.0, 1.08)
            let radius = body.rx * traits.num("sun.r", 0.2, 0.26)
            let offset = traits.num("sun.rot", 0, 2 * .pi)
            for index in 0..<count {
                let angle = offset + (2 * .pi * Double(index)) / Double(count)
                deco.petals.append(BlobatarPetal(cx: body.cx + cos(angle) * distance,
                                                 cy: body.cy + sin(angle) * distance,
                                                 r: radius))
            }
        })

    /// `hexagon` with three sides, and a tighter tilt so it rests on its base.
    static let triangle = BlobatarShape(
        name: "triangle", core: 1.15,
        body: { traits, body in
            body.sides = 3
            body.rot = traits.num("body.rot", -5, 5)
            body.round = traits.num("poly.round", 0.24, 0.5)
        },
        face: { body in
            BlobatarEllipse(cx: body.cx, cy: body.cy + body.ry * 0.1,
                            rx: body.rx * 0.54, ry: body.ry * 0.36)
        },
        path: poly)

    /// `[shape, upper edge of its band in [0, 1)]`, in order.
    static let bands: [(shape: BlobatarShape, upTo: Double)] = [
        (BlobatarShapes.round, 0.22), (organic, 0.48), (boxy, 0.6),
        (capsule, 0.7), (nub, 0.79), (cloud, 0.86), (droplet, 0.915),
        (hexagon, 0.95), (sun, 0.98), (triangle, 1),
    ]

    // MARK: - Shared implementations

    private static func poly(_ body: BlobatarBody) -> BlobatarPath {
        BlobatarPathBuilder.polygon(cx: body.cx, cy: body.cy, rx: body.rx, ry: body.ry,
                                    sides: body.sides ?? 3, round: body.round ?? 0.3,
                                    rot: body.rot)
    }

    private static func spline(_ body: BlobatarBody) -> BlobatarPath {
        BlobatarPathBuilder.blob(cx: body.cx, cy: body.cy, rx: body.rx, ry: body.ry,
                                 radii: body.radii, rot: body.rot)
    }

    private static func shrunk(_ factor: Double) -> (BlobatarBody) -> BlobatarEllipse {
        { body in
            BlobatarEllipse(cx: body.cx, cy: body.cy,
                            rx: body.rx * factor, ry: body.ry * factor)
        }
    }

    private static func splineFace(_ body: BlobatarBody) -> BlobatarEllipse {
        shrunk((body.radii.min() ?? 1) * 0.95)(body)
    }

    private static func polyFace(_ body: BlobatarBody) -> BlobatarEllipse {
        shrunk(0.84)(body)
    }
}

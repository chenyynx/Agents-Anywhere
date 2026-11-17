//
//  BlobatarIdle.swift
//
//  Ported from blobatar 2.8.0 (https://github.com/Alain00/blobatar),
//  MIT License. Copyright (c) 2026 Alain.
//
//  The idle layer as arithmetic: breathe, bob, blink, saccade and the glance's
//  foreshortening, all pure functions of time with per-seed phases. The web
//  runs the same numbers out of a stylesheet; this is the same spec.
//

import Foundation

struct BlobatarIdleSeeds {
    var phase: Double
    var bob: Double
    var blink: Double
    var blinkPhase: Double
    var saccade: Double
    var saccadePhase: Double
    var lookX: Double
    var lookY: Double
    var lookMX: Double
    var lookMY: Double

    init(traits: BlobatarTraits) {
        let blinkPeriod = (traits.num("motion.blink", 3500, 6500)).rounded()
        let saccadePeriod = (traits.num("motion.saccade", 4200, 7600)).rounded()
        let rawLookX = traits.num("motion.lookX", 1, 2.2)
        let rawLookY = traits.num("motion.lookY", 0.8, 1.7)
        let r2 = { (value: Double) in (value * 100).rounded() / 100 }

        blink = blinkPeriod
        saccade = saccadePeriod
        phase = (traits.num("motion.phase", 0, 2800)).rounded()
        bob = (traits.num("motion.bob", 0, 3400)).rounded()
        blinkPhase = (traits.num("motion.blinkPhase", 0, blinkPeriod)).rounded()
        saccadePhase = (traits.num("motion.saccadePhase", 0, saccadePeriod)).rounded()
        lookX = r2(rawLookX) * (traits.bool("motion.lookXFlip") ? -1 : 1)
        lookY = r2(rawLookY) * (traits.bool("motion.lookYFlip") ? -1 : 1)
        lookMX = r2(rawLookX)
        lookMY = r2(rawLookY)
    }
}

struct BlobatarIdleFrame {
    var shake: (Double, Double)
    var breathe: (Double, Double)
    var bob: Double
    var saccade: (Double, Double)
    var rockp: Double
    var blink: Double
    var wrap: (mx: Double, side: Double, sy: Double, rot: Double)
}

enum BlobatarIdle {
    /// The saccade's six fixations: held, then moved to in a single 1.5% flick.
    private static let saccadeStops: [[Double]] = [
        [0, 0, 0],
        [0.15, 0, 0],
        [0.165, -0.8, -0.9],
        [0.31, -0.8, -0.9],
        [0.325, 1, 0.1],
        [0.47, 1, 0.1],
        [0.485, -0.15, 0.85],
        [0.63, -0.15, 0.85],
        [0.645, 0.75, -0.8],
        [0.79, 0.75, -0.8],
        [0.805, -1, -0.15],
        [0.985, -1, -0.15],
        [1, 0, 0],
    ]

    /// The glance's shape change: horizontal squash, signed term, vertical, rotation.
    private static let wrapStops: [[Double]] = [
        [0, 0, 0, 0, 0],
        [0.15, 0, 0, 0, 0],
        [0.165, -0.0176, 0.008, -0.027, 0.648],
        [0.31, -0.0176, 0.008, -0.027, 0.648],
        [0.325, -0.022, -0.01, -0.003, 0.09],
        [0.47, -0.022, -0.01, -0.003, 0.09],
        [0.485, -0.0033, 0.0015, -0.0255, -0.115],
        [0.63, -0.0033, 0.0015, -0.0255, -0.115],
        [0.645, -0.0165, -0.0075, -0.024, -0.54],
        [0.79, -0.0165, -0.0075, -0.024, -0.54],
        [0.805, -0.022, 0.01, -0.0045, 0.135],
        [0.985, -0.022, 0.01, -0.0045, 0.135],
        [1, 0, 0, 0, 0],
    ]

    /// Four offsets on a 112 ms linear loop.
    private static let shakeStops: [[Double]] = [
        [0, 0.62, -0.34],
        [0.25, -0.7, 0.22],
        [0.5, 0.38, 0.66],
        [0.75, -0.44, -0.6],
        [1, 0.62, -0.34],
    ]

    private static let breatheMS = 2800.0
    private static let bobMS = 3400.0
    private static let rockMS = 900.0
    private static let shakeMS = 112.0

    static func frame(_ seeds: BlobatarIdleSeeds,
                      time: Double,
                      amplitude: Double,
                      shakeAmount: Double) -> BlobatarIdleFrame {
        let breathe = easeInOut(alternate(time, seeds.phase, breatheMS))
        let bob = easeInOut(alternate(time, seeds.bob, bobMS))

        let sac = cycle(time, seeds.saccadePhase, seeds.saccade)
        let shakePhase = cycle(time, 0, shakeMS)

        let r = cycle(time, 0, rockMS)
        let rockp = r < 0.5
            ? 1 - 2 * easeInOut(r * 2)
            : -1 + 2 * easeInOut(r * 2 - 1)

        let b = cycle(time, seeds.blinkPhase, seeds.blink)
        let blink: Double
        if b < 0.972 {
            blink = 1
        } else if b < 0.986 {
            blink = 1 - 0.92 * amplitude * easeIn((b - 0.972) / 0.014)
        } else {
            blink = 1 - 0.92 * amplitude * (1 - easeOut((b - 0.986) / 0.014))
        }

        return BlobatarIdleFrame(
            shake: (stops(shakePhase, shakeStops, 1) * shakeAmount,
                    stops(shakePhase, shakeStops, 2) * shakeAmount),
            breathe: (1 + 0.022 * amplitude * breathe,
                      1 - 0.018 * amplitude * breathe),
            bob: -1.1 * amplitude * bob,
            saccade: (stops(sac, saccadeStops, 1) * seeds.lookX * amplitude,
                      stops(sac, saccadeStops, 2) * seeds.lookY * amplitude),
            rockp: rockp,
            blink: blink,
            wrap: (mx: stops(sac, wrapStops, 1) * seeds.lookMX * amplitude,
                   side: stops(sac, wrapStops, 2) * seeds.lookX * amplitude,
                   sy: stops(sac, wrapStops, 3) * seeds.lookMY * amplitude,
                   rot: stops(sac, wrapStops, 4) * seeds.lookX * seeds.lookY * amplitude))
    }

    // MARK: - Loops

    private static func cycle(_ time: Double, _ phase: Double, _ period: Double) -> Double {
        let u = (time + phase) / period
        return u - u.rounded(.down)
    }

    private static func alternate(_ time: Double, _ phase: Double, _ period: Double) -> Double {
        let u = (time + phase) / period
        let n = u.rounded(.down)
        let f = u - n
        return n.truncatingRemainder(dividingBy: 2) == 1 ? 1 - f : f
    }

    private static func stops(_ u: Double, _ table: [[Double]], _ column: Int) -> Double {
        var index = table.count - 1
        while index >= 0 {
            let row = table[index]
            if u < row[0] {
                index -= 1
                continue
            }
            guard index + 1 < table.count else { return row[column] }
            let next = table[index + 1]
            let span = next[0] - row[0]
            return span <= 0
                ? row[column]
                : row[column] + (next[column] - row[column]) * ((u - row[0]) / span)
        }
        return table[0][column]
    }

    // MARK: - Timing functions

    /// Cubic-bezier solver, matching the `bezier()` helper in the original.
    /// Shared with the view's morph timing.
    static func bezier(_ x1: Double, _ y1: Double,
                       _ x2: Double, _ y2: Double,
                       _ x: Double) -> Double {
        let cx = 3 * x1
        let bx = 3 * (x2 - x1) - cx
        let ax = 1 - cx - bx
        let cy = 3 * y1
        let by = 3 * (y2 - y1) - cy
        let ay = 1 - cy - by

        var t = x
        for _ in 0..<8 {
            let error = ((ax * t + bx) * t + cx) * t - x
            if abs(error) < 1e-5 { break }
            let derivative = (3 * ax * t + 2 * bx) * t + cx
            if abs(derivative) < 1e-6 { break }
            t -= error / derivative
        }
        return ((ay * t + by) * t + cy) * t
    }

    private static func easeInOut(_ x: Double) -> Double { bezier(0.42, 0, 0.58, 1, x) }
    private static func easeIn(_ x: Double) -> Double { bezier(0.42, 0, 1, 1, x) }
    private static func easeOut(_ x: Double) -> Double { bezier(0, 0, 0.58, 1, x) }
}

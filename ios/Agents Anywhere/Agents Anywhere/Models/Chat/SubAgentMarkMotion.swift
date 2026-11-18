//
//  SubAgentMarkMotion.swift
//
//  The toolbar mark's idle motion: the blobatar idle layer's blink and
//  saccade, re-expressed for the mark's 24-unit viewBox.
//
//  Blobatar was ported on 2026-11-17 and deleted the same day (the
//  new-session avatar became the official logo style), but pp kept its eye
//  animation as the reference for the SubAgent mark (2026-11-18): the eyes
//  close for the last 2.8 % of each loop — 92 % of the way, ease-in then
//  ease-out — and glance through six held fixations joined by 1.5 % flicks.
//  Everything here is a pure function of time so the canvas can sample it at
//  60 fps without publishing state, and so the numbers stay unit-testable
//  without a view.
//

import Foundation

/// One mark's idle clocks and amplitudes. All times are milliseconds, all
/// offsets are in the mark's own 24-unit design space.
nonisolated struct SubAgentMarkMotion: Equatable, Sendable {
    /// Blink loop. Blobatar drew 3.5–6.5 s per seed; a single fixed period
    /// keeps the toolbar calm and the tests deterministic.
    var blinkPeriod: Double = 4_200
    /// Saccade loop (blobatar: 4.2–7.6 s per seed). Both clocks start at
    /// their table's opening pose — the eyes are open and centred at t = 0 —
    /// so a fresh mark never enters mid-blink or mid-glance.
    var saccadePeriod: Double = 5_600
    /// Glance travel in design units. Blobatar moved its eyes ~1.5 % of a
    /// 100-unit face; at 24 units that is invisible in a 22 pt toolbar mark,
    /// so the travel is raised to ~4 % of the badge — the smallest amplitude
    /// that still reads as a glance at @3x.
    var glanceX: Double = 0.9
    var glanceY: Double = 0.5

    /// The mark's eyes at one instant.
    struct Frame: Equatable, Sendable {
        /// 1 = open eyelid, 0.08 = fully closed (blobatar's 92 % closure is
        /// applied to the eye's own span, so the stroke never vanishes).
        var blink: Double = 1
        var eyeOffset: Offset = .zero

        /// The pose with motion off (Reduce Motion).
        static let still = Frame()
    }

    struct Offset: Equatable, Sendable {
        var x: Double
        var y: Double
        static let zero = Offset(x: 0, y: 0)
    }

    func frame(at time: Double) -> Frame {
        Frame(blink: blink(at: time), eyeOffset: saccade(at: time))
    }

    /// `BlobatarIdle.frame`'s blink column, with amplitude fixed at 1.
    func blink(at time: Double) -> Double {
        let b = Self.cycle(time, blinkPeriod)
        if b < 0.972 { return 1 }
        if b < 0.986 {
            return 1 - 0.92 * Self.easeIn((b - 0.972) / 0.014)
        }
        return 1 - 0.92 * (1 - Self.easeOut((b - 0.986) / 0.014))
    }

    /// `BlobatarIdle.frame`'s saccade column. The table is the original
    /// six-fixation cycle verbatim; the amplitudes are this mark's own.
    func saccade(at time: Double) -> Offset {
        let u = Self.cycle(time, saccadePeriod)
        return Offset(x: Self.stops(u, Self.saccadeStops, 1) * glanceX,
                      y: Self.stops(u, Self.saccadeStops, 2) * glanceY)
    }

    // MARK: - Tables

    /// The saccade's six fixations: held, then moved to in a single 1.5 %
    /// flick (blobatar 2.8.0, MIT).
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

    // MARK: - Loops

    private static func cycle(_ time: Double, _ period: Double) -> Double {
        let u = time / period
        return u - u.rounded(.down)
    }

    /// Linear interpolation through a `[u, x, y, …]` stop table.
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

    /// Cubic-bezier solver, matching blobatar's `bezier()` helper.
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

    private static func easeIn(_ x: Double) -> Double { bezier(0.42, 0, 1, 1, x) }
    private static func easeOut(_ x: Double) -> Double { bezier(0, 0, 0.58, 1, x) }
}

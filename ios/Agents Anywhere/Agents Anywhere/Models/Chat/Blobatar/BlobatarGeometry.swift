//
//  BlobatarGeometry.swift
//
//  Ported from blobatar 2.8.0 (https://github.com/Alain00/blobatar),
//  MIT License. Copyright (c) 2026 Alain.
//
//  The four path primitives the silhouette vocabulary is built from. Each one
//  emits the same SVG `d` string the original emits — the string is what the
//  golden fixture compares — and an absolute command list the view turns into
//  a `Path`, from one construction pass so the two cannot drift.
//

import Foundation

enum BlobatarPathCommand {
    case move(Double, Double)
    case line(Double, Double)
    case quad(Double, Double, Double, Double)
    case curve(Double, Double, Double, Double, Double, Double)
    case close
}

struct BlobatarPath {
    let d: String
    let commands: [BlobatarPathCommand]
}

struct BlobatarPathBuilder {
    private var parts: [String] = []
    private var commands: [BlobatarPathCommand] = []
    private var current: (x: Double, y: Double) = (0, 0)

    static func superellipse(cx: Double, cy: Double, rx: Double, ry: Double,
                             n: Double, rot: Double) -> BlobatarPath {
        // Above n≈5.55 the control offset exceeds the radius and the curve
        // bulges outside its bounds; clamping trades exactness at the 45° point
        // for a shape that always stays inside what it says it does.
        let k = min(1, (8 * pow(2, -1 / n) - 4) / 3)
        let ak = rx * k
        let bk = ry * k

        let points: [(Double, Double)] = [
            (rx, 0),
            (rx, bk), (ak, ry), (0, ry),
            (-ak, ry), (-rx, bk), (-rx, 0),
            (-rx, -bk), (-ak, -ry), (0, -ry),
            (ak, -ry), (rx, -bk), (rx, 0),
        ]

        let radians = rot * .pi / 180
        let cosValue = cos(radians)
        let sinValue = sin(radians)
        let at = { (index: Int) -> (Double, Double) in
            let (x, y) = points[index]
            return (cx + x * cosValue - y * sinValue, cy + x * sinValue + y * cosValue)
        }

        var builder = BlobatarPathBuilder()
        builder.move(at(0).0, at(0).1)
        var index = 1
        while index < 13 {
            let first = at(index)
            let second = at(index + 1)
            let third = at(index + 2)
            builder.curve(first.0, first.1, second.0, second.1, third.0, third.1)
            index += 3
        }
        builder.close()
        return builder.build()
    }

    /// An organic closed curve: radii sampled around a circle, joined by a
    /// closed Catmull-Rom spline converted to cubic Béziers.
    static func blob(cx: Double, cy: Double, rx: Double, ry: Double,
                     radii: [Double], rot: Double) -> BlobatarPath {
        let count = radii.count
        let start = rot * .pi / 180
        let points: [(Double, Double)] = radii.enumerated().map { index, multiplier in
            let angle = start + 2 * .pi * Double(index) / Double(count)
            return (cx + rx * multiplier * cos(angle), cy + ry * multiplier * sin(angle))
        }

        let at = { (index: Int) -> (Double, Double) in
            points[((index % count) + count) % count]
        }

        var builder = BlobatarPathBuilder()
        builder.move(at(0).0, at(0).1)
        for index in 0..<count {
            let (x0, y0) = at(index - 1)
            let (x1, y1) = at(index)
            let (x2, y2) = at(index + 1)
            let (x3, y3) = at(index + 2)
            builder.curve(x1 + (x2 - x0) / 6, y1 + (y2 - y0) / 6,
                          x2 - (x3 - x1) / 6, y2 - (y3 - y1) / 6,
                          x2, y2)
        }
        builder.close()
        return builder.build()
    }

    /// A regular polygon with rounded corners. Corners are cut back along both
    /// adjoining edges and joined with a quadratic through the vertex.
    static func polygon(cx: Double, cy: Double, rx: Double, ry: Double,
                        sides: Int, round: Double, rot: Double) -> BlobatarPath {
        let k = round > 0 ? (round < 1 ? round / 2 : 0.5) : 0
        let start = rot * .pi / 180 - .pi / 2
        let vertices: [(Double, Double)] = (0..<sides).map { index in
            let angle = start + 2 * .pi * Double(index) / Double(sides)
            return (cx + rx * cos(angle), cy + ry * sin(angle))
        }
        let at = { (index: Int) -> (Double, Double) in
            vertices[((index % sides) + sides) % sides]
        }
        let cut = { (i: Int, j: Int) -> (Double, Double) in
            let (x0, y0) = at(i)
            let (x1, y1) = at(j)
            return (x0 + (x1 - x0) * k, y0 + (y1 - y0) * k)
        }

        var builder = BlobatarPathBuilder()
        builder.move(cut(0, -1))
        for index in 0..<sides {
            let vertex = at(index)
            builder.quad(vertex.0, vertex.1, cut(index, index + 1))
            if k < 0.5 {
                builder.line(cut(index + 1, index))
            }
        }
        builder.close()
        return builder.build()
    }

    /// The straight run of a capsule, as a plain box. Drawn with the two cap
    /// circles the capsule already decorates with, the union is an exact stadium.
    static func box(cx: Double, cy: Double, rx: Double, ry: Double) -> BlobatarPath {
        var builder = BlobatarPathBuilder()
        builder.move(cx - rx, cy - ry)
        builder.horizontal(cx + rx)
        builder.vertical(cy + ry)
        builder.horizontal(cx - rx)
        builder.close()
        return builder.build()
    }

    /// The two tangents from an apex to the body ellipse, eased through the apex.
    static func taper(cx: Double, cy: Double, rx: Double, ry: Double, tip: Double) -> BlobatarPath {
        let t = max(1.05, tip)
        let tx = rx * (1 - 1 / (t * t)).squareRoot()
        let ty = cy - ry / t
        let apex = cy - t * ry
        let px = tx * 0.14
        let py = ty + 0.86 * (apex - ty)

        var builder = BlobatarPathBuilder()
        builder.move(cx - tx, ty)
        builder.line(cx - px, py)
        builder.quad(cx, apex, cx + px, py)
        builder.line(cx + tx, ty)
        builder.close()
        return builder.build()
    }

    // MARK: - Assembly

    private mutating func append(_ command: String, _ x: Double, _ y: Double) {
        parts.append(command + Self.format(x) + " " + Self.format(y))
    }

    private mutating func move(_ x: Double, _ y: Double) {
        append("M", x, y)
        commands.append(.move(x, y))
        current = (x, y)
    }

    private mutating func move(_ point: (Double, Double)) {
        move(point.0, point.1)
    }

    private mutating func line(_ point: (Double, Double)) {
        line(point.0, point.1)
    }

    private mutating func line(_ x: Double, _ y: Double) {
        append("L", x, y)
        commands.append(.line(x, y))
        current = (x, y)
    }

    private mutating func horizontal(_ x: Double) {
        parts.append("H" + Self.format(x))
        commands.append(.line(x, current.y))
        current = (x, current.y)
    }

    private mutating func vertical(_ y: Double) {
        parts.append("V" + Self.format(y))
        commands.append(.line(current.x, y))
        current = (current.x, y)
    }

    private mutating func quad(_ cx: Double, _ cy: Double, _ end: (Double, Double)) {
        quad(cx, cy, end.0, end.1)
    }

    private mutating func quad(_ cx: Double, _ cy: Double, _ x: Double, _ y: Double) {
        parts.append("Q" + Self.format(cx) + " " + Self.format(cy)
                     + " " + Self.format(x) + " " + Self.format(y))
        commands.append(.quad(cx, cy, x, y))
        current = (x, y)
    }

    private mutating func curve(_ x1: Double, _ y1: Double,
                                _ x2: Double, _ y2: Double,
                                _ x: Double, _ y: Double) {
        parts.append("C" + Self.format(x1) + " " + Self.format(y1)
                     + " " + Self.format(x2) + " " + Self.format(y2)
                     + " " + Self.format(x) + " " + Self.format(y))
        commands.append(.curve(x1, y1, x2, y2, x, y))
        current = (x, y)
    }

    private mutating func close() {
        parts.append("Z")
        commands.append(.close)
    }

    private func build() -> BlobatarPath {
        BlobatarPath(d: parts.joined(), commands: commands)
    }

    /// JavaScript `Math.round(v * 100) / 100`, printed the way `String(number)`
    /// prints it: no trailing zeros, and `-0` comes out as `0`.
    static func format(_ value: Double) -> String {
        let rounded = (value * 100 + 0.5).rounded(.down) / 100
        if rounded == 0 { return "0" }
        if rounded == rounded.rounded(.towardZero) && abs(rounded) < 1e15 {
            return String(Int(rounded))
        }
        var text = String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), rounded)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }
}

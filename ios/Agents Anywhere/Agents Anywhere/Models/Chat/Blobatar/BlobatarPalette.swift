//
//  BlobatarPalette.swift
//
//  Ported from blobatar 2.8.0 (https://github.com/Alain00/blobatar),
//  MIT License. Copyright (c) 2026 Alain.
//
//  OKLCh palette with the same contrast guarantees as the original: the head
//  clears 1.5:1 against a near-black surface, 1.25:1 against its own plate, and
//  the eyes clear 4.5:1 against the head. The seed picks hue and one of six
//  authored tones; nothing else roams.
//

import Foundation

struct BlobatarOklch {
    var l: Double
    var c: Double
    var h: Double
}

struct BlobatarPalette {
    var bg: String
    var head: String
    var eye: String
}

struct BlobatarTint {
    /// Hue the body arrives at, in degrees.
    var h: Double
    /// Lightness it heads toward.
    var l: Double
    /// How far of the way to `l` the body actually travels, 0–1.
    var pull: Double
    /// Chroma floor.
    var c: Double
}

enum BlobatarColor {
    static let hot = BlobatarTint(h: 27, l: 0.58, pull: 0.6, c: 0.18)
    static let rose = BlobatarTint(h: 358, l: 0.72, pull: 0.55, c: 0.16)
    static let blush = BlobatarTint(h: 12, l: 0.84, pull: 0.4, c: 0.1)
    static let bile = BlobatarTint(h: 142, l: 0.66, pull: 0.6, c: 0.13)

    /// A hair over the 4.5:1 the suite asserts, for 8-bit quantisation.
    private static let tintFloor = 4.55
    private static let surfaceFloor = 1.5
    private static let darkSurface = BlobatarOklch(l: 0.145, c: 0, h: 0)

    /// Cumulative tone swatches: pale and mid dominate, near-black stays a find.
    private static let tones: [(edge: Double, l: Double, c: Double)] = [
        (0.2, 0.86, 0.085),
        (0.36, 0.9, 0.028),
        (0.62, 0.73, 0.135),
        (0.8, 0.62, 0.165),
        (0.93, 0.87, 0.16),
        (1.0, 0.34, 0.035),
    ]

    // MARK: - Palette

    static func palette(hue: Double, tone: Double) -> BlobatarPalette {
        let swatch = toneAt(tone)
        var head = ensureContrast(BlobatarOklch(l: swatch.l, c: swatch.c, h: hue),
                                  darkSurface, surfaceFloor)
        let bg = BlobatarOklch(l: 0.965, c: 0.01, h: hue)
        var eye = head.l >= 0.5
            ? BlobatarOklch(l: 0.17, c: 0.02, h: hue)
            : BlobatarOklch(l: 0.97, c: 0.012, h: hue)
        // Floors in declaration order: later pairs resolve against the already
        // final earlier colours, which is what makes the chain converge.
        head = ensureContrast(head, bg, 1.25)
        eye = ensureContrast(eye, head, 4.5)
        return BlobatarPalette(bg: toHex(bg), head: toHex(head), eye: toHex(eye))
    }

    private static func toneAt(_ value: Double) -> (l: Double, c: Double) {
        for swatch in tones where value < swatch.edge {
            return (swatch.l, swatch.c)
        }
        return (tones[0].l, tones[0].c)
    }

    // MARK: - Tinting poses

    /// The pair a tinting pose wears, walking the mix so every point on the way
    /// clears the eye/head floor, not just the endpoints.
    static func tinted(head: String, eye: String, tint: BlobatarTint) -> (head: String, eye: String) {
        let base = fromHex(head)
        let baseEye = fromHex(eye)

        var hotHead = BlobatarOklch(l: base.l + (tint.l - base.l) * tint.pull,
                                    c: max(base.c, tint.c),
                                    h: tint.h)
        hotHead = ensureContrast(hotHead, darkSurface, surfaceFloor)

        var hotEye = ensureContrast(baseEye, hotHead, tintFloor)

        let direction = hotEye.l >= hotHead.l ? 1.0 : -1.0
        let headHex = toHex(hotHead)
        for _ in 0..<40 {
            let eyeHex = toHex(hotEye)
            var worst = Double.infinity
            for i in 0...10 {
                let t = Double(i) / 10
                worst = min(worst, contrast(fromHex(mixHex(eye, eyeHex, t)),
                                            fromHex(mixHex(head, headHex, t))))
            }
            if worst >= tintFloor { return (headHex, eyeHex) }
            let l = min(1, max(0, hotEye.l + direction * 0.02))
            if l == hotEye.l { return (headHex, eyeHex) }
            hotEye.l = l
        }
        return (headHex, toHex(hotEye))
    }

    /// The resolved palette mixed `heat` of the way toward the tinted pair.
    static func tinted(_ palette: BlobatarPalette, heat: Double, tint: BlobatarTint) -> BlobatarPalette {
        let pair = tinted(head: palette.head, eye: palette.eye, tint: tint)
        return BlobatarPalette(bg: palette.bg,
                               head: mixHex(palette.head, pair.head, heat),
                               eye: mixHex(palette.eye, pair.eye, heat))
    }

    // MARK: - Colour space

    /// OKLCh → linear-light sRGB. Components may fall outside [0, 1].
    private static func toLinear(_ color: BlobatarOklch) -> (Double, Double, Double) {
        let radians = color.h * .pi / 180
        let a = color.c * cos(radians)
        let b = color.c * sin(radians)

        let lPrime = color.l + 0.3963377774 * a + 0.2158037573 * b
        let mPrime = color.l - 0.1055613458 * a - 0.0638541728 * b
        let sPrime = color.l - 0.0894841775 * a - 1.291485548 * b

        let l = lPrime * lPrime * lPrime
        let m = mPrime * mPrime * mPrime
        let s = sPrime * sPrime * sPrime

        return (
            4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
            -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
            -0.0041960863 * l - 0.7034186147 * m + 1.707614701 * s
        )
    }

    private static func inGamut(_ rgb: (Double, Double, Double)) -> Bool {
        let values = [rgb.0, rgb.1, rgb.2]
        return values.allSatisfy { $0 >= -1e-4 && $0 <= 1 + 1e-4 }
    }

    /// In-gamut linear sRGB, giving up chroma rather than clipping channels.
    private static func resolve(_ color: BlobatarOklch) -> (Double, Double, Double) {
        var rgb = toLinear(color)
        if !inGamut(rgb) {
            var low = 0.0
            var high = color.c
            for _ in 0..<12 {
                let mid = (low + high) / 2
                if inGamut(toLinear(BlobatarOklch(l: color.l, c: mid, h: color.h))) {
                    low = mid
                } else {
                    high = mid
                }
            }
            rgb = toLinear(BlobatarOklch(l: color.l, c: low, h: color.h))
        }
        return (min(1, max(0, rgb.0)), min(1, max(0, rgb.1)), min(1, max(0, rgb.2)))
    }

    /// WCAG relative luminance; `resolve` already returns linear-light sRGB.
    private static func luminance(_ color: BlobatarOklch) -> Double {
        let rgb = resolve(color)
        return 0.2126 * rgb.0 + 0.7152 * rgb.1 + 0.0722 * rgb.2
    }

    static func contrast(_ a: BlobatarOklch, _ b: BlobatarOklch) -> Double {
        let x = luminance(a)
        let y = luminance(b)
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    /// Pushes `fg`'s lightness away from `bg` until the pair clears `min`.
    private static func ensureContrast(_ fg: BlobatarOklch,
                                       _ bg: BlobatarOklch,
                                       _ minimum: Double) -> BlobatarOklch {
        if contrast(fg, bg) >= minimum { return fg }

        let lean = fg.l >= bg.l ? 1.0 : -1.0
        for direction in [lean, -lean] {
            var probe = fg
            for _ in 0..<60 {
                probe.l = min(1, max(0, probe.l + direction * 0.02))
                if contrast(probe, bg) >= minimum { return probe }
                if probe.l == 0 || probe.l == 1 { break }
            }
        }

        let black = BlobatarOklch(l: 0, c: 0, h: fg.h)
        let white = BlobatarOklch(l: 1, c: 0, h: fg.h)
        return contrast(black, bg) >= contrast(white, bg) ? black : white
    }

    static func toHex(_ color: BlobatarOklch) -> String {
        let rgb = resolve(color)
        let channels = [rgb.0, rgb.1, rgb.2].map { value -> Int in
            let s = value <= 0.0031308 ? 12.92 * value : 1.055 * pow(value, 1 / 2.4) - 0.055
            return Int(jsRound(s * 255))
        }
        return "#" + channels.map { String(format: "%02x", max(0, min(255, $0))) }.joined()
    }

    /// sRGB hex → OKLCh. Needed by the tint walk, which starts from the colours
    /// actually on screen rather than from the ramp that produced them.
    static func fromHex(_ hex: String) -> BlobatarOklch {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        let value = Int(digits, radix: 16) ?? 0
        let r = linearChannel(Double((value >> 16) & 255) / 255)
        let g = linearChannel(Double((value >> 8) & 255) / 255)
        let b = linearChannel(Double(value & 255) / 255)

        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)

        let a = 1.9779984951 * l - 2.428592205 * m + 0.4505937099 * s
        let bb = 0.0259040371 * l + 0.7827717662 * m - 0.808675766 * s

        return BlobatarOklch(l: 0.2104542553 * l + 0.793617785 * m - 0.0040720468 * s,
                             c: (a * a + bb * bb).squareRoot(),
                             h: atan2(bb, a) * 180 / .pi)
    }

    private static func linearChannel(_ value: Double) -> Double {
        value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }

    /// OKLab blend of two colours, matching `color-mix(in oklab, …)`.
    private static func mix(_ a: BlobatarOklch, _ b: BlobatarOklch, _ t: Double) -> BlobatarOklch {
        let radians = { (v: Double) in v * .pi / 180 }
        let ax = a.c * cos(radians(a.h))
        let ay = a.c * sin(radians(a.h))
        let bx = b.c * cos(radians(b.h))
        let by = b.c * sin(radians(b.h))
        let x = ax + (bx - ax) * t
        let y = ay + (by - ay) * t
        return BlobatarOklch(l: a.l + (b.l - a.l) * t,
                             c: (x * x + y * y).squareRoot(),
                             h: atan2(y, x) * 180 / .pi)
    }

    static func mixHex(_ a: String, _ b: String, _ t: Double) -> String {
        toHex(mix(fromHex(a), fromHex(b), t))
    }

    /// sRGB channel walk, matching the web's `transition: fill`. A morph's
    /// colour travels in sRGB there, so a substrate with no transitions has to
    /// reproduce sRGB rather than OKLab to stay on the same path.
    static func fadeHex(_ a: String, _ b: String, _ t: Double) -> String {
        let from = Int(a.dropFirst(), radix: 16) ?? 0
        let to = Int(b.dropFirst(), radix: 16) ?? 0
        var out = "#"
        for shift in [16, 8, 0] {
            let start = Double((from >> shift) & 255)
            let end = Double((to >> shift) & 255)
            let value = Int(jsRound(start + (end - start) * t))
            out += String(format: "%02x", max(0, min(255, value)))
        }
        return out
    }

    /// JavaScript `Math.round`: halves go toward +∞, so −0.5 rounds to −0.
    private static func jsRound(_ value: Double) -> Double {
        (value + 0.5).rounded(.down)
    }
}

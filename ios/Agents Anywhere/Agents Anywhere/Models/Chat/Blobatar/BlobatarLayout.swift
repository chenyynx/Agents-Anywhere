//
//  BlobatarLayout.swift
//
//  Ported from blobatar 2.8.0 (https://github.com/Alain00/blobatar),
//  MIT License. Copyright (c) 2026 Alain.
//
//  Body + face composition: picks the silhouette, builds the body, fits the eye
//  cluster inside the silhouette's safe region, and resolves the palette.
//

import Foundation

struct BlobatarEye {
    var cx: Double
    var cy: Double
    var rx: Double
    var ry: Double
    var n: Double
    var rot: Double
}

struct BlobatarLayout {
    var shapeName: String
    var body: BlobatarBody
    var face: BlobatarEllipse
    var petals: [BlobatarPetal]
    var extras: [BlobatarPath]
    var eyes: [BlobatarEye]
    var bodyPath: BlobatarPath
    var palette: BlobatarPalette
}

enum BlobatarComposer {
    static func layout(seed: String) -> BlobatarLayout {
        let traits = BlobatarTraits(seed: seed)
        let shape = pick(traits.value("shape"))

        let radius = traits.num("body.r", 31, 38) * shape.core
        var body = BlobatarBody(
            cx: 50 + traits.jitter("body.x", 1.5),
            cy: 50 + traits.jitter("body.y", 1.5),
            rx: radius,
            ry: radius * traits.num("body.ratio", 0.92, 1.08),
            n: traits.num("body.n", 1.9, 2.5),
            rot: 0,
            radii: (0..<traits.int("body.pts", 6, 8)).map { index in
                1 + traits.jitter("body.r\(index)", 0.16)
            })
        shape.body?(traits, &body)

        let face = shape.face?(body)
            ?? BlobatarEllipse(cx: body.cx, cy: body.cy, rx: body.rx, ry: body.ry)

        var deco = BlobatarDeco()
        shape.decorate?(traits, body, &deco)

        let eyes = faceFit(traits, body: body, face: face)
        let path = shape.path?(body)
            ?? BlobatarPathBuilder.superellipse(cx: body.cx, cy: body.cy,
                                                rx: body.rx, ry: body.ry,
                                                n: body.n, rot: body.rot)
        let palette = BlobatarColor.palette(hue: traits.num("hue", 0, 360),
                                            tone: traits.value("tone"))

        return BlobatarLayout(shapeName: shape.name,
                              body: body,
                              face: face,
                              petals: deco.petals,
                              extras: deco.extra,
                              eyes: eyes,
                              bodyPath: path,
                              palette: palette)
    }

    private static func pick(_ value: Double) -> BlobatarShape {
        for band in BlobatarShapes.bands where value < band.upTo {
            return band.shape
        }
        return BlobatarShapes.triangle
    }

    /// Fits the eye cluster against the silhouette's face region on both axes.
    private static func faceFit(_ traits: BlobatarTraits,
                                body: BlobatarBody,
                                face: BlobatarEllipse) -> [BlobatarEye] {
        let rx = body.rx
        let base = traits.num("eye.rx", 0.075, 0.105) * rx
        let ratio = traits.num("eye.ratio", 1.9, 3.2)
        let scale = traits.num("eye.scale", 0.78, 1.24)
        let stretch = traits.num("eye.stretch", 0.85, 1.18)
        let clearance = traits.num("eye.gap", 0.1, 0.24) * rx

        let wide = base * max(1, scale)
        let tall = base * ratio * max(1, scale * stretch)
        let gap0 = wide + rx * 0.03 + clearance

        let gazeX = traits.jitter("gaze.x", 0.09) * face.rx
        let gazeY = traits.num("gaze.y", -0.2, 0.08) * face.ry
        let dy = traits.jitter("eye.dy", 0.04) * face.ry

        let reach = (wide * wide + tall * tall).squareRoot()
        let needX = (abs(gazeX) + gap0 + reach) / face.rx
        let needY = (abs(gazeY) + abs(dy) + reach) / face.ry
        let need = (needX * needX + needY * needY).squareRoot()
        let fit = need > 0.9 ? 0.9 / need : 1

        let er = base * fit
        let eyeRy = er * ratio
        let gap = gap0 * fit

        let room = max(0, min(1, clearance / tall))
        let bound = min(12, asin(room) * 180 / .pi)
        let lean = traits.num("eye.lean", -1, 1) * bound
        let lean2 = max(-12, min(12, lean + traits.jitter("eye.lean2", 3.5)))

        let cx = face.cx + gazeX * fit
        let cy = face.cy + gazeY * fit
        let n = traits.num("eye.n", 3.5, 6)

        return [
            BlobatarEye(cx: cx - gap, cy: cy, rx: er, ry: eyeRy, n: n, rot: lean),
            BlobatarEye(cx: cx + gap, cy: cy + dy * fit,
                        rx: er * scale, ry: eyeRy * scale * stretch, n: n, rot: lean2),
        ]
    }
}

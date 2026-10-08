import SwiftUI

/// The capsule's dynamic mark: a small page whose magnifier (侦察) and pencil
/// (写入) stages cross-fade on one loop. The two stages are tinted along a
/// scout→write ramp, or (with `phase == nil`) cycle through both on their own.
///
/// The phase comes from `SubAgentGlyphPhase` — a name-table classification of
/// the running SubAgent's recent tool calls — and is deliberately independent
/// of the card's lifecycle `SubAgentPhase`. `overrideColor` lets the capsule
/// repaint the whole mark (page, lines, lens, pencil) in a single colour
/// without stopping the phase loop, which is how the failure state reads red.
///
/// Drawn in `Canvas` rather than with an SF Symbol: the mark needs three
/// co-ordinated animations (a lens that lifts and travels, lines that recede,
/// a pencil that appears and writes) that no symbol can carry.
struct SubAgentGlyph: View {
    /// The phase to show; `nil` cycles both stages (the default while the
    /// phase is unknown, or with several SubAgents running).
    var phase: SubAgentGlyphPhase? = nil
    /// The square the mark is drawn into, in points.
    var size: CGFloat = 24
    /// Repaints the whole mark in one colour (phase animation still runs).
    /// The capsule passes the failure red so a failed batch reads red.
    var overrideColor: Color? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    /// The moment the mark first appeared: the animation is anchored here, so
    /// its first frame always starts from the same phase instead of an
    /// arbitrary point of the absolute clock. Identity stays stable across
    /// label/count changes, so the loop is not restarted mid-run.
    @State private var start = Date()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { timeline in
            let elapsed = timeline.date.timeIntervalSince(start)
            let state = reduceMotion ? GlyphState.still : GlyphState.at(time: elapsed, phase: phase)
            let tint = overrideColor ?? GlyphPalette.color(blend: state.blend, scheme: scheme)
            Canvas { context, canvasSize in
                context.scaleBy(x: canvasSize.width / 24, y: canvasSize.height / 24)
                draw(&context, state: state, tint: tint)
            }
        }
        .frame(width: size, height: size)
        .onAppear { start = Date() }
        .accessibilityHidden(true)
    }

    private var stroke: StrokeStyle { StrokeStyle(lineWidth: 1.75, lineCap: .round, lineJoin: .round) }

    private func draw(_ context: inout GraphicsContext, state s: GlyphState, tint: Color) {
        context.drawLayer { layer in
            layer.stroke(Path(roundedRect: CGRect(x: 4, y: 4, width: 13, height: 17), cornerRadius: 2.5), with: .color(tint), style: stroke)
            for (i, y) in [9.0, 13.0, 17.0].enumerated() {
                let p = s.lines[i]; guard p > 0.01 else { continue }
                var line = Path(); line.move(to: CGPoint(x: 7.5, y: y)); line.addLine(to: CGPoint(x: 7.5 + 5.5 * p, y: y))
                layer.stroke(line, with: .color(tint.opacity(0.55)), style: stroke)
            }
            if s.lensOpacity > 0.01 { drawLens(&layer, at: s.lens, opacity: s.lensOpacity, tint: tint) }
            if s.penOpacity > 0.01 { drawPencil(&layer, tip: s.pen, opacity: s.penOpacity, tint: tint) }
        }
    }

    private func drawLens(_ g: inout GraphicsContext, at c: CGPoint, opacity: Double, tint: Color) {
        let ring = Path(ellipseIn: CGRect(x: c.x - 3.6, y: c.y - 3.6, width: 7.2, height: 7.2))
        let halo = Path(ellipseIn: CGRect(x: c.x - 4.9, y: c.y - 4.9, width: 9.8, height: 9.8))
        var handle = Path(); handle.move(to: CGPoint(x: c.x + 2.6, y: c.y + 2.6)); handle.addLine(to: CGPoint(x: c.x + 5.4, y: c.y + 5.4))
        g.blendMode = .destinationOut
        g.stroke(halo, with: .color(.black.opacity(opacity)), style: StrokeStyle(lineWidth: 2, lineCap: .round))
        g.stroke(handle, with: .color(.black.opacity(opacity)), style: StrokeStyle(lineWidth: 3.6, lineCap: .round))
        g.blendMode = .normal
        g.stroke(ring, with: .color(tint.opacity(opacity)), style: stroke)
        g.stroke(handle, with: .color(tint.opacity(opacity)), style: stroke)
    }

    private func drawPencil(_ g: inout GraphicsContext, tip: CGPoint, opacity: Double, tint: Color) {
        var body = Path()
        body.move(to: CGPoint(x: 4, y: 20)); body.addLine(to: CGPoint(x: 8, y: 20)); body.addLine(to: CGPoint(x: 18.5, y: 9.5))
        let center = CGPoint(x: 16.5, y: 7.5); let r = 2.828
        // A quarter-round tip, hand-fanned at 10° steps. Kept as a stride (not
        // Path.addArc) so the tip's vertices stay byte-identical to the design
        // source — an arc substitute could shift the silhouette by a pixel.
        for deg in stride(from: 45.0, through: -135.0, by: -10.0) {
            let a = deg * .pi / 180
            body.addLine(to: CGPoint(x: center.x + r * cos(a), y: center.y + r * sin(a)))
        }
        body.addLine(to: CGPoint(x: 4, y: 16)); body.closeSubpath()
        var band = Path(); band.move(to: CGPoint(x: 13.5, y: 6.5)); band.addLine(to: CGPoint(x: 17.5, y: 10.5))
        g.translateBy(x: tip.x, y: tip.y); g.scaleBy(x: 0.55, y: 0.55); g.translateBy(x: -4, y: -20)
        g.blendMode = .destinationOut
        let halo = StrokeStyle(lineWidth: 7.2, lineCap: .round, lineJoin: .round)
        g.stroke(body, with: .color(.black.opacity(opacity)), style: halo)
        g.stroke(band, with: .color(.black.opacity(opacity)), style: halo)
        g.blendMode = .normal
        let line = StrokeStyle(lineWidth: 3.18, lineCap: .round, lineJoin: .round)
        g.stroke(body, with: .color(tint.opacity(opacity)), style: line)
        g.stroke(band, with: .color(tint.opacity(opacity)), style: line)
    }
}

// MARK: - Geometry

/// A straight `#RRGGBB` colour with the blend helper the tint ramp needs.
private struct RGB {
    let r: Double, g: Double, b: Double
    init(_ hex: UInt32) {
        r = Double((hex >> 16) & 0xFF) / 255
        g = Double((hex >> 8) & 0xFF) / 255
        b = Double(hex & 0xFF) / 255
    }
    func mixed(with o: RGB, _ t: Double) -> Color {
        Color(red: r + (o.r - r) * t, green: g + (o.g - g) * t, blue: b + (o.b - b) * t)
    }
}

/// The scout→write tint ramp. The two endpoints differ per scheme so each stays
/// legible on its background (light values are the corrected, deeper pair).
private enum GlyphPalette {
    /// `blend` 0 = 侦察 (scout), 1 = 写入 (write).
    static func color(blend: Double, scheme: ColorScheme) -> Color {
        let scout = scheme == .dark ? RGB(0x7DA1D4) : RGB(0x4048BF)
        let write = scheme == .dark ? RGB(0xD4937D) : RGB(0xBF4060)
        return scout.mixed(with: write, blend)
    }
}

/// Keyframe pairs `(u, value)`; `lerp` walks them with an optional smoothstep.
private typealias Keys = [(Double, Double)]

private func lerp(_ u: Double, _ keys: Keys, eased: Bool = false) -> Double {
    guard let first = keys.first, let last = keys.last else { return 0 }
    if u <= first.0 { return first.1 }
    if u >= last.0 { return last.1 }
    for i in 1..<keys.count {
        let (u0, v0) = keys[i - 1]; let (u1, v1) = keys[i]
        if u <= u1 {
            var f = (u - u0) / (u1 - u0)
            if eased { f = f * f * (3 - 2 * f) }
            return v0 + (v1 - v0) * f
        }
    }
    return last.1
}

/// One frame's fully-resolved drawing state.
private struct GlyphState {
    var lensOpacity: Double; var lens: CGPoint
    var penOpacity: Double; var pen: CGPoint
    var lines: [Double]; var blend: Double

    /// The reduced-motion frame: lens centred, all three lines out, scout tint.
    static let still = GlyphState(lensOpacity: 1, lens: CGPoint(x: 11.5, y: 13), penOpacity: 0, pen: .zero, lines: [1, 1, 1], blend: 0)

    static func at(time t: Double, phase: SubAgentGlyphPhase?) -> GlyphState {
        switch phase {
        case .scouting?:
            let s = (t / 2.4).truncatingRemainder(dividingBy: 1)
            let x: Keys = [(0, 9), (0.25, 11.5), (0.5, 9), (0.75, 11.5), (1, 9)]
            let y: Keys = [(0, 9), (0.25, 13), (0.5, 17), (0.75, 13), (1, 9)]
            return GlyphState(lensOpacity: 1, lens: CGPoint(x: lerp(s, x, eased: true), y: lerp(s, y, eased: true)), penOpacity: 0, pen: .zero, lines: [1, 1, 1], blend: 0)
        case .writing?:
            let u = 0.48 + (t / 2.08).truncatingRemainder(dividingBy: 1) * 0.52
            var s = cycle(u); s.lensOpacity = 0; s.blend = 1; return s
        case nil:
            return cycle((t / 4).truncatingRemainder(dividingBy: 1))
        }
    }

    private static func cycle(_ u: Double) -> GlyphState {
        let lensX: Keys = [(0, 9), (0.16, 11.5), (0.32, 9), (0.46, 11.5), (0.50, 11.5), (0.98, 9), (1, 9)]
        let lensY: Keys = [(0, 9), (0.16, 13), (0.32, 17), (0.46, 13), (0.50, 13), (0.98, 9), (1, 9)]
        let lensO: Keys = [(0, 1), (0.46, 1), (0.50, 0), (0.98, 0), (1, 1)]
        let penO: Keys = [(0, 0), (0.50, 0), (0.52, 1), (0.96, 1), (0.98, 0), (1, 0)]
        let penX: Keys = [(0.50, 7.5), (0.54, 7.5), (0.66, 13), (0.67, 7.5), (0.78, 13), (0.79, 7.5), (0.90, 13), (1, 13)]
        let penY: Keys = [(0.50, 9), (0.66, 9), (0.67, 13), (0.78, 13), (0.79, 17), (1, 17)]
        let l1: Keys = [(0, 1), (0.48, 1), (0.52, 0), (0.54, 0), (0.66, 1), (1, 1)]
        let l2: Keys = [(0, 1), (0.48, 1), (0.52, 0), (0.66, 0), (0.78, 1), (1, 1)]
        let l3: Keys = [(0, 1), (0.48, 1), (0.52, 0), (0.78, 0), (0.90, 1), (1, 1)]
        let blend: Keys = [(0, 0), (0.44, 0), (0.52, 1), (0.92, 1), (1, 0)]
        return GlyphState(
            lensOpacity: lerp(u, lensO),
            lens: CGPoint(x: lerp(u, lensX, eased: true), y: lerp(u, lensY, eased: true)),
            penOpacity: lerp(u, penO),
            pen: CGPoint(x: lerp(u, penX), y: lerp(u, penY)),
            lines: [lerp(u, l1), lerp(u, l2), lerp(u, l3)],
            blend: lerp(u, blend, eased: true))
    }
}

#Preview("SubAgent glyph — light") {
    VStack(spacing: 28) {
        SubAgentGlyph(phase: nil)
        SubAgentGlyph(phase: nil)
        SubAgentGlyph(phase: .scouting)
        SubAgentGlyph(phase: .writing)
    }
    .padding(32)
    .preferredColorScheme(.light)
}

#Preview("SubAgent glyph — dark") {
    VStack(spacing: 28) {
        SubAgentGlyph(phase: nil)
        SubAgentGlyph(phase: nil)
        SubAgentGlyph(phase: .scouting)
        SubAgentGlyph(phase: .writing)
    }
    .padding(32)
    .preferredColorScheme(.dark)
    .background(Color.black)
}

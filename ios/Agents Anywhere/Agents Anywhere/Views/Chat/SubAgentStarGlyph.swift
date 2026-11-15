import SwiftUI

/// The capsule's mark: the star badge with two eyes, traced 1:1 from the
/// reference SVG (24-unit design space, 2pt stroke, round caps/joins).
///
/// Replaces the earlier animated page-and-lens mark inside the capsule
/// (pp 2026-11-15): the new mark is a flat single-colour outline, so there is
/// no phase loop to drive. The capsule still repaints it red while a live
/// failure is on screen.
struct SubAgentStarGlyph: View {
    /// The square the mark is drawn into, in points.
    var size: CGFloat = 16
    /// The mark is one stroke colour, the SVG's `currentColor`.
    var tint: Color = .primary

    var body: some View {
        Canvas { context, canvasSize in
            let scale = min(canvasSize.width, canvasSize.height) / 24
            context.scaleBy(x: scale, y: scale)
            let style = StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
            context.stroke(Self.star, with: .color(tint), style: style)
            context.stroke(Self.eyes, with: .color(tint), style: style)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    /// The badge outline, transcribed verbatim from the SVG's absolute
    /// `M`/`L`/`C` commands so the silhouette stays identical to the design
    /// source.
    private static let star: Path = {
        var p = Path()
        p.move(to: CGPoint(x: 12.532, y: 2.6252))
        p.addLine(to: CGPoint(x: 15.4508, y: 5.7091))
        p.addCurve(to: CGPoint(x: 16.0479, y: 6.0133),
                   control1: CGPoint(x: 15.6089, y: 5.8762),
                   control2: CGPoint(x: 15.8198, y: 5.9836))
        p.addLine(to: CGPoint(x: 20.2584, y: 6.562))
        p.addCurve(to: CGPoint(x: 22, y: 8.5453),
                   control1: CGPoint(x: 21.2547, y: 6.6919),
                   control2: CGPoint(x: 22, y: 7.5406))
        p.addCurve(to: CGPoint(x: 21.7564, y: 9.5019),
                   control1: CGPoint(x: 22, y: 8.8795),
                   control2: CGPoint(x: 21.9162, y: 9.2084))
        p.addLine(to: CGPoint(x: 19.7254, y: 13.2308))
        p.addCurve(to: CGPoint(x: 19.6035, y: 13.7092),
                   control1: CGPoint(x: 19.6454, y: 13.3776),
                   control2: CGPoint(x: 19.6035, y: 13.542))
        p.addCurve(to: CGPoint(x: 19.6205, y: 13.8927),
                   control1: CGPoint(x: 19.6035, y: 13.7707),
                   control2: CGPoint(x: 19.6092, y: 13.8322))
        p.addLine(to: CGPoint(x: 20.3998, y: 18.0667))
        p.addCurve(to: CGPoint(x: 20.4338, y: 18.4338),
                   control1: CGPoint(x: 20.4224, y: 18.1878),
                   control2: CGPoint(x: 20.4338, y: 18.3107))
        p.addCurve(to: CGPoint(x: 18.4338, y: 20.4338),
                   control1: CGPoint(x: 20.4338, y: 19.5384),
                   control2: CGPoint(x: 19.5384, y: 20.4338))
        p.addCurve(to: CGPoint(x: 18.0667, y: 20.3998),
                   control1: CGPoint(x: 18.3107, y: 20.4338),
                   control2: CGPoint(x: 18.1878, y: 20.4224))
        p.addLine(to: CGPoint(x: 13.8927, y: 19.6205))
        p.addCurve(to: CGPoint(x: 13.7092, y: 19.6035),
                   control1: CGPoint(x: 13.8322, y: 19.6092),
                   control2: CGPoint(x: 13.7707, y: 19.6035))
        p.addCurve(to: CGPoint(x: 13.2308, y: 19.7254),
                   control1: CGPoint(x: 13.542, y: 19.6035),
                   control2: CGPoint(x: 13.3776, y: 19.6454))
        p.addLine(to: CGPoint(x: 9.5019, y: 21.7564))
        p.addCurve(to: CGPoint(x: 8.5453, y: 22),
                   control1: CGPoint(x: 9.2084, y: 21.9162),
                   control2: CGPoint(x: 8.8795, y: 22))
        p.addCurve(to: CGPoint(x: 6.562, y: 20.2584),
                   control1: CGPoint(x: 7.5406, y: 22),
                   control2: CGPoint(x: 6.6919, y: 21.2547))
        p.addLine(to: CGPoint(x: 6.0133, y: 16.0479))
        p.addCurve(to: CGPoint(x: 5.7091, y: 15.4508),
                   control1: CGPoint(x: 5.9836, y: 15.8198),
                   control2: CGPoint(x: 5.8762, y: 15.6089))
        p.addLine(to: CGPoint(x: 2.6252, y: 12.532))
        p.addCurve(to: CGPoint(x: 2, y: 11.0794),
                   control1: CGPoint(x: 2.2261, y: 12.1542),
                   control2: CGPoint(x: 2, y: 11.6289))
        p.addCurve(to: CGPoint(x: 3.1414, y: 9.2731),
                   control1: CGPoint(x: 2, y: 10.3075),
                   control2: CGPoint(x: 2.4442, y: 9.6045))
        p.addLine(to: CGPoint(x: 6.9763, y: 7.4501))
        p.addCurve(to: CGPoint(x: 7.4501, y: 6.9763),
                   control1: CGPoint(x: 7.184, y: 7.3514),
                   control2: CGPoint(x: 7.3514, y: 7.184))
        p.addLine(to: CGPoint(x: 9.2731, y: 3.1414))
        p.addCurve(to: CGPoint(x: 11.0794, y: 2),
                   control1: CGPoint(x: 9.6045, y: 2.4442),
                   control2: CGPoint(x: 10.3075, y: 2))
        p.addCurve(to: CGPoint(x: 12.532, y: 2.6252),
                   control1: CGPoint(x: 11.6289, y: 2),
                   control2: CGPoint(x: 12.1542, y: 2.2261))
        p.closeSubpath()
        return p
    }()

    /// The two eyes, the same two short round-capped strokes as the source.
    private static let eyes: Path = {
        var p = Path()
        p.move(to: CGPoint(x: 11, y: 10.6028))
        p.addLine(to: CGPoint(x: 11.4521, y: 13.5685))
        p.move(to: CGPoint(x: 14.9543, y: 10))
        p.addLine(to: CGPoint(x: 15.4064, y: 12.9657))
        return p
    }()
}

#Preview("SubAgent star") {
    HStack(spacing: 24) {
        SubAgentStarGlyph(size: 16, tint: .primary)
        SubAgentStarGlyph(size: 16, tint: SubAgentPalette.failure)
        SubAgentStarGlyph(size: 32, tint: .primary)
    }
    .padding(32)
}

import SwiftUI

/// The visible call glow, drawn from the two official reference frames
/// (2026-11-23) rather than the raw 7-band shader:
/// - user: a wide bottom cloud that is already present at rest and drifts
///   toward the centre and upward as the voice rises;
/// - agent: an orange band that undulates along the left/right/bottom edges
///   while the assistant speaks, leaving the centre clear.
///
/// The base cloud is deliberately visible without audio (official frame at
/// 11:39), so this view does not gate on a level threshold.
struct VoiceAmbientGlow: View {
    var role: VoiceVisualizerRole
    var levelProvider: (() -> Float)?

    private let blue = Color(red: 0.42, green: 0.61, blue: 0.80)
    private let orange = Color(red: 0.851, green: 0.467, blue: 0.341)

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas(opaque: false, colorMode: .nonLinear, rendersAsynchronously: false) { context, size in
                let time = timeline.date.timeIntervalSinceReferenceDate
                let level = currentLevel(time: time)
                switch role {
                case .user:
                    drawUser(context: &context, size: size, time: time, level: level)
                case .agent:
                    drawAgent(context: &context, size: size, time: time, level: level)
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private func currentLevel(time: Double) -> Double {
        if let levelProvider {
            let bands = levelProvider()
            guard !bands.isEmpty else { return 0 }
            return Double(min(max(bands.reduce(0, +) / Float(bands.count), 0), 1))
        }
        // Lab fallback so the preview still breathes without a microphone.
        return 0.30 + 0.18 * sin(time * 1.35)
    }

    // MARK: - User: bottom cloud drifting up and inward

    private func drawUser(context: inout GraphicsContext, size: CGSize, time: Double, level: Double) {
        let w = size.width
        let h = size.height
        let lift = 0.20 * level

        // Wide base cloud: present at rest, top edge rises with the voice.
        let topY = h * (0.64 - lift)
        let base = CGRect(x: 0, y: topY, width: w, height: h - topY)
        context.fill(Path(base), with: .linearGradient(
            Gradient(stops: [
                .init(color: blue.opacity(0), location: 0),
                .init(color: blue.opacity(0.16 + 0.10 * level), location: 0.45),
                .init(color: blue.opacity(0.34 + 0.14 * level), location: 1)
            ]),
            startPoint: CGPoint(x: w / 2, y: topY),
            endPoint: CGPoint(x: w / 2, y: h)))

        // Five soft curtains; the outer ones slide toward the centre and the
        // whole set rises as the level grows.
        for index in 0..<5 {
            let fi = Double(index)
            let spread = 0.94 - 0.44 * level
            let x = w * (0.5 + (fi / 4 - 0.5) * spread)
            let bob = 0.015 * sin(time * 1.2 + fi * 1.7)
            let y = h * (0.86 - 0.30 * level + bob)
            let rx = w * (0.24 - 0.05 * level)
            let ry = h * (0.19 + 0.10 * level)
            let pulse = 0.8 + 0.2 * sin(time * 1.6 + fi * 1.3)
            let alpha = (0.045 + 0.075 * level) * pulse
            let rect = CGRect(x: x - rx, y: y - ry, width: rx * 2, height: ry * 2)
            context.fill(Path(ellipseIn: rect), with: .radialGradient(
                Gradient(stops: [
                    .init(color: blue.opacity(alpha), location: 0),
                    .init(color: blue.opacity(alpha * 0.5), location: 0.55),
                    .init(color: blue.opacity(0), location: 1)
                ]),
                center: CGPoint(x: x, y: y),
                startRadius: 0,
                endRadius: max(rx, ry)))
        }

        // Centre bloom that grows with the voice.
        let radius = w * (0.42 + 0.18 * level)
        let centre = CGPoint(x: w / 2, y: h * (0.78 - 0.18 * level))
        let bloom = 0.06 + 0.16 * level
        let bloomRect = CGRect(x: centre.x - radius, y: centre.y - radius,
                               width: radius * 2, height: radius * 2)
        context.fill(Path(ellipseIn: bloomRect), with: .radialGradient(
            Gradient(stops: [
                .init(color: blue.opacity(bloom), location: 0),
                .init(color: blue.opacity(bloom * 0.45), location: 0.6),
                .init(color: blue.opacity(0), location: 1)
            ]),
            center: centre,
            startRadius: 0,
            endRadius: radius))
    }

    // MARK: - Agent: border undulation

    private func drawAgent(context: inout GraphicsContext, size: CGSize, time: Double, level: Double) {
        let w = size.width
        let h = size.height
        let strength = 0.15 + 0.65 * level
        let edgeWidth = w * 0.18
        let slices = 36

        // Left and right edges, one thin horizontal slice at a time so the
        // alpha can travel down the border as a wave.
        for side in 0..<2 {
            let rectX: CGFloat = side == 0 ? 0 : w - edgeWidth
            for slice in 0..<slices {
                let y0 = h * CGFloat(slice) / CGFloat(slices)
                let y1 = h * CGFloat(slice + 1) / CGFloat(slices)
                let wave = 0.65 + 0.35 * sin(Double(y0) * 0.042 + time * 3.1 + Double(side) * 1.9 + level * 5)
                let alpha = strength * wave
                let rect = CGRect(x: rectX, y: y0, width: edgeWidth, height: y1 - y0 + 0.6)
                let start = side == 0 ? CGPoint(x: 0, y: 0) : CGPoint(x: w, y: 0)
                let end = side == 0 ? CGPoint(x: edgeWidth, y: 0) : CGPoint(x: w - edgeWidth, y: 0)
                context.fill(Path(rect), with: .linearGradient(
                    Gradient(stops: [
                        .init(color: orange.opacity(alpha), location: 0),
                        .init(color: orange.opacity(alpha * 0.45), location: 0.45),
                        .init(color: orange.opacity(0), location: 1)
                    ]),
                    startPoint: start, endPoint: end))
            }
        }

        // Bottom band, tied to the same undulation.
        let topY = h * (0.90 - 0.05 * level)
        let bottom = CGRect(x: 0, y: topY, width: w, height: h - topY)
        let bottomAlpha = 0.10 + 0.35 * level
        context.fill(Path(bottom), with: .linearGradient(
            Gradient(stops: [
                .init(color: orange.opacity(0), location: 0),
                .init(color: orange.opacity(bottomAlpha * 0.5), location: 0.55),
                .init(color: orange.opacity(bottomAlpha), location: 1)
            ]),
            startPoint: CGPoint(x: w / 2, y: topY),
            endPoint: CGPoint(x: w / 2, y: h)))
    }
}

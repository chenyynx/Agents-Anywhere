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
            return Double(min(max(levelProvider(), 0), 1))
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
        // Official border alpha is strong: at the edge the screenshot's
        // r−b ≈ 80–90, i.e. an effective orange alpha near 0.6–0.7.
        let strength = 0.35 + 0.65 * level

        // Three overlapping radial lobes per side. Centres sit just outside
        // the screen, so only the inner half of each lobe shows as a soft
        // border band; the lobes drift vertically to make the border breathe.
        // They start around 45% screen height, matching the official frame
        // where the top quarter has no orange.
        for side in 0..<2 {
            let centreX: CGFloat = side == 0 ? -w * 0.02 : w * 1.02
            for index in 0..<3 {
                let fi = Double(index)
                let sidePhase = Double(side) * 1.1
                let y = h * (0.52 + 0.16 * fi)
                    + h * 0.030 * sin(time * 1.6 + fi * 2.0 + sidePhase)
                let rx = w * (0.30 + 0.03 * sin(time * 1.3 + fi))
                let ry = h * (0.17 + 0.02 * cos(time * 1.1 + fi * 1.4))
                let wave = 0.55 + 0.45 * sin(time * 2.3 + fi * 2.6 + sidePhase)
                let alpha = strength * wave
                let rect = CGRect(x: centreX - rx, y: y - ry,
                                  width: rx * 2, height: ry * 2)
                context.fill(Path(ellipseIn: rect), with: .radialGradient(
                    Gradient(stops: [
                        .init(color: orange.opacity(alpha), location: 0),
                        .init(color: orange.opacity(alpha * 0.5), location: 0.55),
                        .init(color: orange.opacity(0), location: 1)
                    ]),
                    center: CGPoint(x: centreX, y: y),
                    startRadius: 0,
                    endRadius: max(rx, ry)))
            }
        }

        // Bottom band, tied to the same voice level.
        let topY = h * (0.88 - 0.04 * level)
        let bottom = CGRect(x: 0, y: topY, width: w, height: h - topY)
        let bottomAlpha = 0.18 + 0.38 * level
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

import AVFoundation
import SwiftUI
import UIKit

/// The pixel-art crystal globe from the Creed site (pipicore.cn), ported in
/// full: the looping clip, the 168 orbiting sparkles, the tap burst with the
/// flash/shake, and the feathered rim. The web build draws the same layers on
/// a canvas; here SwiftUI Canvas redraws them from one time-driven model.
struct CrystalGlobeView: View {
    var diameter: CGFloat = 220
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var model = CrystalGlobeModel()

    var body: some View {
        ZStack {
            LoopingVideoLayer(url: Bundle.main.url(forResource: "crystal-globe",
                                                   withExtension: "mp4"))
                // Creed's `.feather-sharp` filter on the clip.
                .brightness(-0.05)
                .contrast(1.02)
                .saturation(0.92)
            if !reduceMotion {
                TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
                    Canvas { context, size in
                        model.advance(to: timeline.date, size: size)
                        model.draw(in: &context, size: size)
                    }
                }
                .allowsHitTesting(false)
            }
        }
        .frame(width: diameter, height: diameter)
        .mask {
            // Creed's veil leaves a hole that is transparent out to 44 % and
            // opaque by 86 % of the farthest-side radius; the same proportion
            // of `diameter` keeps the visible orb the same size.
            RadialGradient(
                stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black, location: 0.5),
                    .init(color: .black.opacity(0.5), location: 0.82),
                    .init(color: .clear, location: 1),
                ],
                center: .center,
                startRadius: 0,
                endRadius: diameter * 0.45)
        }
        .contentShape(Circle())
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    model.movePointer(to: value.location, diameter: diameter)
                    if !model.isPressed {
                        model.press(size: CGSize(width: diameter, height: diameter))
                    }
                }
                .onEnded { _ in model.releasePointer() }
        )
        .accessibilityHidden(true)
        .allowsHitTesting(true)
    }
}

/// One looping muted player, torn down when the page goes away.
private struct LoopingVideoLayer: UIViewRepresentable {
    let url: URL?

    func makeUIView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        guard let url else { return view }
        // The clip carries a silent AAC track. A plain AVPlayer still takes the
        // app's audio session (soloAmbient), which pauses the user's music when
        // this page opens; an ambient session mixes with it instead.
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
        try? session.setActive(true)
        let player = AVQueuePlayer()
        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = false
        let looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspectFill
        context.coordinator.player = player
        context.coordinator.looper = looper
        player.play()
        return view
    }

    func updateUIView(_ view: PlayerView, context: Context) {}

    static func dismantleUIView(_ view: PlayerView, coordinator: Coordinator) {
        coordinator.player?.pause()
        coordinator.looper?.disableLooping()
        view.playerLayer.player = nil
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var player: AVQueuePlayer?
        var looper: AVPlayerLooper?
    }

    final class PlayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}

// MARK: - Particle model

/// Direct port of the Creed `CrystalGlobe` canvas math (component `p7` of the
/// original mmguo.dev bundle). Kept in one reference type so the 60 fps Canvas
/// can advance and draw without publishing state.
final class CrystalGlobeModel {
    private struct OrbitStar {
        var angle = Double.random(in: 0...(2 * .pi))
        var dist = 0.045 + Double.random(in: 0.01...(0.47 - 0.045 - 0.01))
        var size = Double.random(in: 1.2...3.3)
        var speed = Double.random(in: 0.0003...0.001)
        var drift = Double.random(in: -0.0004...0.0004)
        var fall = Double.random(in: 0.00008...0.00025)
        var twinklePhase = Double.random(in: 0...(2 * .pi))
        var twinkleSpeed = Double.random(in: 1.5...4.5)
        var warmth = Double.random(in: 0...1)
        var flickerPhase = Double.random(in: 0...(2 * .pi))
    }

    private struct BurstStar {
        var x: Double
        var y: Double
        var vx: Double
        var vy: Double
        var gravity: Double
        var drag: Double
        var size: Double
        var life: Double
        var age: Double
        var twinklePhase: Double
        var twinkleSpeed: Double
        var orbitalDrift: Double
        var warmth: Double
        var flickerPhase: Double

        static func spawn(size: CGSize) -> BurstStar {
            let base = Double(min(size.width, size.height))
            let magnitude = 0.8 + Double.random(in: 0...1.8)
            let direction = -Double.pi * 0.05 - Double.random(in: 0...(Double.pi * 0.9))
            return BurstStar(
                x: Double(size.width) * (0.2 + Double.random(in: 0...0.6)),
                y: Double(size.height) * (0.5 + Double.random(in: 0...0.3)),
                vx: (cos(direction) * magnitude * 0.45
                    + (Double.random(in: 0...1) - 0.5) * 0.6) * base,
                vy: sin(direction) * magnitude * 0.85 * base,
                gravity: 0.12 * Double.random(in: 0.55...1.45) * base,
                drag: Double.random(in: 0.94...0.985),
                size: Double.random(in: 0.85...2.5),
                life: Double.random(in: 2.8...4.8),
                age: 0,
                twinklePhase: Double.random(in: 0...(2 * .pi)),
                twinkleSpeed: Double.random(in: 2.1...5.4),
                orbitalDrift: Double.random(in: -0.7...0.7),
                warmth: Double.random(in: 0...1),
                flickerPhase: Double.random(in: 0...(2 * .pi)))
        }
    }

    private static let orbitCount = 168
    private static let burstPerPress = 330
    private static let burstLimit = 1320

    private var orbit: [OrbitStar] = (0..<CrystalGlobeModel.orbitCount).map { _ in OrbitStar() }
    private var burst: [BurstStar] = []
    private var lastDate: Date?
    private var startDate: Date?
    private var time: Double = 0
    private var pointer = CGPoint.zero
    private var pointerTarget = CGPoint.zero
    private var flash: Double = 0
    private var flashAge: Double = 0
    private var shake = CGSize.zero
    private let sprites = CrystalGlobeModel.makeSprites()
    private(set) var isPressed = false

    // MARK: Input

    func movePointer(to point: CGPoint, diameter: CGFloat) {
        guard diameter > 0 else { return }
        let x = (point.x / diameter) * 2 - 1
        let y = (point.y / diameter) * 2 - 1
        pointerTarget = CGPoint(x: max(-1, min(1, x)), y: max(-1, min(1, y)))
    }

    func releasePointer() {
        isPressed = false
        pointerTarget = .zero
    }

    func press(size: CGSize) {
        isPressed = true
        flash = 1
        flashAge = 0
        if burst.count + Self.burstPerPress > Self.burstLimit {
            burst.removeFirst(burst.count + Self.burstPerPress - Self.burstLimit)
        }
        burst.append(contentsOf: (0..<Self.burstPerPress).map { _ in BurstStar.spawn(size: size) })
    }

    // MARK: Simulation

    func advance(to date: Date, size: CGSize) {
        if startDate == nil { startDate = date }
        time = date.timeIntervalSince(startDate ?? date)
        let dt = min(0.05, max(0, date.timeIntervalSince(lastDate ?? date)))
        lastDate = date
        guard dt > 0, size.width > 0, size.height > 0 else { return }

        let frameScale = dt * 60
        let smoothing = CGFloat(1 - pow(0.95, frameScale))
        pointer.x += (pointerTarget.x - pointer.x) * smoothing
        pointer.y += (pointerTarget.y - pointer.y) * smoothing

        for index in orbit.indices {
            var star = orbit[index]
            star.angle += (star.speed + star.drift * sin(time * 0.5 + star.twinklePhase * 0.35)) * frameScale
            star.dist += star.fall * 0.1 * sin(time * 0.7 + star.twinklePhase) * frameScale
            if star.dist > 0.49 { star.dist = 0.045 + Double.random(in: 0.01...0.05) }
            if star.dist < 0.025 { star.dist = 0.47 - Double.random(in: 0.01...0.04) }
            orbit[index] = star
        }

        let base = Double(min(size.width, size.height))
        let centerX = Double(size.width) * 0.5
        let centerY = Double(size.height) * 0.5
        let ellipseX = base * 0.4
        let ellipseY = base * 0.345

        for index in burst.indices.reversed() {
            var star = burst[index]
            star.age += dt
            if star.age > star.life {
                burst.remove(at: index)
                continue
            }
            star.vy += star.gravity * dt
            if flash > 0.03 {
                star.vx += sin(time * 2.25 + star.y * 0.02 + star.twinklePhase)
                    * flash * base * 0.018 * dt
                star.vy += cos(time * 1.7 + star.x * 0.015 + star.flickerPhase)
                    * flash * base * 0.01 * dt
            }
            let damp = pow(star.drag, dt * 60)
            star.vx *= damp
            star.vy *= damp
            star.x += star.vx * dt
            star.y += star.vy * dt
            star.x += sin(time * 0.85 + star.twinklePhase) * star.orbitalDrift * dt * 8
            confine(&star, centerX: centerX, centerY: centerY,
                    ellipseX: ellipseX, ellipseY: ellipseY)
            burst[index] = star
        }

        if flash > 0.002 {
            flashAge += dt
            let decay = exp(-flashAge * 1.2)
            flash = decay
            let cycle = flashAge * 1.5 * 2 * .pi
            shake = CGSize(width: sin(cycle) * decay * Double(size.width) * 0.028,
                           height: (1 - cos(cycle)) * decay * Double(size.height) * 0.008)
        } else {
            flash = 0
            let shakeDecay = CGFloat(pow(0.95, frameScale))
            shake.width *= shakeDecay
            shake.height *= shakeDecay
        }
    }

    private func confine(_ star: inout BurstStar,
                         centerX: Double, centerY: Double,
                         ellipseX: Double, ellipseY: Double) {
        let normalizedX = (star.x - centerX) / ellipseX
        let normalizedY = (star.y - centerY) / ellipseY
        let distance = normalizedX * normalizedX + normalizedY * normalizedY
        guard distance > 1 else { return }
        let inverse = 1 / sqrt(distance)
        star.x = centerX + (star.x - centerX) * inverse * 0.992
        star.y = centerY + (star.y - centerY) * inverse * 0.992
        let unitX = (star.x - centerX) / ellipseX
        let unitY = (star.y - centerY) / ellipseY
        let length = sqrt(unitX * unitX + unitY * unitY)
        guard length > 0 else { return }
        let normalX = unitX / length
        let normalY = unitY / length
        let velocity = star.vx * normalX + star.vy * normalY
        if velocity > 0 {
            star.vx -= velocity * normalX * 1.35
            star.vy -= velocity * normalY * 1.35
        }
        star.vx *= 0.55
        star.vy *= 0.55
    }

    // MARK: Drawing

    func draw(in context: inout GraphicsContext, size: CGSize) {
        let base = Double(min(size.width, size.height))
        guard base > 0 else { return }
        let centerX = Double(size.width) * 0.5
        let centerY = Double(size.height) * 0.5
        context.translateBy(x: shake.width, y: shake.height)

        let pointerAngle = Double(atan2(pointer.y, pointer.x == 0 ? 0.0001 : pointer.x))
        for star in orbit {
            let angle = star.angle + pointerAngle * 0.08
            var x = centerX + cos(angle) * star.dist * base
                + Double(pointer.x) * (3.2 + star.dist * 4.8)
            var y = centerY + sin(angle) * star.dist * base * 0.88
                + Double(pointer.y) * (3.2 + star.dist * 4.8)
            if flash > 0.03 {
                x += sin(time * 2.3 + star.dist * 12 + star.twinklePhase)
                    * flash * (4 + star.dist * base * 0.02)
                y += cos(time * 1.7 + angle * 1.5 + star.flickerPhase)
                    * flash * (2.4 + star.dist * base * 0.012)
                let lift = flash * base * 0.032
                x -= sin(angle) * lift * star.dist
                y += cos(angle) * lift * star.dist * 0.88 * 0.7
            }
            let normalized = (sqrt(pow((x - centerX) / base, 2)
                + pow((y - centerY) / (base * 0.88), 2)) - 0.045) / (0.47 - 0.045)
            guard normalized > 0, normalized < 1 else { continue }
            let edge = sin(normalized * .pi)
            var brightness = 0.32
                + 0.42 * (0.5 + 0.5 * sin(time * star.twinkleSpeed + star.twinklePhase))
                + 0.26 * (0.5 + 0.5 * sin(time * star.twinkleSpeed * 1.9
                    + star.twinklePhase * 0.65 + star.flickerPhase))
            if flash > 0.05 { brightness = min(1, brightness + flash * 0.22) }
            let alpha = brightness * edge * 0.9
            guard alpha >= 0.02 else { continue }
            let radius = star.size * (0.72 + brightness * 0.5)
            drawStar(in: &context, x: x, y: y, radius: radius,
                     alpha: alpha, brightness: brightness, warmth: star.warmth)
        }

        for star in burst {
            let normalized = sqrt(pow((star.x - centerX) / (base * 0.4), 2)
                + pow((star.y - centerY) / (base * 0.345), 2))
            let edge: Double
            if normalized >= 1.02 { edge = 0 }
            else if normalized <= 0.72 { edge = 1 }
            else { edge = pow(max(0, 1 - (normalized - 0.72) / 0.3), 0.65) }
            guard edge > 0 else { continue }
            let twinkle = 0.28
                + 0.52 * (0.5 + 0.5 * sin(time * star.twinkleSpeed + star.twinklePhase))
                + 0.2 * (0.5 + 0.5 * sin(time * star.twinkleSpeed * 1.6 + star.flickerPhase))
            let lifeFraction = star.age / star.life
            let fade = lifeFraction > 0.58 ? 1 - (lifeFraction - 0.58) / 0.42 : 1
            let near = 0.84 + (1 - min(normalized, 1)) * 0.16
            let alpha = twinkle * edge * fade * near * max(1, flash * 0.9) * 0.82
            guard alpha >= 0.02 else { continue }
            let radius = star.size * (0.7 + twinkle * 0.56)
            drawStar(in: &context, x: star.x, y: star.y, radius: radius,
                     alpha: alpha, brightness: twinkle, warmth: star.warmth)
        }
    }

    private func drawStar(in context: inout GraphicsContext,
                          x: Double, y: Double, radius: Double,
                          alpha: Double, brightness: Double, warmth: Double) {
        let sprite = sprites[spriteIndex(for: warmth)]
        let glowRadius = radius * 3.5
        context.opacity = alpha
        context.draw(sprite, in: CGRect(x: x - glowRadius, y: y - glowRadius,
                                        width: glowRadius * 2, height: glowRadius * 2))
        context.opacity = 1

        let color = starColor(for: warmth)
        let core = CGRect(x: x - radius * 0.45, y: y - radius * 0.45,
                          width: radius * 0.9, height: radius * 0.9)
        context.fill(Path(ellipseIn: core), with: .color(color.opacity(alpha)))

        guard brightness > 0.6, radius > 1.2 else { return }
        var flare = Path()
        let reach = radius * 2.5
        flare.move(to: CGPoint(x: x - reach, y: y))
        flare.addLine(to: CGPoint(x: x + reach, y: y))
        flare.move(to: CGPoint(x: x, y: y - reach))
        flare.addLine(to: CGPoint(x: x, y: y + reach))
        context.stroke(flare, with: .color(color.opacity(alpha * 0.3)),
                       lineWidth: 0.5)
        guard brightness > 0.85, flash > 0.15 else { return }
        var diagonal = Path()
        let diagonalReach = radius * 1.6
        diagonal.move(to: CGPoint(x: x - diagonalReach, y: y - diagonalReach))
        diagonal.addLine(to: CGPoint(x: x + diagonalReach, y: y + diagonalReach))
        diagonal.move(to: CGPoint(x: x + diagonalReach, y: y - diagonalReach))
        diagonal.addLine(to: CGPoint(x: x - diagonalReach, y: y + diagonalReach))
        context.stroke(diagonal, with: .color(color.opacity(alpha * 0.3)),
                       lineWidth: 0.5)
    }

    // MARK: Palette

    private func spriteIndex(for warmth: Double) -> Int {
        switch warmth {
        case ..<0.2: 0
        case ..<0.45: 1
        case ..<0.7: 2
        case ..<0.85: 3
        default: 4
        }
    }

    private func starColor(for warmth: Double) -> Color {
        let (red, green, blue) = Self.rgb(for: warmth)
        return Color(red: red / 255, green: green / 255, blue: blue / 255)
    }

    private static func rgb(for warmth: Double) -> (Double, Double, Double) {
        switch warmth {
        case ..<0.2: (185, 210, 255)
        case ..<0.45: (255, 255, 242)
        case ..<0.7: (255, 225, 190)
        case ..<0.85: (215, 195, 255)
        default: (200, 240, 230)
        }
    }

    private static func makeSprites() -> [Image] {
        (0..<5).map { index in
            let warmth = Double(index) * 0.2 + 0.1
            let (red, green, blue) = rgb(for: warmth)
            let size = CGSize(width: 128, height: 128)
            let renderer = UIGraphicsImageRenderer(size: size)
            let image = renderer.image { rendererContext in
                let colors = [
                    UIColor(red: CGFloat(red / 255), green: CGFloat(green / 255),
                            blue: CGFloat(blue / 255), alpha: 0.45).cgColor,
                    UIColor(red: CGFloat(red / 255), green: CGFloat(green / 255),
                            blue: CGFloat(blue / 255), alpha: 0.1).cgColor,
                    UIColor(red: CGFloat(red / 255), green: CGFloat(green / 255),
                            blue: CGFloat(blue / 255), alpha: 0).cgColor,
                ] as CFArray
                guard let gradient = CGGradient(
                    colorsSpace: CGColorSpaceCreateDeviceRGB(),
                    colors: colors,
                    locations: [0, 0.2, 1]) else { return }
                let center = CGPoint(x: 64, y: 64)
                rendererContext.cgContext.drawRadialGradient(
                    gradient, startCenter: center, startRadius: 0,
                    endCenter: center, endRadius: 64, options: [])
            }
            return Image(uiImage: image)
        }
    }
}

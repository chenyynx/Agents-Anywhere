//
//  BlobatarView.swift
//
//  Ported from blobatar 2.8.0 (https://github.com/Alain00/blobatar),
//  MIT License. Copyright (c) 2026 Alain.
//
//  The renderer: one Canvas draws the composed figure, TimelineView supplies
//  the clock, and the touch adds a gaze the web never needed (pointer hover is
//  the web's version). No video layer and no layout-dependent leaves, so the
//  new-session page can move this view with the keyboard without it lagging.
//

import SwiftUI

/// Composing a seed is not free — the palette runs contrast walks — and the
/// new-session page rebuilds its body on every keystroke, so the result is
/// cached per seed rather than per view value.
@MainActor
final class BlobatarLayoutCache {
    static let shared = BlobatarLayoutCache()
    private var storage: [String: BlobatarLayout] = [:]
    private var seedStorage: [String: BlobatarIdleSeeds] = [:]

    func layout(for seed: String) -> BlobatarLayout {
        if let cached = storage[seed] { return cached }
        let layout = BlobatarComposer.layout(seed: seed)
        storage[seed] = layout
        return layout
    }

    func idleSeeds(for seed: String) -> BlobatarIdleSeeds {
        if let cached = seedStorage[seed] { return cached }
        let seeds = BlobatarIdleSeeds(traits: BlobatarTraits(seed: seed))
        seedStorage[seed] = seeds
        return seeds
    }
}

struct BlobatarView: View {
    let seed: String
    var diameter: CGFloat = 150

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var fromPose = BlobatarExpressions.idle
    @State private var toPose = BlobatarExpressions.idle
    @State private var fromHead = ""
    @State private var fromEye = ""
    @State private var toHead = ""
    @State private var toEye = ""
    @State private var morphStart = Date.distantPast
    @State private var morphDuration: TimeInterval = 0
    @State private var morphCurve: (Double, Double, Double, Double) = (0.42, 0, 0.58, 1)
    @State private var gaze = CGSize.zero
    @State private var resetTask: Task<Void, Never>?

    private var layout: BlobatarLayout {
        BlobatarLayoutCache.shared.layout(for: seed)
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: reduceMotion)) { timeline in
            Canvas { context, size in
                draw(context: &context, size: size, date: reduceMotion ? nil : timeline.date)
            }
        }
        .frame(width: diameter, height: diameter)
        .contentShape(Circle())
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    guard !reduceMotion else { return }
                    updateGaze(value.location)
                }
                .onEnded { value in
                    gaze = .zero
                    let travel = hypot(value.translation.width, value.translation.height)
                    guard travel < 4 else { return }
                    showNextExpression()
                })
        .accessibilityHidden(true)
        .onDisappear { resetTask?.cancel() }
    }

    // MARK: - Drawing

    private func draw(context: inout GraphicsContext, size: CGSize, date: Date?) {
        let layout = self.layout
        let scale = min(size.width, size.height) / 100
        context.scaleBy(x: scale, y: scale)

        let clock = date?.timeIntervalSinceReferenceDate ?? 0
        let amplitude: Double = date == nil ? 0 : 1
        let pose = date.map { sampledPose(at: $0) } ?? toPose
        let idle = BlobatarIdle.frame(BlobatarLayoutCache.shared.idleSeeds(for: seed),
                                      time: clock * 1000,
                                      amplitude: amplitude,
                                      shakeAmount: pose.shake)
        let colors = date.map { sampledColors(at: $0) } ?? finalColors()
        let head = Color(blobatarHex: colors.head.isEmpty ? layout.palette.head : colors.head)
        let eye = Color(blobatarHex: colors.eye.isEmpty ? layout.palette.eye : colors.eye)

        // `.mo-root` — the tremor. `shakeAmount` was the pose's own amount.
        context.translateBy(x: idle.shake.0, y: idle.shake.1)
        // `.mo-breathe` — about the viewBox centre, as the stylesheet does.
        context.translateBy(x: 50, y: 50)
        context.scaleBy(x: idle.breathe.0, y: idle.breathe.1)
        context.translateBy(x: -50, y: -50)
        // `.mo-bob`, carrying the pose's own body offset.
        context.translateBy(x: 0, y: pose.bdy + idle.bob)

        for petal in layout.petals {
            let rect = CGRect(x: petal.cx - petal.r, y: petal.cy - petal.r,
                              width: petal.r * 2, height: petal.r * 2)
            context.fill(Path(ellipseIn: rect), with: .color(head))
        }
        for extra in layout.extras {
            context.fill(extra.path, with: .color(head))
        }
        context.fill(layout.bodyPath.path, with: .color(head))

        // `.mo-eyes` — the glance, plus the touch gaze this platform adds.
        context.translateBy(x: idle.saccade.0 + gaze.width, y: idle.saccade.1 + gaze.height)

        let posed = pose.baked(layout.eyes, rockp: idle.rockp)
        for (index, baseline) in layout.eyes.enumerated() {
            let eyeShape = posed[index]
            let path = BlobatarPathBuilder.superellipse(
                cx: eyeShape.cx, cy: eyeShape.cy,
                rx: eyeShape.rx, ry: eyeShape.ry,
                n: eyeShape.n, rot: eyeShape.rot).path
            let side = index == 1 ? 1.0 : -1.0
            let lean = baseline.rot
            context.drawLayer { layer in
                // `.mo-eye > *`: the blink closes across the eye's own leaned
                // width; the foreshortening is screen-space and is not leaned.
                layer.translateBy(x: baseline.cx, y: baseline.cy)
                layer.rotate(by: .degrees(idle.wrap.rot * side))
                layer.scaleBy(x: 1 + idle.wrap.mx + idle.wrap.side * side,
                              y: 1 + idle.wrap.sy)
                layer.rotate(by: .degrees(lean))
                layer.scaleBy(x: 1, y: idle.blink)
                layer.rotate(by: .degrees(-lean))
                layer.translateBy(x: -baseline.cx, y: -baseline.cy)
                layer.fill(path, with: .color(eye))
            }
        }
    }

    // MARK: - Expressions

    private func showNextExpression() {
        guard !reduceMotion else { return }
        let now = Date()
        fromPose = sampledPose(at: now)
        let current = sampledColors(at: now)
        fromHead = current.head
        fromEye = current.eye

        let target = BlobatarExpressions.roster.randomElement() ?? BlobatarExpressions.happy
        toPose = target
        let targetColors = colors(for: target)
        toHead = targetColors.head
        toEye = targetColors.eye
        morphStart = now
        morphDuration = 0.3
        morphCurve = (0.45, 0.05, 0.5, 1)

        resetTask?.cancel()
        resetTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            returnToIdle()
        }
    }

    private func returnToIdle() {
        let now = Date()
        fromPose = sampledPose(at: now)
        let current = sampledColors(at: now)
        fromHead = current.head
        fromEye = current.eye
        toPose = BlobatarExpressions.idle
        // Directly, not `finalColors()`: the stored endpoints still belong to
        // the expression being left.
        let idleColors = colors(for: BlobatarExpressions.idle)
        toHead = idleColors.head
        toEye = idleColors.eye
        morphStart = now
        morphDuration = 0.4
        morphCurve = (0.42, 0, 0.58, 1)
    }

    private func progress(at date: Date) -> Double {
        guard morphDuration > 0 else { return 1 }
        let raw = date.timeIntervalSince(morphStart) / morphDuration
        return min(1, max(0, raw))
    }

    private func eased(_ value: Double) -> Double {
        BlobatarIdle.bezier(morphCurve.0, morphCurve.1, morphCurve.2, morphCurve.3, value)
    }

    private func sampledPose(at date: Date) -> BlobatarPose {
        BlobatarPose.lerp(fromPose, toPose, eased(progress(at: date)))
    }

    private func sampledColors(at date: Date) -> (head: String, eye: String) {
        let t = eased(progress(at: date))
        let fallback = finalColors()
        let startHead = fromHead.isEmpty ? fallback.head : fromHead
        let startEye = fromEye.isEmpty ? fallback.eye : fromEye
        let endHead = toHead.isEmpty ? fallback.head : toHead
        let endEye = toEye.isEmpty ? fallback.eye : toEye
        return (BlobatarColor.fadeHex(startHead, endHead, t),
                BlobatarColor.fadeHex(startEye, endEye, t))
    }

    private func finalColors() -> (head: String, eye: String) {
        // Stored endpoints are authoritative; recomputing a tint here would run
        // the contrast walk on every frame.
        if !toHead.isEmpty, !toEye.isEmpty { return (toHead, toEye) }
        return colors(for: toPose)
    }

    private func colors(for pose: BlobatarPose) -> (head: String, eye: String) {
        let palette = layout.palette
        guard let tint = pose.tint, pose.heat > 0 else {
            return (palette.head, palette.eye)
        }
        let pair = BlobatarColor.tinted(head: palette.head, eye: palette.eye, tint: tint)
        return (BlobatarColor.mixHex(palette.head, pair.head, pose.heat),
                BlobatarColor.mixHex(palette.eye, pair.eye, pose.heat))
    }

    // MARK: - Gaze

    private func updateGaze(_ location: CGPoint) {
        let x = Double(location.x / max(diameter, 1)) * 100
        let y = Double(location.y / max(diameter, 1)) * 100
        let dx = x - layout.face.cx
        let dy = y - layout.face.cy
        let length = max(hypot(dx, dy), 0.001)
        // The web's gaze travels at most 3 units; ease in with distance so a
        // touch near the centre barely moves the pair.
        let travel = 3.0 * min(1, length / 18)
        gaze = CGSize(width: dx / length * travel, height: dy / length * travel)
    }
}

private extension Color {
    init(blobatarHex hex: String) {
        let value = Int(hex.dropFirst(), radix: 16) ?? 0
        self.init(.sRGB,
                  red: Double((value >> 16) & 255) / 255,
                  green: Double((value >> 8) & 255) / 255,
                  blue: Double(value & 255) / 255,
                  opacity: 1)
    }
}

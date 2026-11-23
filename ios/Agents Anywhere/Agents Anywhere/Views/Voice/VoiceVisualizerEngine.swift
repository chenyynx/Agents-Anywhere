import Foundation
import MetalKit
import QuartzCore
import SwiftUI
import simd

// Voice UI replica, parameters lifted from Claude iOS 1.261109.19.
// Evidence: aa-test/claude-ios-re/CANONICAL/27-voice-ui-109.md
//   §4 visualizer engine, §8 device screenshot check.
// Shaders: Views/Voice/VoiceVisualizerShaders.metal + SloshShaders.metal.

// MARK: - Palette

enum VoiceVisualizerPalette {
    /// Official voice tint: sRGB (0.42, 0.61, 0.80) — the user's voice.
    static let voice = SIMD4<Float>(0.42, 0.61, 0.80, 1.0)
    /// The agent's voice. Screenshot fit lands on the brand orange #D97757.
    static let agent = SIMD4<Float>(0.851, 0.467, 0.341, 1.0)
    /// Brand accent used by the slosh liquid (spark / listening frames).
    static let accentBrand = SIMD3<Float>(0.851, 0.467, 0.341) // #D97757
}

/// Which side of the conversation is speaking; drives the orb color.
enum VoiceVisualizerRole: Equatable, Hashable {
    case user
    case agent

    var color: SIMD4<Float> {
        switch self {
        case .user: return VoiceVisualizerPalette.voice
        case .agent: return VoiceVisualizerPalette.agent
        }
    }
}

// MARK: - Tuning (VisualizerBlobTuning)

struct VoiceVisualizerTuning {
    var maxScale: Float
    var maxOvalRatio: Float
    var gradientFalloffFactor: Float
    var edgeSmoothstepOuter: Float
    var intensityYOffsetFactor: Float
    var roleColorDelay: Double
    var colorTimeConstant: Double?
    var settleWindow: Double

    /// Three presets recovered from `FUN_101dd0550` (see CANONICAL §4.2).
    static func preset(useSlosh: Bool, raised: Bool) -> VoiceVisualizerTuning {
        if useSlosh {
            return .init(maxScale: 1.2, maxOvalRatio: 0.9,
                         gradientFalloffFactor: 8.0, edgeSmoothstepOuter: 0.64,
                         intensityYOffsetFactor: 0.3,
                         roleColorDelay: 0.3, colorTimeConstant: nil,
                         settleWindow: 1.2)
        }
        if raised {
            return .init(maxScale: 0.9, maxOvalRatio: 0.75,
                         gradientFalloffFactor: 6.0, edgeSmoothstepOuter: 0.68,
                         intensityYOffsetFactor: 0.2,
                         roleColorDelay: 0, colorTimeConstant: 0.06,
                         settleWindow: 0.5859056451847443)
        }
        return .init(maxScale: 1.5, maxOvalRatio: 0.75,
                     gradientFalloffFactor: 6.0, edgeSmoothstepOuter: 0.68,
                     intensityYOffsetFactor: 0.3,
                     roleColorDelay: 0.3, colorTimeConstant: nil,
                     settleWindow: 0.5859056451847443)
    }
}

// MARK: - GPU layouts (must match the .metal structs exactly)

struct VoiceVisualizerUniforms {
    var modelView: simd_float4x4
    var baseColor: SIMD4<Float>
    var time: Float
    var opacityFactor: Float
    var ovalRatio: Float
    var ditherSeed: Float
    var gradientFalloffFactor: Float
    var edgeSmoothstepOuter: Float
    var pad0: Float = 0
    var pad1: Float = 0
}

struct SloshUniforms {
    var resolution: SIMD2<Float>
    var time: Float
    var sinceUtteranceStart: Float
    var envelope: Float
    var level: Float
    var bottomLeftCornerRadius: Float
    var bottomRightCornerRadius: Float
    var darkModeDim: Float
    var reduceMotion: Float
    var phase: Float
    var compactFill: Float
    var thinking: Float
    var pad0: Float = 0
    var pad1: Float = 0
    var pad2: Float = 0
    var tint: SIMD3<Float>
}

struct VoiceVisualizerBand {
    var position: SIMD2<Float>
    var scale: Float
    var ovalRatio: Float
    var opacity: Float
    var ditherSeed: Float
}

// MARK: - Scene model (layout math from FUN_101dd15e0)

final class VoiceVisualizerSceneModel {
    var tuning: VoiceVisualizerTuning
    var isDark: Bool = false
    var reduceMotion: Bool = false
    var holdsStill: Bool = false
    /// Extra vertical shift of the band cluster, in clip-space units.
    var baseYOffset: Float = 0

    private var time: Double = 0
    private var fast = [Float](repeating: 0, count: 7)
    private var slow = [Float](repeating: 0, count: 7)
    private var prevFast = [Float](repeating: 0, count: 7)
    private var prevSlow = [Float](repeating: 0, count: 7)

    init(tuning: VoiceVisualizerTuning) {
        self.tuning = tuning
    }

    func reset() {
        fast = .init(repeating: 0, count: 7)
        slow = .init(repeating: 0, count: 7)
        prevFast = fast
        prevSlow = slow
        time = 0
    }

    /// `dt` seconds; `levels` 7 microphone band powers in 0...1.
    func update(dt: Double, levels: [Float]) -> [VoiceVisualizerBand] {
        time += dt
        let dtF = Float(dt)
        let aFast = expf((2 * dtF) * -1.3581960 * Float.pi)
        let aSlow = expf((2 * dtF) * -1.6477940 * Float.pi)

        for i in 0..<7 {
            let input = levels.indices.contains(i) ? levels[i] : 0
            let f = (1 - aFast) * input + aFast * prevFast[i]
            // Official (0x101dd15e0): slow = a·slow_prev + (1−a)·fast.
            let s = aSlow * prevSlow[i] + (1 - aSlow) * f
            fast[i] = f
            slow[i] = s
            prevFast[i] = f
            prevSlow[i] = s
        }

        // Light keeps the wide ±1 spread; the dark branch narrows to ±0.6.
        // The oval branch is the one that differs by dark mode; opacity does
        // not (0x101dd15e0 field order: scale@0x28, opacity@0x2c, oval@0x30).
        let wide = !isDark
        let xBase: Float = wide ? -1.0 : -0.6
        let xSpread: Float = wide ? 2.0 : 1.2
        let ovalBase: Float = wide ? 1.0 : 0.5
        let ovalSlope: Float = wide ? 0.1 : 0.2

        var bands: [VoiceVisualizerBand] = []
        bands.reserveCapacity(7)
        for i in 0..<7 {
            let fi = Float(i)
            let phi = fi * Float.pi
            let level = min(max(slow[i] / 0.75, 0), 1)

            // Exact layout constants from FUN_101dd15e0 (see CANONICAL §4.4).
            let x = xBase + xSpread * fi / 6
                + sinf(level * 0.2 + fi * 1.3) * 0.01
                + (fi * 0.04 + 0.04) * sinf(phi * 0.6 + level * (fi * 0.07 + 0.4))
            let y = baseYOffset
                + cosf(level * 0.15 + fi * 2.7) * 0.015
                + (fi * 0.004 + 0.07) * cosf(phi * 0.7 + level * (fi * 0.05 + 0.3))
                // NDC +y is up; the official call glow sits lower, so the
                // intensity offset pulls the cluster down.
                - tuning.intensityYOffsetFactor * level

            bands.append(.init(position: SIMD2(x, y),
                               scale: 0.3 + 0.65 * level,
                               // uVar22 = (0.3, 0.1); field 0x2c uses the 0.1
                               // base and grows with the voice.
                               opacity: 0.1 + 0.65 * level,
                               // 0x30 = P − level·Q (light P=1/Q=0.1).
                               ovalRatio: max(ovalBase - level * ovalSlope, 0.05),
                               ditherSeed: Float(i) * 0.37 + 1))
        }
        return bands
    }
}

// MARK: - Renderer

final class VoiceVisualizerRenderer: NSObject, MTKViewDelegate {
    private var device: MTLDevice!
    private var commandQueue: MTLCommandQueue!
    private var orbPipeline: MTLRenderPipelineState!
    private var sloshPipeline: MTLRenderPipelineState!
    private var quadBuffer: MTLBuffer!
    private var uniformBuffer: MTLBuffer!
    private var sloshUniformBuffer: MTLBuffer!

    private var scene: VoiceVisualizerSceneModel!
    private var lastTimestamp: CFTimeInterval?

    var isDark: Bool = false {
        didSet { scene.isDark = isDark }
    }
    var reduceMotion: Bool = false {
        didSet { scene.reduceMotion = reduceMotion }
    }
    /// Extra downward shift of the band cluster, in clip-space units.
    var baseYOffset: Float = 0 {
        didSet { scene.baseYOffset = baseYOffset }
    }
    var showSlosh: Bool = true
    var thinking: Bool = false
    var liveLevels: Bool = true
    /// When set, overrides the mock levels (microphone input).
    var levelsProvider: (() -> [Float])?
    var role: VoiceVisualizerRole = .user {
        didSet {
            if role != oldValue { roleChangedAt = CACurrentMediaTime() }
        }
    }

    private var currentColor = VoiceVisualizerPalette.voice
    private var roleChangedAt: CFTimeInterval = 0
    private var lastAudible: CFTimeInterval?
    private var idleOpacity: Float = 0

    init?(device: MTLDevice, pixelFormat: MTLPixelFormat, tuning: VoiceVisualizerTuning) {
        guard let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary(),
              let orbVertex = library.makeFunction(name: "voiceVisualizerVertexShader"),
              let orbFragment = library.makeFunction(name: "voiceVisualizerFragmentShader"),
              let sloshVertex = library.makeFunction(name: "sloshVertexShader"),
              let sloshFragment = library.makeFunction(name: "sloshFragmentShader")
        else { return nil }
        self.device = device
        self.commandQueue = queue
        self.scene = VoiceVisualizerSceneModel(tuning: tuning)

        let orbDesc = MTLRenderPipelineDescriptor()
        orbDesc.vertexFunction = orbVertex
        orbDesc.fragmentFunction = orbFragment
        orbDesc.colorAttachments[0].pixelFormat = pixelFormat
        let vertexDescriptor = MTLVertexDescriptor()
        vertexDescriptor.attributes[0].format = .float2
        vertexDescriptor.attributes[0].offset = 0
        vertexDescriptor.attributes[0].bufferIndex = 0
        vertexDescriptor.layouts[0].stride = MemoryLayout<SIMD2<Float>>.stride
        vertexDescriptor.layouts[0].stepFunction = .perVertex
        orbDesc.vertexDescriptor = vertexDescriptor
        let attachment = orbDesc.colorAttachments[0]!
        attachment.isBlendingEnabled = true
        attachment.rgbBlendOperation = .add
        attachment.alphaBlendOperation = .add
        attachment.sourceRGBBlendFactor = .one            // premultiplied
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha

        let sloshDesc = MTLRenderPipelineDescriptor()
        sloshDesc.vertexFunction = sloshVertex
        sloshDesc.fragmentFunction = sloshFragment
        sloshDesc.colorAttachments[0].pixelFormat = pixelFormat
        let sloshAttachment = sloshDesc.colorAttachments[0]!
        sloshAttachment.isBlendingEnabled = true
        sloshAttachment.rgbBlendOperation = .add
        sloshAttachment.alphaBlendOperation = .add
        sloshAttachment.sourceRGBBlendFactor = .one
        sloshAttachment.sourceAlphaBlendFactor = .one
        sloshAttachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        sloshAttachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha

        guard let orb = try? device.makeRenderPipelineState(descriptor: orbDesc),
              let slosh = try? device.makeRenderPipelineState(descriptor: sloshDesc) else {
            return nil
        }
        self.orbPipeline = orb
        self.sloshPipeline = slosh

        let vertices: [SIMD2<Float>] = [
            SIMD2(-1, -1), SIMD2(1, -1), SIMD2(-1, 1), SIMD2(1, 1)
        ]
        guard let quad = device.makeBuffer(bytes: vertices,
                                           length: MemoryLayout<SIMD2<Float>>.stride * vertices.count,
                                           options: .storageModeShared),
              let uniforms = device.makeBuffer(length: MemoryLayout<VoiceVisualizerUniforms>.stride * 7,
                                               options: .storageModeShared),
              let sloshUniforms = device.makeBuffer(length: MemoryLayout<SloshUniforms>.stride,
                                                    options: .storageModeShared)
        else { return nil }
        self.quadBuffer = quad
        self.uniformBuffer = uniforms
        self.sloshUniformBuffer = sloshUniforms
        super.init()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        let dt = min(max(now - (lastTimestamp ?? now), 0), 2.0 / 60.0)
        lastTimestamp = now

        let levels = levelsProvider?()
            ?? (liveLevels ? Self.mockLevels(time: now, thinking: thinking)
                           : [Float](repeating: 0.32, count: 7))
        let bands = scene.update(dt: dt, levels: levels)

        // Idle gate: the official view is blank before anyone speaks. After
        // `settleWindow` without audio the whole band set fades to zero, and
        // it snaps back when the voice returns.
        let peak = levels.max() ?? 0
        if peak > 0.04 { lastAudible = now }
        let audible = lastAudible.map { now - $0 < scene.tuning.settleWindow } ?? false
        let idleTarget: Float = audible ? 1 : 0
        let idleTau = audible ? 0.05 : 0.25
        idleOpacity += (idleTarget - idleOpacity) * Float(1 - exp(-dt / idleTau))

        // Role change: hold 0.3 s, then ease toward the new voice color
        // (roleColorDelay / colorTimeConstant, CANONICAL §4.2).
        if now - roleChangedAt > 0.3 {
            let target = role.color
            let k = Float(1 - exp(-dt / 0.06))
            currentColor += (target - currentColor) * k
        }

        guard let drawable = view.currentDrawable,
              let pass = view.currentRenderPassDescriptor,
              let command = commandQueue.makeCommandBuffer(),
              let encoder = command.makeRenderCommandEncoder(descriptor: pass)
        else { return }

        let size = view.drawableSize
        let contentScale = Float(view.contentScaleFactor)

        // Slosh liquid (composer) behind the orb.
        if showSlosh {
            var u = SloshUniforms(
                resolution: SIMD2(Float(size.width), Float(size.height)),
                time: Float(now),
                sinceUtteranceStart: 1.2,
                envelope: 0.8,
                level: 0.35,
                bottomLeftCornerRadius: 26 * contentScale,
                bottomRightCornerRadius: 26 * contentScale,
                darkModeDim: isDark ? 0.82 : 1.0,
                reduceMotion: reduceMotion ? 1 : 0,
                phase: Float(now) * 1.3,
                compactFill: 0,
                thinking: thinking ? 1 : 0,
                tint: VoiceVisualizerPalette.accentBrand)
            memcpy(sloshUniformBuffer.contents(), &u, MemoryLayout<SloshUniforms>.stride)
            encoder.setRenderPipelineState(sloshPipeline)
            encoder.setFragmentBuffer(sloshUniformBuffer, offset: 0, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }

        // Orb bands.
        encoder.setRenderPipelineState(orbPipeline)
        encoder.setVertexBuffer(quadBuffer, offset: 0, index: 0)
        for (index, band) in bands.enumerated() {
            var matrix = simd_float4x4(diagonal: SIMD4<Float>(1, 1, 1, 1))
            // Official uniform build (0x101dd1c5c): uniform scale + (x, y)
            // translation in clip space — no aspect correction, no 0.5 factor.
            matrix.columns.0 = SIMD4(band.scale, 0, 0, 0)
            matrix.columns.1 = SIMD4(0, band.scale, 0, 0)
            matrix.columns.2 = SIMD4(0, 0, 1, 0)
            matrix.columns.3 = SIMD4(band.position.x, band.position.y, 0, 1)
            var u = VoiceVisualizerUniforms(
                modelView: matrix,
                baseColor: currentColor,
                time: Float(now),
                opacityFactor: band.opacity * idleOpacity,
                ovalRatio: max(band.ovalRatio, 0.05),
                ditherSeed: band.ditherSeed,
                gradientFalloffFactor: scene.tuning.gradientFalloffFactor,
                edgeSmoothstepOuter: scene.tuning.edgeSmoothstepOuter)
            let offset = MemoryLayout<VoiceVisualizerUniforms>.stride * index
            memcpy(uniformBuffer.contents().advanced(by: offset), &u,
                   MemoryLayout<VoiceVisualizerUniforms>.stride)
            encoder.setVertexBuffer(uniformBuffer, offset: offset, index: 1)
            encoder.setFragmentBuffer(uniformBuffer, offset: offset, index: 1)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }

        encoder.endEncoding()
        command.present(drawable)
        command.commit()
    }

    private static func mockLevels(time: CFTimeInterval, thinking: Bool) -> [Float] {
        (0..<7).map { i in
            let fi = Double(i)
            let a = 0.5 + 0.5 * sin(time * 1.35 + fi * 0.9)
            let b = 0.5 + 0.5 * sin(time * 0.61 + fi * 2.1)
            let base = thinking ? 0.18 : 0.28
            return Float(min(max(base + 0.45 * a * b, 0), 1))
        }
    }
}

// MARK: - SwiftUI surface

struct VoiceVisualizerSurface: UIViewRepresentable {
    var isDark: Bool
    var reduceMotion: Bool
    var showSlosh: Bool
    var thinking: Bool
    var liveLevels: Bool
    var role: VoiceVisualizerRole
    var levelsProvider: (() -> [Float])?
    var baseYOffset: Float = 0

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView()
        view.device = MTLCreateSystemDefaultDevice()
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.isOpaque = false
        view.backgroundColor = .clear
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        view.preferredFramesPerSecond = 60
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        if let device = view.device,
           let renderer = VoiceVisualizerRenderer(device: device,
                                                  pixelFormat: view.colorPixelFormat,
                                                  tuning: .preset(useSlosh: true, raised: false)) {
            renderer.isDark = isDark
            renderer.reduceMotion = reduceMotion
            renderer.showSlosh = showSlosh
            renderer.thinking = thinking
            renderer.liveLevels = liveLevels
            renderer.role = role
            renderer.levelsProvider = levelsProvider
            renderer.baseYOffset = baseYOffset
            context.coordinator.renderer = renderer
            view.delegate = renderer
        }
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        guard let renderer = context.coordinator.renderer else { return }
        renderer.isDark = isDark
        renderer.reduceMotion = reduceMotion
        renderer.showSlosh = showSlosh
        renderer.thinking = thinking
        renderer.liveLevels = liveLevels
        renderer.role = role
        renderer.levelsProvider = levelsProvider
        renderer.baseYOffset = baseYOffset
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var renderer: VoiceVisualizerRenderer?
    }
}

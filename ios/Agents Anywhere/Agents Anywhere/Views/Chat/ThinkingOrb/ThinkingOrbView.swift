import SwiftUI
import UIKit

/// `#RRGGBB` bridging for the orb's custom palette. Lives here, not in
/// `OrbPalette.swift`: this file is iOS-only, so `UIColor` is free to use,
/// while the palette model compiles for macOS in the package's test job.
extension Color {
    init(orbHex hex: String) { self = (OrbRGB(hexString: hex) ?? OrbRGB(0, 124, 255)).color(1) }
    var orbHex: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X", Int(round(r * 255)), Int(round(g * 255)), Int(round(b * 255)))
    }
}

// MARK: - 视图：思考球

/// The dot-matrix orb: a Canvas drawing driven by the settings and the
/// environment — activity picks the motion, the seven `OrbSettingsKeys`
/// `@AppStorage` values pick palette/form/glow, and a new `OrbPulse.id`
/// fires one shockwave.
struct ThinkingOrbView: View {
    /// The activity whose default effect drives the orb.
    var activity: OrbActivity = .thinking
    /// 布局占位直径（pt）。状态行里建议 30；设置页预览建议 96~120。
    var size: CGFloat = 30
    /// 收到消息时宿主换一个新的 OrbPulse 即触发一次
    var pulse: OrbPulse? = nil
    /// 球所在背景的明暗；nil = 跟随系统
    var appearance: ColorScheme? = nil
    /// finished 状态是否自动淡出
    var fadeWhenFinished: Bool = true

    @AppStorage(OrbSettingsKeys.palette) private var paletteID = "kimi"
    @AppStorage(OrbSettingsKeys.customHex) private var customHexJSON = "[\"#007CFF\",\"#00F6FF\",\"#DFC8F5\"]"
    @AppStorage(OrbSettingsKeys.form) private var formRaw = OrbForm.dots.rawValue
    @AppStorage(OrbSettingsKeys.glow) private var glowOn = true
    @AppStorage(OrbSettingsKeys.fixedEffect) private var fixedEffectRaw = ""
    @AppStorage(OrbSettingsKeys.receivePulse) private var receivePulse = true
    @AppStorage(OrbSettingsKeys.lowPower) private var lowPower = false

    @Environment(\.colorScheme) private var envScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var engine = OrbEngine()
    @State private var fade = 1.0

    init(activity: OrbActivity = .thinking, size: CGFloat = 30, pulse: OrbPulse? = nil,
         appearance: ColorScheme? = nil, fadeWhenFinished: Bool = true) {
        self.activity = activity
        self.size = size
        self.pulse = pulse
        self.appearance = appearance
        self.fadeWhenFinished = fadeWhenFinished
    }

    private var config: OrbRenderConfig {
        let palette = OrbPalette.resolve(id: paletteID, customHex: OrbSettingsKeys.decodeCustomHex(customHexJSON))
        let form = OrbSettingsKeys.resolvedForm(formRaw)
        let fixed = OrbSettingsKeys.resolvedFixedEffect(fixedEffectRaw)
        let effect: OrbEffect = activity == .finished ? .calm : (fixed ?? activity.defaultEffect)
        return OrbRenderConfig(effect: effect, palette: palette,
                               isDark: (appearance ?? envScheme) == .dark,
                               glow: glowOn ? 0.55 : 0,
                               form: form, reduced: reduceMotion)
    }

    var body: some View {
        let side = size * 1.45   // 画布比占位大一圈，留给光晕，不裁切
        let interval: Double? = reduceMotion ? 1.0 / 10 : (lowPower ? 1.0 / 30 : nil)
        TimelineView(.animation(minimumInterval: interval, paused: scenePhase != .active)) { tl in
            Canvas { ctx, sz in
                engine.render(&ctx, size: sz, radius: Double(size) * 0.36,
                              now: tl.date.timeIntervalSinceReferenceDate, config: config)
            }
            .frame(width: side, height: side)
        }
        .frame(width: size, height: size)
        .opacity(fadeWhenFinished ? fade : 1)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onChange(of: pulse?.id) { _, _ in
            // 设置关闭或「减少动态效果」时不触发脉冲（模型层不做设置判断）。
            if receivePulse, !reduceMotion, let p = pulse { engine.addPulse(strength: p.strength) }
        }
        .onChange(of: activity) { _, new in
            if new == .finished {
                withAnimation(.easeOut(duration: 1.2).delay(0.8)) { fade = 0 }
            } else {
                withAnimation(.easeOut(duration: 0.2)) { fade = 1 }
            }
        }
    }
}

// MARK: - 状态文字（高光与球的扫描节奏同步）

struct OrbStatusText: View {
    let text: String
    var active = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: !active || reduceMotion || scenePhase != .active)) { tl in
            let e = OrbMath.wave(tl.date.timeIntervalSinceReferenceDate)
            Text(text)
                .foregroundStyle(.secondary)
                .overlay {
                    GeometryReader { geo in
                        LinearGradient(colors: [.clear, .primary, .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: geo.size.width * 0.45)
                            .offset(x: -geo.size.width * 0.45 + geo.size.width * 1.45 * e)
                    }
                    .mask { Text(text) }
                }
        }
    }
}

/// 状态行：球 + 文案，直接替换原来的「图标 + 文案」
struct OrbStatusRow: View {
    var activity: OrbActivity
    var text: String
    var pulse: OrbPulse? = nil

    var body: some View {
        HStack(spacing: 6) {
            ThinkingOrbView(activity: activity, size: 30, pulse: pulse)
            OrbStatusText(text: text, active: activity != .finished)
                .font(.subheadline)
        }
    }
}

#Preview("Thinking orb — light") {
    VStack(spacing: 28) {
        HStack(spacing: 28) {
            ThinkingOrbView(activity: .thinking, size: 84)
            ThinkingOrbView(activity: .toolRunning, size: 84)
        }
        HStack(spacing: 28) {
            ThinkingOrbView(activity: .parallelWork, size: 84)
            ThinkingOrbView(activity: .writing, size: 84)
        }
        OrbStatusRow(activity: .thinking, text: "Thinking…")
    }
    .padding(32)
    .preferredColorScheme(.light)
}

#Preview("Thinking orb — dark") {
    VStack(spacing: 28) {
        HStack(spacing: 28) {
            ThinkingOrbView(activity: .thinking, size: 84)
            ThinkingOrbView(activity: .toolRunning, size: 84)
        }
        HStack(spacing: 28) {
            ThinkingOrbView(activity: .parallelWork, size: 84)
            ThinkingOrbView(activity: .writing, size: 84)
        }
        OrbStatusRow(activity: .thinking, text: "Thinking…")
    }
    .padding(32)
    .preferredColorScheme(.dark)
    .background(Color.black)
}

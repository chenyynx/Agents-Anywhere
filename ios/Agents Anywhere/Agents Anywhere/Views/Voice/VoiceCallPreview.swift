import SwiftUI

/// Lab-only call-shell preview at the real device size.
///
/// The official reference frames (2026-11-23) show:
/// - user: a wide bottom cloud that exists even at rest and drifts toward
///   the centre/up with the voice;
/// - agent: an orange band undulating along the left/right/bottom edges
///   while the assistant speaks, centre clear.
/// `VoiceAmbientGlow` draws those curves; this view supplies the real-size
/// controls (64 pt mic, 44 pt row, official margins).
struct VoiceCallPreview: View {
    @Binding var role: VoiceVisualizerRole
    var isDark: Bool
    var levelsProvider: (() -> [Float])?
    var onClose: () -> Void

    private let cream = Color(red: 249.0 / 255, green: 249.0 / 255, blue: 247.0 / 255)
    private let endFill = Color(red: 27.0 / 255, green: 32.0 / 255, blue: 37.0 / 255)
    private let ink = Color(red: 11.0 / 255, green: 11.0 / 255, blue: 11.0 / 255)

    var body: some View {
        ZStack {
            (isDark ? Color(red: 0.082, green: 0.082, blue: 0.082) : cream)
                .ignoresSafeArea()

            VoiceAmbientGlow(role: role, levelProvider: averageLevel)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                Spacer()
                controls
            }
        }
    }

    private var averageLevel: (() -> Float)? {
        guard let levelsProvider else { return nil }
        return {
            let bands = levelsProvider()
            guard !bands.isEmpty else { return 0 }
            return min(max(bands.reduce(0, +) / Float(bands.count), 0), 1)
        }
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Picker("发声角色", selection: $role) {
                Text("用户 · 蓝").tag(VoiceVisualizerRole.user)
                Text("助手 · 橙").tag(VoiceVisualizerRole.agent)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 220)
            Spacer(minLength: 0)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭预览")
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var controls: some View {
        VStack(spacing: 18) {
            Button(action: {}) {
                Circle()
                    .fill(.ultraThinMaterial)
                    .frame(width: 64, height: 64)
                    .overlay {
                        AppSymbol("anthropicon.microphone", size: 32)
                            .foregroundStyle(ink)
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("麦克风")

            HStack(spacing: 8) {
                circleButton(symbol: "anthropicon.add", size: 17)
                HStack(spacing: 6) {
                    Text("Sonnet")
                        .font(.system(size: 15, weight: .regular))
                        .foregroundStyle(ink)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(ink)
                }
                .padding(.horizontal, 14)
                .frame(height: 44)
                .background(.ultraThinMaterial, in: Capsule())

                Spacer(minLength: 0)

                circleButton(system: "speaker.wave.2", size: 20)

                Button(action: {}) {
                    Circle()
                        .fill(endFill)
                        .frame(width: 44, height: 44)
                        .overlay {
                            Image(systemName: "xmark")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(.white)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("结束通话")
            }
            .padding(.horizontal, 20)

            tabBar
                .padding(.horizontal, 12)
        }
        .padding(.bottom, 8)
    }

    private func circleButton(system: String? = nil, symbol: String? = nil, size: CGFloat) -> some View {
        Button(action: {}) {
            Circle()
                .fill(.ultraThinMaterial)
                .frame(width: 44, height: 44)
                .overlay {
                    if let symbol {
                        AppSymbol(symbol, size: size)
                            .foregroundStyle(ink)
                    } else if let system {
                        Image(systemName: system)
                            .font(.system(size: size, weight: .regular))
                            .foregroundStyle(ink)
                    }
                }
        }
        .buttonStyle(.plain)
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            tabItem("bubble.left", "对话", selected: true)
            tabItem("tray", "项目")
            tabItem("chevron.left.forwardslash.chevron.right", "Code")
            tabItem("square.on.square", "Artifacts")
        }
        .padding(6)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private func tabItem(_ symbol: String, _ title: String, selected: Bool = false) -> some View {
        VStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .regular))
            Text(title)
                .font(.system(size: 11))
        }
        .foregroundStyle(ink)
        .frame(maxWidth: .infinity)
        .frame(height: 52)
        .background {
            if selected {
                Capsule().fill(.white.opacity(0.55))
            }
        }
    }
}

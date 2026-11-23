import SwiftUI

/// Lab-only call-shell preview.
///
/// The official screen recording (2026-11-23) shows two distinct visible
/// layers, not one recoloured orb:
/// - the user's voice lights a wide blue cloud at the bottom, above the
///   surface the transcript sits on;
/// - the agent's voice lights an orange ring around a near-full-screen cream
///   panel: the visualizer runs behind the panel and only the feathered rim
///   lets it through.
/// The panel's opacity therefore follows the speaking role.
struct VoiceCallPreview: View {
    @Binding var role: VoiceVisualizerRole
    var isDark: Bool
    var levelsProvider: (() -> [Float])?
    var onClose: () -> Void

    @State private var panelOpacity: Double = 0.15

    private let cream = Color(red: 249.0 / 255, green: 249.0 / 255, blue: 247.0 / 255)
    private let endFill = Color(red: 27.0 / 255, green: 32.0 / 255, blue: 37.0 / 255)
    private let ink = Color(red: 11.0 / 255, green: 11.0 / 255, blue: 11.0 / 255)

    var body: some View {
        ZStack {
            VoiceVisualizerSurface(isDark: isDark,
                                   reduceMotion: false,
                                   showSlosh: false,
                                   thinking: false,
                                   liveLevels: true,
                                   role: role,
                                   levelsProvider: levelsProvider,
                                   baseYOffset: -0.15)
                .ignoresSafeArea()

            // The blurred fill is the panel: solid in the middle, feathered
            // at the rim so the glow reads as the official edge ring.
            RoundedRectangle(cornerRadius: 44, style: .continuous)
                .fill(cream)
                .padding(4)
                .blur(radius: 40)
                .opacity(panelOpacity)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                Spacer()
                controls
            }
        }
        .onAppear { panelOpacity = role == .agent ? 1.0 : 0.15 }
        .onChange(of: role) { _, newRole in
            withAnimation(.easeInOut(duration: 0.35)) {
                panelOpacity = newRole == .agent ? 1.0 : 0.15
            }
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

import SwiftUI

/// Debug-only gallery for the voice UI replica. Parameters and shader math are
/// taken from Claude iOS 1.261109.19; see
/// aa-test/claude-ios-re/CANONICAL/27-voice-ui-109.md.
struct VoiceLabView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    @StateObject private var mic = VoiceMicrophoneMeter()
    @State private var forceDark = false
    @State private var live = true
    @State private var thinking = false
    @State private var slosh = true
    @State private var reduceMotion = false
    @State private var showsDictation = false
    @State private var showsCall = false
    @State private var useMic = false
    @State private var role: VoiceVisualizerRole = .user
    @State private var verticalOffset: Float = 0

    private var isDark: Bool { forceDark || colorScheme == .dark }

    var body: some View {
        ZStack {
            (isDark ? Color(red: 0.082, green: 0.082, blue: 0.082)
                    : Color(red: 0.976, green: 0.976, blue: 0.969))
                .ignoresSafeArea()

            if showsCall {
                VoiceCallPreview(role: $role,
                                 isDark: isDark,
                                 levelsProvider: useMic ? { mic.snapshot } : nil,
                                 onClose: {
                                     withAnimation(.easeInOut(duration: 0.2)) {
                                         showsCall = false
                                     }
                                 })
                    .transition(.opacity)
            } else {
                VoiceVisualizerSurface(isDark: isDark,
                                       reduceMotion: reduceMotion,
                                       showSlosh: slosh,
                                       thinking: thinking,
                                       liveLevels: live,
                                       role: role,
                                       levelsProvider: useMic ? { mic.snapshot } : nil,
                                       baseYOffset: verticalOffset)
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    header
                    Spacer()
                    if showsDictation {
                        VoiceDictationBar(amplitude: mockLevel,
                                          onCancel: { showsDictation = false },
                                          onStop: { showsDictation = false },
                                          onSend: { showsDictation = false })
                            .padding(.horizontal, 16)
                            .padding(.bottom, 20)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    } else {
                        footer
                    }
                }
                .animation(.spring(response: 0.3, dampingFraction: 0.85), value: showsDictation)
            }
        }
        .statusBarHidden(false)
        .onChange(of: useMic) { _, isOn in
            if isOn { mic.start() } else { mic.stop() }
        }
        .onDisappear { mic.stop() }
    }

    private var microphoneNote: String? {
        switch mic.status {
        case .denied:
            return "麦克风权限被拒绝，回退到模拟电平"
        case .failed(let message):
            return "麦克风不可用：\(message)"
        case .idle, .running:
            return nil
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("语音视觉实验室")
                        .font(.system(size: 17, weight: .semibold))
                    Text("Claude iOS 1.261109.19 · 逆向参数")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 32, height: 32)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭")
            }

            Toggle("深色模式", isOn: $forceDark)
            Toggle("动态电平（模拟语音）", isOn: $live)
            Toggle("麦克风（真实音量）", isOn: $useMic)
            Picker("发声角色", selection: $role) {
                Text("用户 · 蓝").tag(VoiceVisualizerRole.user)
                Text("助手 · 橙").tag(VoiceVisualizerRole.agent)
            }
            .pickerStyle(.segmented)
            HStack(spacing: 8) {
                Text("垂直偏移")
                Slider(value: $verticalOffset, in: -0.5...0.5)
                Text(String(format: "%+.2f", verticalOffset))
                    .monospacedDigit()
                    .frame(width: 44, alignment: .trailing)
            }
            .font(.system(size: 13))
            if useMic, let note = microphoneNote {
                Text(note)
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
            }
            Toggle("Thinking", isOn: $thinking)
            Toggle("显示 slosh 液体（输入框）", isOn: $slosh)
            Toggle("听写录音条（361×52）", isOn: $showsDictation)
            Toggle("通话预览（面板边缘环）", isOn: $showsCall)
            Toggle("减少动态效果", isOn: $reduceMotion)
        }
        .font(.system(size: 14))
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    /// Deterministic stand-in for microphone power until real capture lands;
    /// the waveform samples it at past times, so the scroll stays coherent.
    private func mockLevel(_ time: Double) -> Float {
        let a = 0.5 + 0.5 * sin(time * 1.35)
        let b = 0.5 + 0.5 * sin(time * 0.61 + 1.7)
        return Float(min(max(0.22 + 0.5 * a * b, 0), 1))
    }

    private var footer: some View {
        Text("orb = 用户 #6B9CCC / 助手 #D97757 · 7 band（官方矩阵）· slosh = 品牌橙")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 24)
            .padding(.bottom, 20)
    }
}

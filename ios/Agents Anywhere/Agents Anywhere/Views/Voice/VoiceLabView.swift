import SwiftUI

/// Debug-only gallery for the voice UI replica. Parameters and shader math are
/// taken from Claude iOS 1.261109.19; see
/// aa-test/claude-ios-re/CANONICAL/27-voice-ui-109.md.
struct VoiceLabView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    @State private var forceDark = false
    @State private var live = true
    @State private var thinking = false
    @State private var slosh = true
    @State private var reduceMotion = false
    @State private var showsDictation = false

    private var isDark: Bool { forceDark || colorScheme == .dark }

    var body: some View {
        ZStack {
            (isDark ? Color(red: 0.082, green: 0.082, blue: 0.082)
                    : Color(red: 0.976, green: 0.976, blue: 0.969))
                .ignoresSafeArea()

            VoiceVisualizerSurface(isDark: isDark,
                                   reduceMotion: reduceMotion,
                                   showSlosh: slosh,
                                   thinking: thinking,
                                   liveLevels: live)
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
        .statusBarHidden(false)
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
            Toggle("Thinking", isOn: $thinking)
            Toggle("显示 slosh 液体（输入框）", isOn: $slosh)
            Toggle("听写录音条（361×52）", isOn: $showsDictation)
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
        Text("orb = voiceVisualizer（#6B9CCC · 暗 0.5 / 亮 0.75）· 7 band · slosh = 品牌橙 #D97757")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 24)
            .padding(.bottom, 20)
    }
}

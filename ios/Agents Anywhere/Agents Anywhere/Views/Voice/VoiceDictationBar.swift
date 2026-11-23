import SwiftUI

/// Recording pill that replaces the composer while dictating.
///
/// Geometry and colors come from the official device screenshots
/// (1179×2556 @3x → 393×852 pt), cross-checked against the binary:
/// outer Capsule 361×52 pt (16 pt screen margins), 8 pt inner padding,
/// three 36 pt circles. Cancel/stop fill #F0EFEC with #131313 ink,
/// send fill #C6603F with a white arrow, pill fill #FBFBF9 with a white
/// highlight edge, waveform ink #131313.
/// Evidence: aa-test/claude-ios-re/CANONICAL/27-voice-ui-109.md §2.3, §8.2.
struct VoiceDictationBar: View {
    var amplitude: (Double) -> Float
    var onCancel: () -> Void
    var onStop: () -> Void
    var onSend: () -> Void

    private let ink = Color(red: 19.0 / 255, green: 19.0 / 255, blue: 19.0 / 255)
    private let controlFill = Color(red: 240.0 / 255, green: 239.0 / 255, blue: 236.0 / 255)
    private let pillFill = Color(red: 251.0 / 255, green: 251.0 / 255, blue: 249.0 / 255)
    private let sendFill = Color(red: 198.0 / 255, green: 96.0 / 255, blue: 63.0 / 255)

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(ink)
                    .frame(width: 36, height: 36)
                    .background(controlFill, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "取消录音"))
            .accessibilityIdentifier("voiceDictation.cancel")

            VoiceWaveformView(amplitude: amplitude)
                .frame(maxWidth: .infinity)

            Button(action: onStop) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(ink)
                    .frame(width: 36, height: 36)
                    .background(controlFill, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "停止录音"))
            .accessibilityIdentifier("voiceDictation.stop")

            Button(action: onSend) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(sendFill, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "发送"))
            .accessibilityIdentifier("voiceDictation.send")
        }
        .padding(8)
        .frame(height: 52)
        .background(pillFill, in: Capsule())
        .overlay {
            Capsule().strokeBorder(.white.opacity(0.9), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.06), radius: 8, y: 2)
    }
}

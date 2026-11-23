import SwiftUI

/// Scrolling waveform recovered from Claude iOS 1.261109.19
/// (`ClaudeMediaUI.ScrollingWaveform` + `ClaudeVoiceUI.SpeechWaveformView`).
///
/// Parameters are transcribed from the binary, not eyeballed:
/// pitch 6 pt, bar 3 pt Capsule, base height 3 pt, max height 25 pt,
/// 3-bar (18 pt) edge fade, phase = time mod 0.06 s (~100 pt/s),
/// `TimelineView(.animation)` with the default schedule.
/// Evidence: aa-test/claude-ios-re/CANONICAL/27-voice-ui-109.md §2.2.
struct VoiceWaveformView: View {
    /// Amplitude in 0...1 sampled at a past time, exactly like the official
    /// `amplitude: (Double) -> Float?` closure.
    var amplitude: (Double) -> Float
    var maxHeight: CGFloat = 25
    var color: Color = Color(red: 19.0 / 255, green: 19.0 / 255, blue: 19.0 / 255)

    private let pitch: CGFloat = 6
    private let barWidth: CGFloat = 3
    private let baseHeight: CGFloat = 3
    private let fadeBars: Double = 3

    var body: some View {
        TimelineView(.animation) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            Canvas(opaque: false, colorMode: .nonLinear, rendersAsynchronously: false) { context, size in
                draw(context: &context, size: size, time: time)
            }
        }
        .frame(maxHeight: maxHeight)
        .accessibilityHidden(true)
    }

    private func draw(context: inout GraphicsContext, size: CGSize, time: Double) {
        guard size.width > 0, size.height > 0 else { return }
        let height = min(size.height, maxHeight)
        let count = Int(ceil(size.width / pitch)) + 1
        // Sub-pitch phase: time mod 0.06 s, one pitch step per 0.06 s.
        let phase = time.truncatingRemainder(dividingBy: 0.06) / 0.06
        let startX = -CGFloat(phase) * pitch
        let last = Double(count - 1)

        for index in 0..<count {
            let x = startX + CGFloat(index) * pitch
            if x + barWidth < 0 || x > size.width { continue }

            // Newest sample sits at the trailing edge; each bar samples one
            // 0.06 s further into the past as it moves left.
            let fromRight = last - Double(index)
            let sample = amplitude(time - 0.06 * fromRight)
            let level = min(max(Double(sample), 0), 1)

            // fade = clamp(1 - min(pos, count-pos)/3, 0, 1); sqrt(1-fade²)
            let edge = min(Double(index), fromRight)
            let fade = min(max(1 - edge / fadeBars, 0), 1)
            let shape = (1 - fade * fade).squareRoot()
            let barHeight = shape * (Double(baseHeight) + level * Double(maxHeight - baseHeight))

            let rect = CGRect(x: x,
                              y: (height - CGFloat(barHeight)) / 2,
                              width: barWidth,
                              height: CGFloat(barHeight))
            context.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2),
                         with: .color(color))
        }
    }
}

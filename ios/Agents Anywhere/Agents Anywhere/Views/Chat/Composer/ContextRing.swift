import SwiftUI

/// Level palette for the context ring, bar and status copy. The thresholds and
/// arithmetic stay in ClientCore (`ContextLevel`); only the colors live here.
extension ContextLevel {
    var color: Color {
        switch self {
        case .comfortable: Color(red: 29 / 255, green: 158 / 255, blue: 117 / 255)   // #1D9E75
        case .normal: Color(red: 99 / 255, green: 153 / 255, blue: 34 / 255)          // #639922
        case .elevated: Color(red: 239 / 255, green: 159 / 255, blue: 39 / 255)       // #EF9F27
        case .tight: Color(red: 216 / 255, green: 90 / 255, blue: 48 / 255)           // #D85A30
        case .critical: Color(red: 226 / 255, green: 75 / 255, blue: 74 / 255)        // #E24B4A
        }
    }
}

/// The 18 pt usage ring. The arc starts at 12 o'clock and grows clockwise;
/// at critical usage it breathes unless the user reduces motion.
struct ContextRing: View {
    let fraction: Double
    var size: CGFloat = ChatControlMetrics.contextRingDiameter
    var lineWidth: CGFloat = 2.5
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathe = false

    private var level: ContextLevel { ContextLevel(fraction: fraction) }
    private var isBreathing: Bool { level == .critical && !reduceMotion }

    var body: some View {
        ZStack {
            Circle().stroke(level.color.opacity(0.22), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(fraction, 0.02))
                .stroke(level.color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
        .animation(.smooth(duration: 0.35), value: fraction)
        .animation(.smooth(duration: 0.35), value: level)
        .opacity(isBreathing && breathe ? 0.5 : 1)
        .animation(isBreathing ? .easeInOut(duration: 1.4).repeatForever(autoreverses: true) : .default, value: breathe)
        .onAppear { breathe = isBreathing }
        .onChange(of: isBreathing) { _, newValue in breathe = newValue }
    }
}

/// Composer control that opens the usage popover. The visual ring stays 18 pt;
/// the hit slot matches the other composer controls (`controls.touchTarget`).
struct ContextRingButton: View {
    let usage: ContextUsage
    var touchTarget: CGFloat = 44
    @State private var showsDetails = false

    private var level: ContextLevel { ContextLevel(fraction: usage.fraction) }
    private var remainingText: String { "\(usage.remainingPercent)%" }

    var body: some View {
        Button { showsDetails = true } label: {
            ContextRing(fraction: usage.fraction)
                .frame(width: touchTarget, height: touchTarget)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "上下文窗口"))
        .accessibilityValue(String(localized: "剩余 \(remainingText)，\(level.title)"))
        .accessibilityIdentifier("chat.composer.contextUsage")
        .popover(isPresented: $showsDetails) {
            ContextPopoverContent(usage: usage)
                .presentationCompactAdaptation(.popover)
        }
        // One warning when the level first reaches tight or worse.
        .sensoryFeedback(trigger: level) { old, new in
            new > old && new >= .tight ? .warning : nil
        }
    }
}

/// The popover body: title with status, remaining summary and a 4 pt bar. The
/// system popover supplies the background material; this view adds none.
struct ContextPopoverContent: View {
    let usage: ContextUsage

    private var level: ContextLevel { ContextLevel(fraction: usage.fraction) }
    private var remainingText: String { "\(usage.remainingPercent)%" }
    private var usedText: String { TokenFormat.wan(usage.used) }
    private var totalText: String { TokenFormat.wan(usage.total) }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(String(localized: "上下文窗口")).font(.subheadline.weight(.medium))
                Spacer(minLength: 8)
                Text(level.title).font(.footnote.weight(.medium)).foregroundStyle(level.color)
            }
            Text(String(localized: "剩余 \(remainingText)（已用 \(usedText) / \(totalText)）"))
                .font(.footnote)
                .foregroundStyle(.secondary)
            usageBar.padding(.top, 8)
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 16)
        .frame(width: 250)
    }

    private var usageBar: some View {
        Capsule()
            .fill(level.color.opacity(0.22))
            .frame(height: 4)
            .overlay {
                GeometryReader { proxy in
                    Capsule()
                        .fill(level.color)
                        .frame(width: proxy.size.width * max(usage.fraction, 0.02))
                }
            }
            .accessibilityHidden(true)
    }
}

#Preview("Context usage ring") {
    ScrollView {
        VStack(spacing: 28) {
            ForEach([0.06, 0.50, 0.68, 0.83, 0.96], id: \.self) { fraction in
                let usage = ContextUsage(used: Int((fraction * 260_000).rounded()), total: 260_000)
                VStack(spacing: 14) {
                    ContextRingButton(usage: usage)
                    ContextPopoverContent(usage: usage)
                }
            }
        }
        .padding(24)
    }
}

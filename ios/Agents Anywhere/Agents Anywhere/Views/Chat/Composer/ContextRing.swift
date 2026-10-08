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

/// The ring's neutral stand-in for a real measurement whose window is not yet
/// known — a gateway model before its first calibration. It is deliberately
/// colourless, arcless and glyphless so it can never be read as a percentage,
/// but it stays on screen: pp 2026-10-08, the ring must never simply disappear,
/// and pp 2026-10-08 the plain grey ring alone is the whole signal (the popover
/// and the accessibility value say "window unknown" in words).
struct ContextUnknownRing: View {
    var size: CGFloat = ChatControlMetrics.contextRingDiameter
    var lineWidth: CGFloat = 2.5

    var body: some View {
        Circle()
            .stroke(Color.secondary.opacity(0.45), lineWidth: lineWidth)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// Composer control that opens the usage popover. The visual ring stays 18 pt;
/// the hit slot matches the other composer controls (`controls.touchTarget`).
/// It draws the arc when the window is known and the neutral unknown ring when
/// only the window is missing; the caller only builds it for a visible state
/// (`ContextRingState.isVisible`), so the `.hidden` case never reaches it.
struct ContextRingButton: View {
    let state: ContextRingState
    var touchTarget: CGFloat = 44
    @State private var showsDetails = false

    /// The complete usage, or nil in the unknown / hidden states.
    private var level: ContextLevel? {
        if case .ready(let usage) = state { return ContextLevel(fraction: usage.fraction) }
        return nil
    }

    var body: some View {
        Button { showsDetails = true } label: {
            ring
                .frame(width: touchTarget, height: touchTarget)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "上下文窗口"))
        .accessibilityValue(accessibilityValue)
        .accessibilityIdentifier("chat.composer.contextUsage")
        .popover(isPresented: $showsDetails) {
            ContextPopoverContent(state: state)
                .presentationCompactAdaptation(.popover)
        }
        // One warning when the level first reaches tight or worse. The unknown
        // state carries no level, so it never fires.
        .sensoryFeedback(trigger: level) { old, new in
            guard let old, let new, new > old, new >= .tight else { return nil }
            return .warning
        }
    }

    @ViewBuilder private var ring: some View {
        if case .ready(let usage) = state {
            ContextRing(fraction: usage.fraction)
        } else {
            ContextUnknownRing()
        }
    }

    /// Sighted users read the arc; VoiceOver reads the numbers. The unknown
    /// state names the real `used` and says the window is unknown — it never
    /// claims a percentage it cannot compute.
    private var accessibilityValue: String {
        switch state {
        case .ready(let usage):
            // A String argument keeps the "剩余 %@，%@" catalog key (an inlined
            // Int would extract as %lld).
            let remaining = "\(usage.remainingPercent)%"
            return String(localized: "剩余 \(remaining)，\(ContextLevel(fraction: usage.fraction).title)")
        case .unknownWindow(let used):
            return String(localized: "已用 \(TokenFormat.wan(used))，窗口未知")
        case .hidden:
            return ""
        }
    }
}

/// The popover body: title with status, remaining summary and a 4 pt bar. The
/// system popover supplies the background material; this view adds none. The
/// unknown state replaces the summary and bar with "已用 X，窗口未知" and a
/// neutral grey stripe, so it never prints "0" or a fabricated percentage.
struct ContextPopoverContent: View {
    let state: ContextRingState

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            switch state {
            case .ready(let usage):
                let level = ContextLevel(fraction: usage.fraction)
                titleRow(status: level.title, tint: level.color)
                Text(summary(usage))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                usageBar(fraction: usage.fraction, tint: level.color)
                    .padding(.top, 8)
            case .unknownWindow(let used):
                titleRow(status: String(localized: "未知"), tint: .secondary)
                Text(String(localized: "已用 \(TokenFormat.wan(used))，窗口未知"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                usageBar(fraction: 0, tint: .secondary)
                    .padding(.top, 8)
            case .hidden:
                EmptyView()
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 16)
        .frame(width: 250)
    }

    /// The ready summary. A String argument keeps the "剩余 %@（已用 %@ / %@）"
    /// catalog key (inlining an Int would extract as %lld).
    private func summary(_ usage: ContextUsage) -> String {
        let remaining = "\(usage.remainingPercent)%"
        return String(localized: "剩余 \(remaining)（已用 \(TokenFormat.wan(usage.used)) / \(TokenFormat.wan(usage.total))）")
    }

    private func titleRow(status: String, tint: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(String(localized: "上下文窗口")).font(.subheadline.weight(.medium))
            Spacer(minLength: 8)
            Text(status).font(.footnote.weight(.medium)).foregroundStyle(tint)
        }
    }

    /// A 4 pt bar. At `fraction == 0` nothing is filled — the unknown state's
    /// neutral track, which is never drawn as an arc.
    private func usageBar(fraction: Double, tint: Color) -> some View {
        Capsule()
            .fill(tint.opacity(0.22))
            .frame(height: 4)
            .overlay {
                GeometryReader { proxy in
                    Capsule()
                        .fill(tint)
                        .frame(width: proxy.size.width * (fraction > 0 ? max(fraction, 0.02) : 0))
                }
            }
            .accessibilityHidden(true)
    }
}

#Preview("Context usage ring") {
    ScrollView {
        VStack(spacing: 28) {
            ForEach([0.06, 0.50, 0.68, 0.83, 0.96], id: \.self) { fraction in
                let state = ContextRingState.ready(
                    ContextUsage(used: Int((fraction * 260_000).rounded()), total: 260_000))
                VStack(spacing: 14) {
                    ContextRingButton(state: state)
                    ContextPopoverContent(state: state)
                }
            }
            VStack(spacing: 14) {
                ContextRingButton(state: .unknownWindow(used: 15_600))
                ContextPopoverContent(state: .unknownWindow(used: 15_600))
            }
        }
        .padding(24)
    }
}

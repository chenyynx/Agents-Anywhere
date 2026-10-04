import SwiftUI

/// L2 (§3.2): the glass capsule above the composer that says a SubAgent is
/// still running. Visibility is data-driven (a running top-level Agent card in
/// the presented window) — never scroll or keyboard state. It is the first
/// tinted glass in the app: a light smoke with a blue bot mark while
/// running, red glass with a red bot mark while the newest batch carries a
/// failure — dispatching a new SubAgent clears older failures
/// (`SubAgentProgress.hasLiveFailure`). Like the “到底部” pill, the capsule
/// hugs its label instead of claiming a fixed maximum width.
struct SubAgentCapsule: View {
    let state: SubAgentCapsuleState
    let onOpen: () -> Void
    @ScaledMetric(relativeTo: .footnote) private var height: CGFloat = 36
    @ScaledMetric(relativeTo: .footnote) private var markSize: CGFloat = 18

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 6) {
                Image("aa-Bot").resizable().scaledToFit().frame(width: markSize, height: markSize)
                    .foregroundStyle(SubAgentPalette.capsuleIcon(failure: state.hasFailure))
                    .accessibilityHidden(true)
                Text(state.title)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, 14)
            .frame(height: height)
            .glassEffect(.regular.interactive().tint(SubAgentPalette.capsuleTint(failure: state.hasFailure)), in: .capsule)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("chat.subagent.capsule")
        .accessibilityLabel(state.accessibilityText)
        .accessibilityHint(String(localized: "查看详情"))
        .padding(.bottom, 2)
    }
}

/// The SubAgent concept colors, single point: running is blue, the semantic
/// colors (green done / red failure) carry over from the rest of the app. The
/// running capsule wears a light neutral smoke — not a hue — so the blue bot
/// mark carries the state; failure stays red. Both tints stay low-opacity so
/// the capsule still reads as glass beside the neutral “到底部” and takeover
/// pills (pp 2026-10-05: 再透一点 — dropped another step).
enum SubAgentPalette {
    static let running = Color.blue
    static let failure = Color.red
    static let completed = Color.green

    static func phase(_ phase: SubAgentPhase) -> Color {
        switch phase {
        case .running: return running
        case .completed: return completed
        case .failed, .interrupted: return failure
        case .unknown: return .secondary
        }
    }

    static func capsuleIcon(failure: Bool) -> Color {
        failure ? Self.failure : running
    }

    static func capsuleTint(failure: Bool) -> Color {
        failure ? Self.failure.opacity(0.26) : Color.black.opacity(0.12)
    }
}

import SwiftUI

/// L2 (§3.2): the glass capsule above the composer that says a SubAgent is
/// still running. Visibility is data-driven (a running top-level Agent card in
/// the presented window) — never scroll or keyboard state. It is the first
/// tinted glass in the app: indigo while running, red while the newest batch
/// carries a failure — dispatching a new SubAgent clears older failures
/// (`SubAgentProgress.hasLiveFailure`).
struct SubAgentCapsule: View {
    let state: SubAgentCapsuleState
    let onOpen: () -> Void
    @ScaledMetric(relativeTo: .caption) private var height: CGFloat = 32

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 6) {
                Circle().fill(SubAgentPalette.capsuleDot(failure: state.hasFailure))
                    .frame(width: 7, height: 7)
                Text(state.title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, 12)
            .frame(height: height)
            .frame(maxWidth: 280)
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

/// The SubAgent concept colors, single point: running is the new indigo, the
/// semantic colors (green done / red failure) carry over from the rest of the
/// app. The glass tint stays low-saturation so the colored capsule still reads
/// as glass beside the neutral “到底部” and takeover pills.
enum SubAgentPalette {
    static let running = Color.indigo
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

    static func capsuleDot(failure: Bool) -> Color {
        failure ? failure : running
    }

    static func capsuleTint(failure: Bool) -> Color {
        failure ? Color.red.opacity(0.40) : Color.indigo.opacity(0.45)
    }
}

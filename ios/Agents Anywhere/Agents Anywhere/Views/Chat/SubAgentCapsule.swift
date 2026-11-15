import SwiftUI

/// L2 (§3.2): the glass capsule above the composer that says a SubAgent is
/// still running. Visibility is data-driven (a running top-level Agent card in
/// the presented window) — never scroll or keyboard state. While running it is
/// the plain glass with the `SubAgentStarGlyph` mark; while the newest batch
/// carries a failure the glass is tinted red and the mark is repainted red —
/// dispatching a new SubAgent clears older failures
/// (`SubAgentProgress.hasLiveFailure`). Like the “到底部” pill, the capsule
/// hugs its label instead of claiming a fixed maximum width.
///
/// Size follows the reference capsule (pp 2026-11-15): 41pt tall, 15pt side
/// padding, 13pt label, 16pt mark — measured from a 1179×2556 @3x screenshot
/// (123px tall, 44.5px side padding, 49×35px mark).
struct SubAgentCapsule: View {
    let state: SubAgentCapsuleState
    let onOpen: () -> Void
    @ScaledMetric(relativeTo: .footnote) private var height: CGFloat = 41
    @ScaledMetric(relativeTo: .footnote) private var glyphSize: CGFloat = 16

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 8) {
                SubAgentStarGlyph(size: glyphSize,
                                  tint: state.hasFailure ? SubAgentPalette.failure : .primary)
                Text(state.title)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                AppSymbol("chevron.right", size: 12)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 15)
            .frame(height: height)
            .glassEffect(state.hasFailure
                         ? .regular.interactive().tint(SubAgentPalette.failure.opacity(0.26))
                         : .regular.interactive(),
                         in: .capsule)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("chat.subagent.capsule")
        .accessibilityLabel(String(localized: "子代理运行中"))
        .accessibilityValue(state.accessibilityText)
        .accessibilityHint(String(localized: "查看详情"))
        .padding(.bottom, 2)
    }
}

/// The capsule's own leaf (S2), docked as the composer dock's first row
/// (B, pp 2026-10-06): only this view reads the presented rows, so a streamed
/// token re-evaluates one capsule instead of the dock that hosts it. It is
/// empty — not hidden — without a running SubAgent, so a hidden capsule never
/// leaves a phantom gap between the timeline and the composer. The rows are
/// read together with the projection's active-card sidecar: a card that later
/// traffic pushed out of the loaded window still holds the capsule open
/// (ios-capsule-activity-window §2).
struct SubAgentCapsuleSlot: View {
    let model: SessionChatModel
    let onOpen: (String) -> Void

    var body: some View {
        let state = SubAgentProgress.capsuleState(inWindow: model.timeline.rows.map(\.value),
                                                  activeCards: model.session.activeAgentCards)
        if state.isVisible {
            SubAgentCapsule(state: state) {
                if let id = state.latestRunningID { onOpen(id) }
            }
        }
    }
}

/// §A3: the one stop control the SubAgent surfaces share — the panel header
/// and the Agent card's timeline fold. It is the composer's official stop
/// affordance at row scale: same symbol, same primary-control colors, same
/// disabled wash. One control carries one `SubAgentTask`, so its button is
/// always bound to exactly one task id; a card with several live tasks
/// renders one named control per task (逐条渲染), and the single-task case
/// stays the bare control.
struct SubAgentStopControl: View {
    let task: SubAgentTask
    /// Show the task's own data-sourced name beside the control.
    let showsName: Bool
    /// The stop request is accepted and the card has not converged: the
    /// control shows its in-flight disabled form until either lands.
    let isStopping: Bool
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric(relativeTo: .footnote) private var diameter: CGFloat = 26
    @AppStorage(AppAccent.storageKey) private var accentValue = AppAccent.storageDefault.rawValue
    private var accent: AppAccent { AppAccent.resolve(accentValue) }

    var body: some View {
        HStack(spacing: 4) {
            if showsName, let label = task.label {
                Text(label)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Button(action: action) {
                AppSymbol("stop.fill", size: 12)
                    .foregroundStyle(AppTheme.accentForeground(accent, colorScheme))
                    .frame(width: diameter, height: diameter)
                    .background(AppTheme.accentBackground(accent, colorScheme).opacity(isStopping ? 0.42 : 1), in: Circle())
                    .frame(minHeight: 32)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(isStopping)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityIdentifier("chat.subagent.stop.\(task.taskID)")
        }
    }

    /// Minimal by design: the control is the feature's own body. The entry's
    /// name joins only when controls are stacked, so a multi-task card's
    /// buttons are told apart by voice.
    private var accessibilityLabel: String {
        let base = String(localized: "停止子代理")
        guard showsName, let label = task.label else { return base }
        return "\(base) \(label)"
    }
}

/// The SubAgent concept colors, single point: running is blue, the semantic
/// colors (green done / red failure) carry over from the rest of the app. The
/// running capsule is plain glass with the phase-coloured glyph carrying the
/// state; a failure tints that glass red (low opacity, so it still reads as
/// glass beside the neutral “到底部” and takeover pills — pp 2026-10-05).
enum SubAgentPalette {
    static let running = Color.blue
    static let failure = Color.red
    static let completed = Color.green

    static func phase(_ phase: SubAgentPhase) -> Color {
        switch phase {
        // Starting borrows the running hue on purpose: it is the same work one
        // step earlier, and a fourth color here would read as a second,
        // unexplained state in a badge that has no room to explain itself.
        case .running, .starting: return running
        case .completed: return completed
        case .failed, .interrupted: return failure
        case .unknown: return .secondary
        }
    }
}

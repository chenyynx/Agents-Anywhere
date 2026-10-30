import SwiftUI

/// The SubAgent entry above the composer, in AA's own design: a circular
/// liquid-glass button on the trailing edge, icon only (pp 2026-10-30).
/// Visibility and state stay data-driven from `SubAgentCapsuleState` — the
/// button disappears with the last active card, and a finished SubAgent stays
/// readable from its timeline tool row. The icon is the official
/// `anthropicon.agent` asset; a failure tints the glass and icon red, and
/// several running SubAgents carry a small count badge.
struct SubAgentRoundButton: View {
    let state: SubAgentCapsuleState
    let onOpen: () -> Void
    @ScaledMetric(relativeTo: .body) private var diameter: CGFloat = 40
    @ScaledMetric(relativeTo: .caption2) private var badgeSize: CGFloat = 16

    var body: some View {
        Button(action: onOpen) {
            Circle()
                .fill(.clear)
                .frame(width: diameter, height: diameter)
                .glassEffect(state.hasFailure
                             ? .regular.interactive().tint(SubAgentPalette.failure.opacity(0.26))
                             : .regular.interactive(),
                             in: .circle)
                .overlay {
                    AnthropiconView(name: "anthropicon.agent", size: .large)
                        .foregroundStyle(state.hasFailure ? SubAgentPalette.failure : Color.primary)
                }
                .overlay(alignment: .topTrailing) {
                    if state.runningCount > 1 {
                        Text("\(state.runningCount)")
                            .font(.system(size: 9, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                            .frame(width: badgeSize, height: badgeSize)
                            .background(state.hasFailure ? SubAgentPalette.failure : SubAgentPalette.running,
                                        in: .circle)
                            .offset(x: 3, y: -3)
                    }
                }
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("chat.subagent.roundButton")
        .accessibilityLabel(String(localized: "子代理运行中"))
        .accessibilityValue(state.accessibilityText)
        .accessibilityHint(String(localized: "查看详情"))
    }
}

/// The round button's own leaf (S2), docked as the composer dock's first row:
/// only this view reads the presented rows, so a streamed token re-evaluates
/// one button instead of the dock that hosts it. It is empty — not hidden —
/// without a running SubAgent, so a hidden button never leaves a phantom gap
/// between the timeline and the composer. The rows are read together with the
/// projection's active-card sidecar: a card that later traffic pushed out of
/// the loaded window still holds the button open (ios-capsule-activity-window
/// §2). The dock right-aligns this leaf; the button's state and visibility are
/// unchanged from the old capsule.
struct SubAgentCapsuleSlot: View {
    let model: SessionChatModel
    let onOpen: (String) -> Void

    var body: some View {
        let state = SubAgentProgress.capsuleState(inWindow: model.timeline.rows.map(\.value),
                                                  activeCards: model.session.activeAgentCards)
        if state.isVisible {
            SubAgentRoundButton(state: state) {
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
    @AppStorage(AppAccent.storageKey) private var accentValue = AppAccent.default.rawValue
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

import SwiftUI

/// The SubAgent surfaces' shared chrome.
///
/// The running-state entry moved out of the composer dock and into the
/// navigation bar on 2026-11-18 (`SubAgentToolbarButton`), so the capsule this
/// file was named after is gone. What stays here is what the panel, the
/// timeline folds and the Agent list still share: the one stop control and the
/// concept colours.

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
/// colors (green done / red failure) carry over from the rest of the app.
/// The toolbar mark does not use `running` — it wears the navigation bar's
/// own `text300` ink, swapping in the tool row's red
/// (`CodePageTheme.failureGlyphFailedColor`) while a failure shows — so this
/// palette stays the vocabulary the panel and previews use.
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

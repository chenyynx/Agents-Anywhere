import SwiftUI

/// One SubAgent entry on the list page that opens from the circular glass
/// button. The row is AA's own layout: a large rounded card with the official
/// agent asset, the card's title, the live phase (plus its last tool), and the
/// existing telemetry metrics. A card with exactly one live task gets the
/// compact stop control on the trailing edge; a multi-task card is stopped
/// from its detail page so every control still names one task.
struct SubAgentListRow: View {
    let card: SubAgentCard
    let now: Date?
    /// Empty unless this card has exactly one live task (the row-level stop).
    let stopTasks: [SubAgentTask]
    let stoppingTaskIDs: Set<String>
    let onTap: () -> Void
    let onStop: (String) -> Void

    @Environment(\.colorScheme) private var colorScheme
    /// Room for the trailing stop control, scaled with the type size so an
    /// accessibility-size control never overlaps the title.
    @ScaledMetric(relativeTo: .footnote) private var stopReserve: CGFloat = 44

    private var phaseColor: Color { SubAgentPalette.phase(card.phase) }

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .center, spacing: 14) {
                ZStack {
                    Circle().fill(phaseColor.opacity(0.14))
                    AnthropiconView(name: "anthropicon.agent", size: .large)
                        .foregroundStyle(phaseColor)
                }
                .frame(width: 40, height: 40)

                VStack(alignment: .leading, spacing: 4) {
                    Text(card.taskName)
                        .font(.custom(CodePageTheme.sansFontName, size: 17,
                                      relativeTo: .body).weight(.semibold))
                        .foregroundStyle(CodePageTheme.userBubbleText.resolved(for: colorScheme))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(subtitle)
                        .font(.custom(CodePageTheme.sansFontName, size: 15,
                                      relativeTo: .subheadline))
                        .foregroundStyle(CodePageTheme.text300Color.resolved(for: colorScheme))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if !metrics.isEmpty {
                        HStack(spacing: 10) {
                            ForEach(Array(metrics.enumerated()), id: \.offset) { _, metric in
                                HStack(spacing: 3) {
                                    AppSymbol(metric.symbol, size: 11)
                                        .foregroundStyle(.tertiary)
                                    Text(metric.value)
                                        .font(.custom(CodePageTheme.sansFontName, size: 13,
                                                      relativeTo: .footnote))
                                        .foregroundStyle(.secondary)
                                        .monospacedDigit()
                                        .lineLimit(1)
                                }
                            }
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            // Keep the title clear of the trailing stop control; the whole
            // padded card stays tappable because the padding is in the label.
            .padding(.trailing, stopTasks.isEmpty ? 0 : stopReserve)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(card.taskName)
        .accessibilityValue(accessibilityValueText)
        .accessibilityHint(String(localized: "查看详情"))
        .background(CodePageTheme.userBubbleFill.resolved(for: colorScheme),
                    in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(alignment: .trailing) {
            if stopTasks.count == 1, let task = stopTasks.first {
                SubAgentStopControl(task: task, showsName: false,
                                    isStopping: stoppingTaskIDs.contains(task.taskID)) {
                    onStop(task.taskID)
                }
                .frame(minWidth: 44, minHeight: 44)
                .padding(.trailing, 12)
            }
        }
    }

    /// 「正在运行 <last tool>」 while a task is live, else the phase word. The
    /// entry's data is the same one the capsule and panel read; no new wire
    /// field.
    private var subtitle: String {
        if card.phase.isActive, let tool = card.liveTasks.first?.lastToolName, !tool.isEmpty {
            return String(localized: "正在运行 \(tool)")
        }
        return card.phase.word
    }

    /// The spoken value: the live tool line (when it adds something beyond
    /// the phase) plus the stored telemetry. The stats label already starts
    /// with the phase word, so a bare phase is not repeated.
    private var accessibilityValueText: String {
        let stats = SubAgentProgress.statsAccessibilityLabel(for: card)
        return subtitle == card.phase.word ? stats : "\(subtitle)，\(stats)"
    }

    private var metrics: [SubAgentProgress.SubAgentMetric] {
        SubAgentProgress.metrics(for: card, now: now)
    }
}

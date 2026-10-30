import SwiftUI

/// The chat profile's step-group detail: the ordered step list behind one
/// step-group row. A thinking step pushes its markdown; a tool step pushes the
/// existing single-call page (`CodeToolCallDetailView`).
///
/// The official sheet roots the same ordered `steps` list (`EVIDENCE/round29`
/// §3: `StepSheetModel` → `FoldedStepsTimeline` → per-step previews); AA reuses
/// its own detail pages for the pushed level.
struct CodeStepGroupDetailView: View {
    let group: TimelineStepGroup
    let cwd: String?
    /// The adapter's live groups. While the turn streams, the sheet reads the
    /// current group instead of the tapped snapshot: a running step settles in
    /// place and newly emitted calls append at the tail (pp 2026-10-30). The
    /// snapshot is the fallback once the group leaves the timeline window.
    var liveGroups: TimelineLiveStepGroups? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityDifferentiateWithoutColor)
    private var differentiateWithoutColor
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var path: [Route] = []

    enum Route: Hashable {
        /// Carries the step id so the pushed page can follow the live text;
        /// the tapped text is the fallback once the step leaves the group.
        case thinking(id: String, fallback: String)
        case tool(CodeToolCall)
    }

    private var liveGroup: TimelineStepGroup {
        liveGroups?.groups[group.id] ?? group
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollViewReader { proxy in
                List {
                    // One list row per element: a step cell and its inter-row
                    // connector are separate rows. Bundling the connector into
                    // the step's own cell made the previously-last cell grow
                    // when a step was appended, and List could hold the old
                    // height until a later layout pass (pp: the last rows'
                    // spacing looked wrong, then healed by itself).
                    ForEach(detailRows) { row in
                        switch row {
                        case let .step(step):
                            row(for: step)
                                .listRowInsets(CodePageTheme.groupListRowInsets)
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                        case .connector:
                            // The Code page's group sheet draws the 2 × 16 pt
                            // `TimelineConnector` between rows, centred in the
                            // 24 pt icon column (`CodeToolGroupDetailView`); the
                            // chat sheet lists the same ordered steps, so it
                            // carries the same connector.
                            CodeTimelineConnector()
                                .listRowInsets(CodePageTheme.groupListRowInsets)
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                // Open on the newest step: a live group keeps growing at the
                // tail, so the reader should land where the work is happening
                // instead of the top of the list (pp 2026-10-30). Appends keep
                // following the tail through the `onChange` scroll below.
                .defaultScrollAnchor(.bottom)
                // The official StepSheet grows downward while the turn runs: a
                // newly emitted call slides in at the tail (pp 2026-10-30).
                // Only the count is animated; streaming text redraws in place.
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.2),
                           value: liveGroup.steps.count)
                .onChange(of: liveGroup.steps.count) { _, _ in
                    guard let lastID = liveGroup.steps.last?.id else { return }
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                        proxy.scrollTo(lastID, anchor: .bottom)
                    }
                }
                .background(CodePageTheme.pageBackgroundColor.resolved(for: colorScheme)
                    .ignoresSafeArea())
                .navigationTitle(Text(title))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { SheetCloseToolbar { dismiss() } }
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case let .thinking(id, fallback):
                        ScrollView {
                            // The thinking body streams: the pushed page reads
                            // the live step text on every group update instead
                            // of the snapshot taken at tap time (pp 2026-10-30).
                            CodeThinkingMarkdownView(text: liveThinkingText(id: id) ?? fallback)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(16)
                        }
                        .background(CodePageTheme.pageBackgroundColor.resolved(for: colorScheme)
                            .ignoresSafeArea())
                        .navigationTitle(Text(String(localized: "thought_process")))
                        .navigationBarTitleDisplayMode(.inline)
                    case let .tool(call):
                        CodeToolCallDetailView(call: call)
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    /// The sheet's flat row list: each step followed by its connector (except
    /// after the last step). Separate cells keep every existing row's height
    /// constant when a new step arrives at the tail.
    private enum DetailRow: Identifiable {
        case step(TimelineStep)
        case connector(id: String)

        var id: String {
            switch self {
            case let .step(step): step.id
            case let .connector(id): id
            }
        }
    }

    private var detailRows: [DetailRow] {
        let steps = liveGroup.steps
        var rows: [DetailRow] = []
        rows.reserveCapacity(max(0, steps.count * 2 - 1))
        for (index, step) in steps.enumerated() {
            rows.append(.step(step))
            if index < steps.count - 1 {
                rows.append(.connector(id: "connector:" + steps[index + 1].id))
            }
        }
        return rows
    }

    private var title: String {
        TimelineStepSummaryText.line(
            TimelineStepSummarizer.summary(steps: liveGroup.steps, cwd: cwd))
    }

    /// The live thinking body for the pushed page; `nil` once the step leaves
    /// the group, where the tapped snapshot takes over.
    private func liveThinkingText(id: String) -> String? {
        liveGroup.steps.first { $0.id == id }?.thinkingText
    }

    @ViewBuilder
    private func row(for step: TimelineStep) -> some View {
        switch step {
        case let .thinking(id, text, status):
            Button {
                path.append(.thinking(id: id, fallback: text))
            } label: {
                CodeStepDetailRow(
                    leading: status.isActive
                        ? .mark(.think)
                        : .icon("anthropicon.extendedThinking", .medium),
                    text: thinkingRowText(text),
                    shimmers: status.isActive)
            }
            .buttonStyle(.plain)
        case let .tool(call):
            let label = CodeToolLabels.label(for: [call], cwd: cwd)
            let runs = CodeToolLabels.runs(for: label,
                                           differentiateWithoutColor: differentiateWithoutColor)
            Button {
                path.append(.tool(call))
            } label: {
                CodeStepDetailRow(
                    leading: call.status == .running
                        ? .mark(CodeWorkingMarkPose.body(forToolName: call.name))
                        : .icon(CodeToolLabels.anthropicon(for: call), .large),
                    text: CodeToolLabelRun.styledText(runs, scheme: colorScheme),
                    diff: label.diff,
                    shimmers: call.status == .running)
            }
            .buttonStyle(.plain)
        }
    }

    private func thinkingRowText(_ text: String) -> Text {
        let line = TimelineStep.thinking(id: "", text: text, status: .done).liveThinkingLine
            ?? String(localized: "thought_process")
        return Text(line)
            .font(.custom(CodePageTheme.sansFontName,
                          size: CodePageTheme.toolRowFontSize,
                          relativeTo: CodePageTheme.toolRowBodyTextStyle))
            .foregroundStyle(CodePageTheme.text400Color.resolved(for: colorScheme))
    }
}

/// One ordered step row, laid out with the Code page group sheet's decoded
/// metrics (`CodeDetailRowHooks`: 16 pt icon/content gap, 8 pt vertical
/// padding, `textMuted` chevron) so the chat sheet's rhythm matches the Code
/// page's tool detail (pp 2026-10-30). A running step swaps the icon for the
/// working mark and keeps the tool rows' shimmer on its label.
private struct CodeStepDetailRow: View {
    enum Leading {
        case icon(String, AnthropiconSize)
        case mark(WorkingMarkBody)
    }

    let leading: Leading
    let text: Text
    /// The `+N −N` pill the transcript row shows for edits; the group sheet
    /// keeps it next to the label (pp 2026-10-30).
    var diff: CodeDiffStat? = nil
    let shimmers: Bool

    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric(relativeTo: CodeDetailRowHooks.textStyle)
    private var textLineHeight = CodePageTheme.toolRowTextLineHeight

    var body: some View {
        HStack(alignment: .center, spacing: CodeDetailRowHooks.iconSpacing) {
            leadingView

            text
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(minHeight: textLineHeight, alignment: .leading)
                .layoutPriority(1)
                .modifier(CodeCollapsedRowShimmer(active: shimmers))

            // The label owns the whole middle stretch: the +N −N pill and the
            // chevron sit as a trailing cluster, so a file name keeps more
            // characters before it truncates (pp 2026-10-30). The chevron's
            // trailing position does not move.
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                if let diff, diff.hasCounts {
                    CodeDiffIndicator(stat: diff)
                }
                CodeRowCaret(tint: CodePageTheme.textMutedColor)
            }
        }
        .padding(.vertical, CodeDetailRowHooks.verticalPadding)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var leadingView: some View {
        switch leading {
        case let .icon(name, size):
            AnthropiconView(name: name, size: size)
                .foregroundStyle(CodePageTheme.text500Color.resolved(for: colorScheme))
                .frame(width: CodePageTheme.toolRowIconFrameSize,
                       height: CodePageTheme.toolRowIconFrameSize)
                .accessibilityHidden(true)
        case let .mark(body):
            WorkingMarkView(body: body, isRunning: true)
                .frame(width: CodePageTheme.toolRowIconFrameSize,
                       height: CodePageTheme.toolRowIconFrameSize)
        }
    }
}

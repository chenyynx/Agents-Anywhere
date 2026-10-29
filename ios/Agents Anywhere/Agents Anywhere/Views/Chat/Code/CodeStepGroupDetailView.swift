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
                    ForEach(liveGroup.steps) { step in
                        VStack(spacing: 0) {
                            row(for: step)
                            // The Code page's group sheet draws the 2 × 16 pt
                            // `TimelineConnector` between rows, centred in the
                            // 24 pt icon column (`CodeToolGroupDetailView`); the
                            // chat sheet lists the same ordered steps, so it
                            // carries the same connector.
                            if step.id != liveGroup.steps.last?.id {
                                CodeTimelineConnector()
                            }
                        }
                        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
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
            CodeCollapsedStepsRow(
                icon: status.isActive ? nil : "anthropicon.extendedThinking",
                iconSize: .medium,
                text: thinkingRowText(text),
                status: status.isActive ? .running
                    : (status.isFailure ? .failed : .complete),
                failureExtent: nil,
                hasDetails: true,
                diffIndicator: nil,
                workingMark: nil,
                leadingOverride: status.isActive
                    ? AnyView(WorkingMarkView(body: .think, isRunning: true)
                        .frame(width: CodePageTheme.toolRowIconFrameSize,
                               height: CodePageTheme.toolRowIconFrameSize))
                    : nil,
                isTextHidden: false,
                includesImages: false,
                voiceControlName: nil,
                spokenLabel: nil,
                isRunning: status.isActive,
                action: { path.append(.thinking(id: id, fallback: text)) })
        case let .tool(call):
            let label = CodeToolLabels.label(for: [call], cwd: cwd)
            let runs = CodeToolLabels.runs(for: label,
                                           differentiateWithoutColor: differentiateWithoutColor)
            CodeCollapsedStepsRow(
                icon: call.status == .running
                    ? nil : CodeToolLabels.anthropicon(for: call),
                text: CodeToolLabelRun.styledText(runs, scheme: colorScheme),
                status: call.status,
                failureExtent: call.status == .failed ? .failed : nil,
                hasDetails: true,
                diffIndicator: label.diff,
                workingMark: nil,
                leadingOverride: call.status == .running
                    ? AnyView(WorkingMarkView(
                        body: CodeWorkingMarkPose.body(forToolName: call.name),
                        isRunning: true)
                        .frame(width: CodePageTheme.toolRowIconFrameSize,
                               height: CodePageTheme.toolRowIconFrameSize))
                    : nil,
                isTextHidden: false,
                includesImages: false,
                voiceControlName: nil,
                spokenLabel: nil,
                isRunning: call.status == .running,
                action: { path.append(.tool(call)) })
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

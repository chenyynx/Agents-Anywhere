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

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityDifferentiateWithoutColor)
    private var differentiateWithoutColor

    @State private var path: [Route] = []

    enum Route: Hashable {
        case thinking(String)
        case tool(CodeToolCall)
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                ForEach(group.steps) { step in
                    row(for: step)
                        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(CodePageTheme.pageBackgroundColor.resolved(for: colorScheme)
                .ignoresSafeArea())
            .navigationTitle(Text(title))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { SheetCloseToolbar { dismiss() } }
            .navigationDestination(for: Route.self) { route in
                switch route {
                case let .thinking(text):
                    ScrollView {
                        CodeThinkingMarkdownView(text: text)
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
        .presentationDetents([.medium, .large])
    }

    private var title: String {
        TimelineStepSummaryText.line(
            TimelineStepSummarizer.summary(steps: group.steps, cwd: cwd))
    }

    @ViewBuilder
    private func row(for step: TimelineStep) -> some View {
        switch step {
        case let .thinking(_, text, status):
            CodeCollapsedStepsRow(
                icon: status.isActive ? nil : "anthropicon.extendedThinking",
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
                action: { path.append(.thinking(text)) })
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

import SwiftUI
import UIKit

/// The chat profile's step-group row: one `CollapsedStepsRow` per run of
/// reasoning/tool steps.
///
/// Official shape (`EVIDENCE/round29/chat-thinking-tool-dots-1.261023.20.md`
/// §2 and addendum §J): while the group runs, the row shows the group's last
/// item with the working mark in the leading slot; when it settles, the row
/// shows a summary. The ordered steps live in the detail sheet, never inline.
///
/// AA's one substitution (pp 2026-10-29): the official running thinking line
/// shows the server summary; AA's wire has none, so it shows the thinking
/// body's last line instead. Tool steps keep the official label.
struct CodeStepGroupRowView: View {
    let group: TimelineStepGroup
    let cwd: String?
    /// The turn is still live and this is its trailing group. The dots sit on
    /// this row for the whole live turn — including between steps, before any
    /// body text (pp 2026-10-29 device observation).
    let isLiveTail: Bool
    let onTap: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityDifferentiateWithoutColor)
    private var differentiateWithoutColor

    /// The row is always one line: the row's own 6 pt padding plus the pair of
    /// message margins every Code row carries. Used as the pre-measure estimate
    /// so the first frame does not jump.
    static var estimatedHeight: CGFloat {
        max(CodePageTheme.toolRowIconFrameSize,
            UIFontMetrics(forTextStyle: .body)
                .scaledValue(for: CodePageTheme.toolRowTextLineHeight))
            + 2 * CodePageTheme.toolRowButtonPadding
            + 2 * CodePageTheme.rowMarginTop
    }

    var body: some View {
        row
            .padding(.vertical, CodePageTheme.rowMarginTop)
    }

    /// The live pose: the mark plus the current step's one-line text. It
    /// covers both a running step and the gap between steps while the turn is
    /// still live (`isLiveTail`), so the dots never hop to a separate row
    /// before the reply body.
    private var showsMark: Bool { isLiveTail || group.isRunning }

    @ViewBuilder
    private var row: some View {
        if showsMark, let live = group.liveStep {
            CodeCollapsedStepsRow(
                icon: nil,
                text: liveText(for: live),
                status: .running,
                failureExtent: nil,
                hasDetails: true,
                diffIndicator: nil,
                workingMark: nil,
                leadingOverride: AnyView(
                    WorkingMarkView(body: workingMark(for: live), isRunning: true)
                        .frame(width: CodePageTheme.toolRowIconFrameSize,
                               height: CodePageTheme.toolRowIconFrameSize)),
                isTextHidden: false,
                includesImages: false,
                voiceControlName: nil,
                spokenLabel: nil,
                isRunning: true,
                action: onTap)
        } else {
            CodeCollapsedStepsRow(
                icon: summaryIcon,
                iconSize: group.toolCalls.isEmpty ? .medium : .large,
                text: summaryText,
                status: group.hasFailure ? .failed : .complete,
                failureExtent: nil,
                hasDetails: true,
                diffIndicator: nil,
                workingMark: nil,
                isTextHidden: false,
                includesImages: false,
                voiceControlName: nil,
                spokenLabel: nil,
                isRunning: false,
                action: onTap)
        }
    }

    // MARK: - Running

    private func liveText(for step: TimelineStep) -> Text {
        switch step {
        case .thinking:
            let line = step.liveThinkingLine
                ?? String(localized: "thinking_status_thinking")
            return Text(line)
                .font(.custom(CodePageTheme.sansFontName,
                              size: CodePageTheme.toolRowFontSize,
                              relativeTo: CodePageTheme.toolRowBodyTextStyle))
                .foregroundStyle(CodePageTheme.text400Color.resolved(for: colorScheme))
        case let .tool(call):
            let label = CodeToolLabels.label(for: [call], cwd: cwd)
            let runs = CodeToolLabels.runs(for: label,
                                           differentiateWithoutColor: differentiateWithoutColor)
            return CodeToolLabelRun.styledText(runs, scheme: colorScheme)
        }
    }

    private func workingMark(for step: TimelineStep) -> WorkingMarkBody {
        switch step {
        case .thinking: return .think
        case let .tool(call): return CodeWorkingMarkPose.body(forToolName: call.name)
        }
    }

    // MARK: - Settled

    private var summaryIcon: String {
        if let call = group.toolCalls.first {
            return CodeToolLabels.anthropicon(for: call)
        }
        return "anthropicon.extendedThinking"
    }

    private var summaryText: Text {
        let summary = TimelineStepSummarizer.summary(steps: group.steps, cwd: cwd)
        return Text(TimelineStepSummaryText.line(summary))
            .font(.custom(CodePageTheme.sansFontName,
                          size: CodePageTheme.toolRowFontSize,
                          relativeTo: CodePageTheme.toolRowBodyTextStyle))
            .foregroundStyle(CodePageTheme.text300Color.resolved(for: colorScheme))
    }
}

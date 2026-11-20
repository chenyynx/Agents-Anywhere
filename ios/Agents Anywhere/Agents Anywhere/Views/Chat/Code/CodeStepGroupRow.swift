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
    /// Whether a step that still reports `running` may be drawn live. False
    /// once fresh live facts prove the turn stopped (idle, or an accepted
    /// stop's optimistic window); late row snapshots must not keep the row
    /// spinning (pp 2026-11-14).
    var allowsRunningPose: Bool = true
    /// Draw a step that still reports `running` with the failure mark.
    ///
    /// True once the user stopped the turn: the tool that was running did not
    /// finish, and the connector's terminal row is a round trip plus settle
    /// away (device 2026-11-14: the ⚠️ trailed the notice by seconds). Display
    /// only — the server's own status replaces this as soon as it lands.
    var treatsRunningAsFailed: Bool = false
    /// Draw the official interrupted-response notice under the row. The chat
    /// profile's stopped turn is anchored to this group when it produced no
    /// partial answer text (pp 2026-11-14).
    var showsInterruptedNotice: Bool = false
    /// The session's configured agent name for the notice copy.
    var interruptedAgentName: String = "Claude"
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

    /// One notice card plus its top gap; used by the collection's estimate.
    static var interruptedNoticeExtraHeight: CGFloat {
        ChatInterruptedNoticeCard.estimatedHeight + 8
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            row
            if showsInterruptedNotice {
                ChatInterruptedNoticeCard(agentName: interruptedAgentName)
                    .padding(.top, 8)
            }
        }
        .padding(.vertical, CodePageTheme.rowMarginTop)
    }

    /// The live pose: the mark plus the current step's one-line text. It
    /// covers both a running step and the gap between steps while the turn is
    /// still live (`isLiveTail`), so the dots never hop to a separate row
    /// before the reply body.
    private var showsMark: Bool {
        group.showsRunningPose(isLiveTail: isLiveTail,
                               allowsRunningPose: allowsRunningPose)
    }

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
                trailingIcon: liveTrailingIcon(for: live),
                isTextHidden: false,
                includesImages: false,
                voiceControlName: nil,
                spokenLabel: nil,
                isRunning: true,
                textStepID: live.id,
                textContent: liveLabelContent(for: live),
                action: onTap)
        } else {
            CodeCollapsedStepsRow(
                icon: summaryIcon,
                iconSize: group.toolCalls.isEmpty ? .medium : .large,
                text: summaryText,
                status: group.hasFailure || (treatsRunningAsFailed && group.isRunning)
                    ? .failed : .complete,
                failureExtent: nil,
                hasDetails: true,
                diffIndicator: nil,
                workingMark: nil,
                isTextHidden: false,
                includesImages: false,
                voiceControlName: nil,
                spokenLabel: nil,
                // A background subagent keeps working after the main turn
                // settles; the row's own copy already turns present-tense
                // (「正在运行 N 个智能体」), so it carries the activity sweep
                // too (pp 2026-11-19). The icon does not change — only the
                // text's sweep animation is borrowed. Since pp 2026-11-21 this
                // branch also draws a group the main turn has moved past while
                // its dispatched subagent still runs (no second working mark).
                isRunning: group.hasRunningBackgroundAgent && !treatsRunningAsFailed,
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
            // A running question reads as a status, not a tool label: the
            // group row says 「正在提问」 while the card waits for the answer
            // (pp 2026-11-16). An answered question keeps its label in the
            // settled summary/sheet.
            if call.kind == .question {
                return Text(String(localized: "正在提问"))
                    .font(.custom(CodePageTheme.sansFontName,
                                  size: CodePageTheme.toolRowFontSize,
                                  relativeTo: CodePageTheme.toolRowBodyTextStyle))
                    .foregroundStyle(CodePageTheme.text400Color.resolved(for: colorScheme))
            }
            let label = CodeToolLabels.label(for: [call], cwd: cwd)
            let runs = CodeToolLabels.runs(for: label,
                                           differentiateWithoutColor: differentiateWithoutColor)
            return CodeToolLabelRun.styledText(runs, scheme: colorScheme)
        }
    }

    /// The running question carries the thinking row's clock after its label
    /// (pp 2026-11-16).
    /// The plain label the live row shows, for the width glide and the
    /// structural cross-fade (round29: `PacedRow` transitions `ShownView`).
    private func liveLabelContent(for step: TimelineStep) -> String {
        switch step {
        case .thinking:
            return step.liveThinkingLine
                ?? String(localized: "thinking_status_thinking")
        case let .tool(call):
            if call.kind == .question { return String(localized: "正在提问") }
            // Only the width/offset identity — the styled Text still comes
            // from `liveText(for:)`; this string never reaches the screen.
            let label = CodeToolLabels.label(for: [call], cwd: cwd)
            return [label.verb, label.target].compactMap { $0 }.joined(separator: " ")
        }
    }


    private func liveTrailingIcon(for step: TimelineStep) -> String? {
        if case let .tool(call) = step, call.kind == .question {
            return "anthropicon.extendedThinking"
        }
        return nil
    }

    private func workingMark(for step: TimelineStep) -> WorkingMarkBody {
        switch step {
        case .thinking: return .think
        case let .tool(call): return CodeWorkingMarkPose.body(forToolName: call.name)
        }
    }

    // MARK: - Settled

    private var summaryIcon: String {
        // Rule A (pp 2026-11-21): a row settled because its live step is a
        // working dispatched subagent reads as the subagent's row, so it
        // carries the subagent icon even when an earlier tool opened the run.
        if group.settlesAsRunningSubagentRow {
            return CodeToolLabels.anthropicon(for: .task)
        }
        if let call = group.toolCalls.first {
            return CodeToolLabels.anthropicon(for: call)
        }
        return "anthropicon.extendedThinking"
    }

    private var summaryText: Text {
        // Built with the group (apply time). Re-running the summarizer here
        // priced one label plan and diff scan per step inside the frame that
        // scrolled the row in.
        return Text(TimelineStepSummaryText.line(group.summary))
            .font(.custom(CodePageTheme.sansFontName,
                          size: CodePageTheme.toolRowFontSize,
                          relativeTo: CodePageTheme.toolRowBodyTextStyle))
            .foregroundStyle(CodePageTheme.text300Color.resolved(for: colorScheme))
    }
}

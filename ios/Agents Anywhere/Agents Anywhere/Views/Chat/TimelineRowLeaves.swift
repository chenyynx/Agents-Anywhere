import SwiftUI
import UIKit

// The leaf rows the Code transcript and the standalone fallback share.
// They moved here when the retired Chat row views were deleted
// (2026-11-16); their layout and parameters are unchanged.

struct TimelineMarkerRow: View {
    let title: String
    let symbol: String
    let status: V2TimelineItemStatus
    var expanded: Bool?
    var accessory: String?
    var body: some View {
        HStack(spacing: 8) {
            if let expanded { AppSymbol(expanded ? "chevron.down" : "chevron.right", size: 10).frame(width: 10) }
            // Non-fold rows keep the fold rows' chevron column so their icon
            // and text stay on the same vertical line as every expandable row.
            else { Color.clear.frame(width: 10, height: 10) }
            // `[pp 2026-10-17]` shrink reverted: the tool-row glyph keeps the
            // pre-refresh size so it still reads at a glance in the timeline.
            AppSymbol(symbol, size: 15).frame(width: 18)
            Text(title).font(.system(.subheadline, design: .monospaced)).lineLimit(1).truncationMode(.tail)
                .modifier(StatusShimmer(active: status.isActive && !status.isFailure))
                .frame(maxWidth: .infinity, alignment: .leading)
            if let accessory { AppSymbol(accessory, size: 14) }
        }
        .foregroundStyle(status.isFailure ? Color.red : ChatPalette.iconSecondary.color)
        // Consecutive tool rows read as one list; the full-width row stays tappable.
        .frame(minHeight: 32).contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityValue(status.label)
    }
}

struct TimelineFold<Content: View>: View {
    let id: String
    let title: String
    let symbol: String
    let status: V2TimelineItemStatus
    let disclosures: TimelineDisclosureState
    /// pp 2026-10-06: opt-in — an expanded body collapses on a double tap,
    /// because the header button scrolls out of reach on long reasoning.
    /// Only the reasoning fold opts in; every other fold attaches no gesture
    /// and keeps its exact interaction surface.
    var collapsesOnBodyDoubleTap = false
    /// L2: an explicit entry beside the disclosure title (the Agent card / the
    /// SubAgent progress group). It is a sibling button, not a tap on the
    /// disclosure row, so the existing expand gesture is never intercepted.
    var detailsAction: (() -> Void)?
    /// §A3: the card's live SubAgent tasks whose own stop control renders in
    /// the header row — one control per task, each bound to exactly one task
    /// id (a multi-task card renders one named control each; 能唯一确定目标
    /// 才出单按钮).
    var stopTasks: [SubAgentTask] = []
    var stoppingTaskIDs: Set<String> = []
    var onStopTask: ((String) -> Void)?
    @ViewBuilder var content: () -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.collectionTimelineHeightAnimation) private var heightAnimatedByHost
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Button {
                    toggleDisclosure()
                } label: { TimelineMarkerRow(title: title, symbol: symbol, status: status, expanded: disclosures.isExpanded(id)) }
                .buttonStyle(.plain).accessibilityValue(disclosures.isExpanded(id) ? String(localized: "已展开") : String(localized: "已折叠"))
                if let detailsAction {
                    Button(action: detailsAction) {
                        Text(String(localized: "查看详情"))
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(.tint)
                            .frame(minHeight: 32)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("chat.subagent.details")
                }
                if let onStopTask {
                    ForEach(stopTasks) { task in
                        SubAgentStopControl(task: task, showsName: stopTasks.count > 1,
                            isStopping: stoppingTaskIDs.contains(task.taskID)) {
                            onStopTask(task.taskID)
                        }
                    }
                }
            }
            if disclosures.isExpanded(id) { expandedBody.transition(.identity) }
        }
    }
    /// The expanded body. With `collapsesOnBodyDoubleTap`, a double tap
    /// anywhere in the body collapses the fold — the same toggle and animation
    /// as the header button (the header scrolls out of reach on long
    /// reasoning). Without it, the body is attached unmodified: the other
    /// folds attach no gesture and keep their exact interaction surface.
    /// A plain two-tap gesture, so single taps (links), scrolling and
    /// long-press selection keep working as before.
    /// The collection timeline animates the row height in its controller; the
    /// fold then only flips its state. The SwiftUI path keeps its own 0.18 s
    /// content animation.
    private func toggleDisclosure() {
        if heightAnimatedByHost {
            disclosures.toggle(id)
        } else {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                disclosures.toggle(id)
            }
        }
    }

    @ViewBuilder private var expandedBody: some View {
        if collapsesOnBodyDoubleTap {
            content()
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    toggleDisclosure()
                }
        } else {
            content()
        }
    }
}

struct TimelineCodePanel: View {
    let label: String
    let code: String
    var isDiff = false
    @State private var copied = false
    @State private var memo = PanelMemo()
    @ScaledMetric(relativeTo: .caption) private var rowHeight: CGFloat = 19
    /// Diff parsing and line counting repeat only when the code changes, not
    /// when the copy feedback or a neighbouring row invalidates this body.
    private final class PanelMemo {
        var code: String?
        var displayCode = ""
        var lineCount = 0
        var diffLines: [TimelineDiff.Line] = []
    }
    private func prepared() -> PanelMemo {
        if memo.code != code {
            memo.code = code
            memo.displayCode = String(code.prefix(200_000))
            memo.lineCount = memo.displayCode.utf8.reduce(1) { $0 + ($1 == UInt8(ascii: "\n") ? 1 : 0) }
            memo.diffLines = isDiff ? TimelineDiff(memo.displayCode).lines : []
        }
        return memo
    }
    var body: some View {
        let panel = prepared()
        let displayCode = panel.displayCode
        VStack(spacing: 0) {
            HStack {
                Text(label).font(.system(.caption, design: .monospaced))
                Spacer()
                Button {
                    UIPasteboard.general.string = code; copied = true
                } label: { AppSymbol(copied ? "checkmark" : "document.on.document").frame(width: 44, height: 44) }
                .buttonStyle(.plain).accessibilityLabel(copied ? String(localized: "已复制") : String(localized: "复制 \(label)"))
                .task(id: copied) { if copied { try? await Task.sleep(for: .seconds(2)); copied = false } }
            }.padding(.leading, 12).foregroundStyle(.secondary).background(.quaternary.opacity(0.3))
            ScrollView([.horizontal, .vertical]) {
                if isDiff {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(panel.diffLines) { line in
                            HStack(alignment: .top, spacing: 8) {
                                Text(line.sign).frame(width: 10)
                                Text(line.oldLine.map(String.init) ?? "").frame(width: 34, alignment: .trailing)
                                Text(line.newLine.map(String.init) ?? "").frame(width: 34, alignment: .trailing)
                                ChatSelectableText(text: line.text.isEmpty ? " " : line.text).fixedSize(horizontal: true, vertical: false)
                                Spacer(minLength: 0)
                            }
                            .font(.system(.caption, design: .monospaced)).monospacedDigit()
                            .padding(.horizontal, 12).frame(minHeight: rowHeight)
                            .foregroundStyle(diffColor(line.kind)).background(diffColor(line.kind).opacity(line.kind == .add || line.kind == .delete ? 0.09 : 0))
                        }
                    }.padding(.vertical, 8).fixedSize(horizontal: true, vertical: false)
                } else {
                    ChatSelectableText(text: displayCode).font(.system(.caption, design: .monospaced))
                        .fixedSize(horizontal: true, vertical: false).padding(12).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(height: min(320, max(76, CGFloat(panel.lineCount) * rowHeight + 24)))
            if displayCode.count < code.count { ToolTruncatedNote() }
        }.background(Color(uiColor: .secondarySystemBackground))
    }
    private func diffColor(_ kind: TimelineDiff.Line.Kind) -> Color {
        switch kind { case .add: .green; case .delete: .red; case .hunk, .file, .annotation: .secondary; case .context: .primary }
    }
}

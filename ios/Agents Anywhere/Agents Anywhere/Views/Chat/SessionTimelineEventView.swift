import SwiftUI
import UIKit

struct SessionTimelineGroupView: View, Equatable {
    let group: ChatTimelineGroup
    let chat: SessionChatModel
    /// The second argument is the thumbnail already decoded by the bubble.
    let onAttachment: (V2AttachmentContent, UIImage?) -> Void
    let onFile: (String) -> Void
    var turnAction: TimelineTurnAction?
    /// L2: opens the SubAgent panel. Nil in the panel's own child rows.
    var onSubAgent: ((String) -> Void)?
    /// Interaction cards targeting rows of this group. Passing the subset keeps
    /// unrelated groups equal when another row's notice changes.
    var inlineNotices: [SessionNoticeModel] = []

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.group == rhs.group && lhs.chat === rhs.chat && lhs.turnAction == rhs.turnAction
            && (lhs.onSubAgent == nil) == (rhs.onSubAgent == nil)
            && lhs.inlineNotices.elementsEqual(rhs.inlineNotices, by: ===)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            content
                .traceChatLayout("group-content:\(group.id)")
            if let turnAction {
                SessionTurnReviewFooter(action: turnAction, root: chat.session.metadata?.cwd,
                    hasOlderItems: chat.session.hasOlderItems, onFile: onFile)
                    .equatable()
                if !turnAction.replies.isEmpty {
                    SessionTurnActions(action: turnAction).equatable().traceChatLayout("actions:\(group.id)")
                }
            }
        }
        .traceChatLayout("group:\(group.id)", state: "footer=\(turnAction != nil)")
    }
    @ViewBuilder private var content: some View {
        if group.kind == .single { rows }
        else {
            TimelineFold(id: "group:\(group.id)", title: group.title,
                symbol: group.kind == .reconnect ? "wifi.slash" : agentGroup ? "person.2" : "hammer",
                status: group.status, disclosures: chat.disclosures,
                detailsAction: groupDetailsAction) {
                rows
            }
        }
    }
    private var agentGroup: Bool { if case .agents = group.kind { true } else { false } }
    /// The SubAgent progress group is the card's fold in the timeline; its
    /// header carries the same 查看详情 entry as the card row.
    private var groupDetailsAction: (() -> Void)? {
        guard case .agents(let parent) = group.kind, let onSubAgent else { return nil }
        return { onSubAgent(parent) }
    }
    private var rows: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(group.rows) { row in
                SessionTimelineRow(row: row, chat: chat, onAttachment: onAttachment, cwd: chat.session.metadata?.cwd,
                    disclosures: chat.disclosures, onFile: onFile, onSubAgent: onSubAgent)
                // Only interaction notices anchor to a row. A notification-type
                // notice has no timeline anchor and is a top toast instead; the
                // type check keeps that true even if a future one carried an
                // anchor. Routing the group's pre-sliced `inlineNotices` (not the
                // full list) keeps the equatable narrowing ChatTimelineView
                // gained: this group re-renders only when its own notices change.
                ForEach(SessionNoticeRouting.notices(inlineNotices,
                    sessionID: chat.session.id, anchoredTo: row.id)) { notice in
                    SessionInteractionCard(item: notice, chat: chat)
                }
            }
        }
    }
}

struct SessionTimelineEventView: View {
    let row: ChatTimelineRowModel
    let chat: SessionChatModel
    let cwd: String?
    let disclosures: TimelineDisclosureState
    let onFile: (String) -> Void
    /// L2: opens the SubAgent panel from an Agent card's 查看详情 entry. Nil
    /// (the panel's own child rows) leaves the card without the entry.
    var onSubAgent: ((String) -> Void)?
    private var entry: TimelineEntryPresentation { TimelineEntryPresentation(item: row.value, cwd: cwd) }
    /// Only a top-level Agent call card opens the panel: a nested card is a
    /// child row of its parent's panel (v1 renders one layer).
    private var agentCardDetailsAction: (() -> Void)? {
        guard let onSubAgent, SubAgentProgress.isAgentCall(row.value),
              SubAgentProgress.parentItemID(row.value) == nil else { return nil }
        return { onSubAgent(row.id) }
    }
    /// §A3 gate + targets: the card's live tasks, one stop control each —
    /// including nested tasks (G3), because the projection reads every live
    /// `agents` entry, not just the primary one. Empty for non-card rows and
    /// while the capability gate is closed (门控不渲染).
    private var stopTasks: [SubAgentTask] {
        SubAgentProgress.stopTasks(in: row.value, capabilities: chat.session.runtime.capabilities)
    }
    private var stopTask: ((String) -> Void)? {
        guard !stopTasks.isEmpty else { return nil }
        return { taskID in Task { await chat.stopSubagent(taskID: taskID) } }
    }

    var body: some View {
        let value = row.entry(cwd: cwd)
        switch value.kind {
        case .reasoning:
            if row.text.isEmpty || TimelineText.inlineSummary(row.text) != nil {
                TimelineMarkerRow(title: value.title, symbol: value.symbol, status: row.value.status)
            } else {
                TimelineFold(id: row.id, title: value.title, symbol: value.symbol, status: row.value.status, disclosures: disclosures,
                    collapsesOnBodyDoubleTap: true) {
                    ChatMarkdownView(text: row.text, isStreaming: row.isRevealing, resolvesFileReferences: true)
                        .id(row.layoutGeneration).padding(.leading, 24).foregroundStyle(.secondary)
                        // Reasoning stays well below the reply text.
                        .environment(\.chatMarkdownFont, .caption2)
                }
            }
        case .compact:
            HStack(spacing: 12) {
                Rectangle().fill(.quaternary).frame(height: 1)
                Text(value.title).font(.caption).foregroundStyle(row.value.status.isFailure ? Color.red : .secondary).fixedSize()
                Rectangle().fill(.quaternary).frame(height: 1)
            }.padding(.vertical, 8)
        case .tool:
            if value.hasToolDetails {
                TimelineFold(id: row.id, title: value.title, symbol: value.symbol, status: row.value.status,
                    disclosures: disclosures, detailsAction: agentCardDetailsAction,
                    stopTasks: stopTasks, stoppingTaskIDs: chat.stoppingSubagentTaskIDs, onStopTask: stopTask) {
                    TimelineToolDetails(row: row, cwd: cwd, onFile: onFile)
                }
            } else { TimelineMarkerRow(title: value.title, symbol: value.symbol, status: row.value.status) }
        case .artifact:
            VStack(alignment: .leading, spacing: 8) {
                if let path = value.filePath {
                    Button { onFile(path) } label: { TimelineMarkerRow(title: value.title, symbol: value.symbol, status: row.value.status, accessory: "arrow.up.right") }
                        .buttonStyle(.plain).accessibilityHint(String(localized: "打开文件预览"))
                } else if let url = value.externalURL {
                    Link(destination: url) { TimelineMarkerRow(title: value.title, symbol: value.symbol, status: row.value.status, accessory: "arrow.up.right") }
                        .buttonStyle(.plain)
                } else { TimelineMarkerRow(title: value.title, symbol: value.symbol, status: row.value.status) }
            }
        case .marker:
            if let detail = value.detail {
                TimelineFold(id: row.id, title: value.title, symbol: value.symbol, status: row.value.status, disclosures: disclosures) {
                    TimelineCodePanel(label: String(localized: "Details"), code: detail.formattedJSON).clipShape(.rect(cornerRadius: 14))
                }
            } else { TimelineMarkerRow(title: value.title, symbol: value.symbol, status: row.value.status) }
        }
    }
}

struct TimelineMarkerRow: View {
    let title: String
    let symbol: String
    let status: V2TimelineItemStatus
    var expanded: Bool?
    var accessory: String?
    var body: some View {
        HStack(spacing: 8) {
            if let expanded { AppSymbol(expanded ? "chevron.down" : "chevron.right", size: 10).frame(width: 10) }
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

/// This subtree is created only inside the expanded branch of TimelineFold.
/// Collapsing destroys parsed output, patch rows, code panels and their state.
private struct TimelineToolDetails: View {
    let row: ChatTimelineRowModel
    let cwd: String?
    let onFile: (String) -> Void
    var body: some View {
        let value = row.entry(cwd: cwd)
        let changes = value.changes
        VStack(spacing: 0) {
            if let command = value.command { TimelineCodePanel(label: String(localized: "Command"), code: command) }
            if let input = value.input, input != .null && input != .object([:]) {
                TimelineCodePanel(label: String(localized: "Input"), code: input.formattedJSON)
            }
            ForEach(changes) { change in TimelineFileChangeView(change: change, onFile: onFile) }
            if let output = value.output { TimelineCodePanel(label: String(localized: "Output"), code: output) }
        }.clipShape(.rect(cornerRadius: 14))
    }
}

private struct TimelineFold<Content: View>: View {
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
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Button {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { disclosures.toggle(id) }
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
    @ViewBuilder private var expandedBody: some View {
        if collapsesOnBodyDoubleTap {
            content()
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { disclosures.toggle(id) }
                }
        } else {
            content()
        }
    }
}

private struct TimelineFileChangeView: View {
    let change: TimelineFileChange
    let onFile: (String) -> Void
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                AppSymbol("doc.text").foregroundStyle(.secondary)
                Text(change.action.label).font(.caption2).padding(5).background(.quaternary, in: .rect(cornerRadius: 5))
                Button { if let path = change.path { onFile(path) } } label: {
                    Text(change.displayPath).font(.system(.caption, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain).disabled(change.path == nil).accessibilityHint(String(localized: "在 Web 预览中打开文件"))
                AppSymbol("square.and.pencil", size: 12).foregroundStyle(.secondary)
            }.padding(.horizontal, 12).frame(minHeight: 44).background(.quaternary.opacity(0.4))
            if let code = change.diff ?? change.code { TimelineCodePanel(label: change.diff == nil ? "code" : "diff", code: code, isDiff: change.diff != nil) }
        }.background(Color(uiColor: .secondarySystemBackground))
    }
}

struct TimelineCodePanel: View {
    let label: String
    let code: String
    var isDiff = false
    @State private var copied = false
    @State private var memo = PanelMemo()
    @ScaledMetric(relativeTo: .caption) private var rowHeight: CGFloat = ChatMetrics.blockCodeLineHeight
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
            HStack(spacing: 0) {
                Text(label)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(ChatPalette.codeHeaderLabel.color)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button {
                    UIPasteboard.general.string = code; copied = true
                    // Copy confirms by touch as well as by glyph, matching the
                    // card family this chrome comes from.
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                } label: {
                    AppSymbol(copied ? "checkmark" : "document.on.document", size: 15)
                        .foregroundStyle(copied ? Color.green : ChatPalette.codeHeaderIcon.color)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain).accessibilityLabel(copied ? String(localized: "已复制") : String(localized: "复制 \(label)"))
                .task(id: copied) { if copied { try? await Task.sleep(for: .seconds(2)); copied = false } }
            }
            .padding(.horizontal, 14)
            .frame(height: 36)
            .background(ChatPalette.codeCardFill.color)
            Rectangle()
                .fill(ChatPalette.codeHeaderDivider.color)
                .frame(height: 1 / UIScreen.main.scale)
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
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .scrollIndicators(.hidden)
            .frame(height: min(320, max(76, CGFloat(panel.lineCount) * rowHeight + 24)))
            if displayCode.count < code.count {
                Text(String(localized: "预览已截断，复制可获取完整内容"))
                    .font(.caption)
                    .foregroundStyle(ChatPalette.codeHeaderLabel.color)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
            }
        }
        .background(ChatPalette.codeCardFill.color)
        .clipShape(.rect(cornerRadius: ChatMetrics.codeRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: ChatMetrics.codeRadius, style: .continuous)
                .stroke(ChatPalette.codeCardBorder.color, lineWidth: 1 / UIScreen.main.scale)
                .allowsHitTesting(false)
        )
    }
    private func diffColor(_ kind: TimelineDiff.Line.Kind) -> Color {
        switch kind {
        case .add: ChatPalette.diffAdd.color
        case .delete: ChatPalette.diffRemove.color
        case .hunk, .file, .annotation: ChatPalette.textSecondary.color
        case .context: ChatPalette.text.color
        }
    }
}

import SwiftUI
import UIKit

/// The collection adapter's fallback for rows that are neither a message unit
/// nor a step group: a compaction divider, a marker row, an artifact, an
/// interaction anchor, or a legacy keyless row the builder could not group.
///
/// Every branch draws with the Code page's own components — the one-line status
/// rows reuse `CodeCollapsedStepsRow`, the message/tool/thinking rows reuse
/// `CodeMessageRowView` / `CodeCollapsedToolRow`. The retired Chat leaves are
/// gone: keeping them as a fallback made old-styled rows reappear on this page
/// (pp 2026-11-16).
///
/// The row's inline interaction cards, the interrupted notice and the turn
/// footer keep the retired group's spacing (outer 4 pt, row → notice 2 pt).
struct CodeStandaloneRowView: View, Equatable {
    let group: ChatTimelineGroup
    let chat: SessionChatModel
    /// The runtime profile the Code rows render with.
    let profile: CodeRuntimeProfile
    /// The second argument is the thumbnail already decoded by the bubble.
    let onAttachment: (V2AttachmentContent, UIImage?) -> Void
    let onFile: (String) -> Void
    /// Interaction cards targeting this row. Passing the subset keeps unrelated
    /// groups equal when another row's notice changes.
    var inlineNotices: [SessionNoticeModel] = []
    /// The official interrupted-response notice sits under this row.
    var showsInterruptedNotice = false
    var onToolDetail: (CodeToolDetailRequest) -> Void = { _ in }
    var onThinkingDetail: (CodeThinkingDetailRequest) -> Void = { _ in }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.group == rhs.group && lhs.chat === rhs.chat
            && lhs.inlineNotices.elementsEqual(rhs.inlineNotices, by: ===)
            && lhs.showsInterruptedNotice == rhs.showsInterruptedNotice
    }

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openURL) private var openURL

    private var cwd: String? { chat.session.metadata?.cwd }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            content
            if showsInterruptedNotice {
                ChatInterruptedNoticeCard(agentName: chat.agentName)
                    // The stack's 4 pt spacing already separates this footer;
                    // 4 more matches the official card's top gap.
                    .padding(.top, 4)
            }
        }
    }

    @ViewBuilder private var content: some View {
        // Every producer hands over a one-row group, but rendering the whole
        // array keeps a future multi-row group from silently losing rows.
        ForEach(group.rows) { row in
            // The same 2 pt stack the retired group used between a row and the
            // interaction cards anchored to it.
            VStack(alignment: .leading, spacing: 2) {
                rowView(row)
                // Only interaction notices anchor to a row; routing the
                // pre-sliced subset keeps this view equal when another row's
                // notice changes.
                ForEach(SessionNoticeRouting.notices(inlineNotices,
                    sessionID: chat.session.id, anchoredTo: row.id)) { notice in
                    SessionInteractionCard(item: notice, chat: chat)
                }
            }
        }
    }

    @ViewBuilder private func rowView(_ row: ChatTimelineRowModel) -> some View {
        let value = row.entry(cwd: cwd)
        if case .message = row.value.content {
            // An interaction target can be a message row (an approval anchored
            // on the prompt). It keeps the Code message row, not a marker.
            codeRow(row)
        } else {
            switch value.kind {
            case .compact:
                CompactedDivider(title: value.title, failed: value.compactFailed)
            case .marker:
                // A system/status line (a reconnect notice, an error row).
                codeStatusRow(title: value.title,
                              icon: row.value.status.isFailure
                                  ? "anthropicon.warning" : "anthropicon.clock",
                              failure: row.value.status.isFailure)
            case .artifact:
                // A file (or an external link) published as its own row.
                if let path = value.filePath {
                    codeStatusRow(title: value.title, icon: "anthropicon.file",
                                  failure: row.value.status.isFailure) {
                        onFile(path)
                    }
                    .accessibilityHint(String(localized: "打开文件预览"))
                } else if let url = value.externalURL {
                    codeStatusRow(title: value.title, icon: "anthropicon.file",
                                  failure: row.value.status.isFailure) {
                        openURL(url)
                    }
                } else {
                    codeStatusRow(title: value.title, icon: "anthropicon.file",
                                  failure: row.value.status.isFailure)
                }
            case .tool, .reasoning:
                // An approval anchors on these rows; they keep the Code tool /
                // thinking row and its detail page. A runtime may skip the
                // call itself (an answered question, ExitPlanMode), and a
                // running reasoning block is not drawn by the Code builder:
                // what is left is the builder's generic `.other` placeholder,
                // not a drawing. A skipped *tool* still has a name, a status
                // and a payload, so it keeps a Code tool row (label plan +
                // status glyph + the Code detail sheet). A thinking block the
                // builder does not draw keeps one Code-styled status line: the
                // Code page draws only settled thinking, and a running one is
                // the live working line.
                if hasDrawableCodeRow(row) {
                    codeRow(row)
                } else if let call = codeToolCall(row) {
                    codeToolRow(call)
                } else {
                    codeStatusRow(title: value.title, icon: "anthropicon.extendedThinking",
                                  failure: row.value.status.isFailure)
                }
            }
        }
    }

    /// Whether the Code builder draws a real block for this row. A standalone
    /// item maps to a generic `.other` block — the builder's placeholder for
    /// "the Code page has no block for this" — so a row with only that block is
    /// not drawable and the caller draws its own one-line row.
    private func hasDrawableCodeRow(_ row: ChatTimelineRowModel) -> Bool {
        CodeMessageBuilder.rows(for: [row.value], profile: profile,
                                includeSubAgentChildren: true)
            .contains { codeRow in
                codeRow.blocks.contains { block in
                    if case .other = block { return false }
                    return true
                }
            }
    }

    /// The row as a Code tool call, when it declares one. The Code builder
    /// drops a runtime's skipped calls (`AskUserQuestion`, `ExitPlanMode`) and
    /// therefore has no block for them; the row itself still carries
    /// everything the Code tool row draws.
    private func codeToolCall(_ row: ChatTimelineRowModel) -> CodeToolCall? {
        let item = row.value
        // The same predicate `CodeMessageBuilder` uses for a tool row.
        guard item.type == .tool || item.type == .fileChange
                || item.raw["content"]?["kind"] == .string("file_change") else { return nil }
        let name = CodeToolCall.wireName(for: item)
        return CodeToolCall(item: item,
                            kind: profile.kind(for: name,
                                               wireKind: CodeToolCall.wireKind(for: item)))
    }

    /// One call in the Code page's own row shape — the construction
    /// `CodeMessageRowView.toolRow` uses: the label plan, the category icon,
    /// the status glyph, and the caret when there is a detail page to open.
    private func codeToolRow(_ call: CodeToolCall) -> some View {
        let calls = [call]
        let label = CodeToolLabels.label(for: calls, cwd: cwd)
        let failed = calls.filter { $0.status == .failed }.count
        let status: CodeToolStatus
        if label.isRunning {
            status = .running
        } else if failed == calls.count {
            status = .failed
        } else {
            status = .complete
        }
        let failureExtent: CodeFailureExtent? = failed == 0
            ? nil : (failed == calls.count ? .failed : .partial)
        let request = CodeToolDetailRequest(calls: calls)
        return CodeCollapsedToolRow(label: label,
                                    icon: CodeToolLabels.anthropicon(for: calls),
                                    workingMark: nil,
                                    status: status,
                                    failureExtent: failureExtent,
                                    hasDetails: request != nil) {
            if let request { onToolDetail(request) }
        }
    }

    /// One Code-styled line for a row the page has no dedicated component for:
    /// a system marker, a file artifact, or a thinking block with nothing
    /// drawable. It reuses the thinking row's slot, type settings and paddings,
    /// so these rows read as part of the page (the retired Chat marker line is
    /// gone, pp 2026-11-16).
    ///
    /// - `icon`: an `anthropicon` asset name; the row draws it in the 24 pt
    ///   slot at `.medium`, the same extent a thinking row uses.
    /// - `failure`: the title takes the Code danger ink. The status glyph stays
    ///   empty so the warning does not read twice.
    /// - `action`: when non-nil the row is tappable and shows the caret; a
    ///   plain status line has no affordance.
    private func codeStatusRow(title: String, icon: String, failure: Bool,
                               action: (() -> Void)? = nil) -> some View {
        CodeCollapsedStepsRow(
            icon: icon,
            iconSize: .medium,
            text: Text(verbatim: title)
                .font(.custom(CodePageTheme.sansFontName,
                              size: CodePageTheme.toolRowFontSize,
                              relativeTo: CodePageTheme.toolRowBodyTextStyle))
                .foregroundStyle((failure ? CodePageTheme.danger00Color
                                          : CodePageTheme.text400Color)
                    .resolved(for: colorScheme)),
            status: .complete,
            failureExtent: nil,
            hasDetails: action != nil,
            diffIndicator: nil,
            workingMark: nil,
            isTextHidden: false,
            includesImages: false,
            voiceControlName: nil,
            spokenLabel: nil,
            isRunning: false,
            action: { action?() })
    }

    /// One row through the Code message row: the builder groups it by its own
    /// id when a legacy payload declares no key, and the explicit selection
    /// opts into sub-agent child rows.
    private func codeRow(_ row: ChatTimelineRowModel) -> some View {
        CodeMessageRowView(
            group: ChatTimelineGroup(kind: .single, rows: [row], explicitID: nil),
            profile: profile,
            includesSubAgentChildren: true,
            cwd: cwd,
            // A plain standalone row sits in the list's 20 pt spacing and
            // skips the official 5 pt margins (5/25 would be uneven). An
            // interaction anchor is the exception: its group is self-margined
            // and its card docks right below, so it draws the Code margins
            // and pays no list gap (pp 2026-11-16: the question card sat
            // ~20 pt lower than the approval card).
            addsRowMargins: group.isInteractionAnchor,
            onToolDetail: onToolDetail,
            onThinkingDetail: onThinkingDetail,
            // The page's own attachment pipeline: without it an image tile
            // has no preview bytes and a tap only retries the (never-run)
            // loader instead of opening the viewer.
            attachmentResolver: { contents, clientID in
                chat.session.attachmentPreviews.resolve(contents, clientID: clientID)
            },
            attachmentState: { _ in .complete },
            loadThumbnail: { try await chat.thumbnail(for: $0) },
            onAttachment: onAttachment)
    }
}

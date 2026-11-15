import SwiftUI
import UIKit

/// The collection adapter's fallback for rows that are neither a message unit
/// nor a step group: a compaction divider, a marker row, an artifact, an
/// interaction anchor, or a legacy keyless row the builder could not group.
///
/// - A message row keeps the Code message row (bubble / markdown / thinking).
/// - A tool or reasoning row keeps the Code row too, so an approval anchored on
///   a tool call still opens the official tool detail instead of degrading to a
///   one-line marker.
/// - A compaction divider, a marker and an artifact keep the same leaf views
///   the retired Chat group used.
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
    var turnAction: TimelineTurnAction?
    /// Interaction cards targeting this row. Passing the subset keeps unrelated
    /// groups equal when another row's notice changes.
    var inlineNotices: [SessionNoticeModel] = []
    /// The official interrupted-response notice sits under this row.
    var showsInterruptedNotice = false
    var onToolDetail: (CodeToolDetailRequest) -> Void = { _ in }
    var onThinkingDetail: (CodeThinkingDetailRequest) -> Void = { _ in }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.group == rhs.group && lhs.chat === rhs.chat && lhs.turnAction == rhs.turnAction
            && lhs.inlineNotices.elementsEqual(rhs.inlineNotices, by: ===)
            && lhs.showsInterruptedNotice == rhs.showsInterruptedNotice
    }

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
            if let turnAction {
                SessionTurnReviewFooter(action: turnAction, root: cwd,
                    hasOlderItems: chat.session.hasOlderItems, onFile: onFile)
                    .equatable()
                if !turnAction.replies.isEmpty {
                    SessionTurnActions(action: turnAction).equatable()
                }
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
                if let detail = value.detail {
                    TimelineFold(id: row.id, title: value.title, symbol: value.symbol,
                                 status: row.value.status, disclosures: chat.disclosures) {
                        TimelineCodePanel(label: String(localized: "Details"),
                                          code: detail.formattedJSON)
                            .clipShape(.rect(cornerRadius: 14))
                    }
                } else {
                    TimelineMarkerRow(title: value.title, symbol: value.symbol,
                                      status: row.value.status)
                }
            case .artifact:
                if let path = value.filePath {
                    Button { onFile(path) } label: {
                        TimelineMarkerRow(title: value.title, symbol: value.symbol,
                                          status: row.value.status, accessory: "arrow.up.right")
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(String(localized: "打开文件预览"))
                } else if let url = value.externalURL {
                    Link(destination: url) {
                        TimelineMarkerRow(title: value.title, symbol: value.symbol,
                                          status: row.value.status, accessory: "arrow.up.right")
                    }
                    .buttonStyle(.plain)
                } else {
                    TimelineMarkerRow(title: value.title, symbol: value.symbol,
                                      status: row.value.status)
                }
            case .tool, .reasoning:
                // An approval anchors on these rows; they keep the Code tool /
                // thinking row and its detail page. A runtime may skip the
                // call itself (an answered question, ExitPlanMode), and a
                // running reasoning block is not drawn by the Code builder:
                // what is left is the builder's generic `.other` placeholder,
                // not a drawing. Those cases keep the marker line so the
                // anchored card never floats under a blank or a raw type name.
                if hasDrawableCodeRow(row) {
                    codeRow(row)
                } else {
                    TimelineMarkerRow(title: value.title, symbol: value.symbol,
                                      status: row.value.status)
                }
            }
        }
    }

    /// Whether the Code builder draws a real block for this row. A standalone
    /// item maps to a generic `.other` block — the builder's placeholder for
    /// "the Code page has no block for this" — so a row with only that block is
    /// not drawable and the caller keeps the marker line.
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

    /// One row through the Code message row: the builder groups it by its own
    /// id when a legacy payload declares no key, and the explicit selection
    /// opts into sub-agent child rows.
    private func codeRow(_ row: ChatTimelineRowModel) -> some View {
        CodeMessageRowView(
            group: ChatTimelineGroup(kind: .single, rows: [row], explicitID: nil),
            profile: profile,
            includesSubAgentChildren: true,
            cwd: cwd,
            // The group already sits in the list's 20 pt spacing; the official
            // 5 pt row margins would make this row's gaps uneven (5/25).
            addsRowMargins: false,
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

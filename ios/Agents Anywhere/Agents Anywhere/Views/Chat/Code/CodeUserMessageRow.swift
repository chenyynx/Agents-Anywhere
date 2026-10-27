import SwiftUI

// The Code page's user message as one block stack: the attachment grids
// first, then the text bubble below them (device screenshots 2026-10-27).
// The settled `CodeMessageRowView` builds the same stack from the same
// `CodeUserBubble` and `CodeAttachmentRow` components; this view is the
// optimistic-send entry point, and the two share the 8 pt block gap.

/// One Code user message: attachments then text bubble, in that order.
struct CodeUserMessageRow: View {
    var text: String = ""
    var attachments: [ChatMessageAttachment] = []
    /// The optimistic-send state; the bubble or the attachment row carries the
    /// indicator in the leading gutter.
    var isPending = false
    var onDeliveryIssue: (() -> Void)? = nil
    /// One attachment's display state. A settled message passes `.complete`;
    /// an optimistic send maps its uploaded/failed attachments here.
    var attachmentState: (V2AttachmentContent) -> CodeAttachmentDisplayState = { _ in .complete }
    var onAttachment: (V2AttachmentContent, UIImage?) -> Void = { _, _ in }
    var loadThumbnail: (V2AttachmentContent) async throws -> Data? = { _ in nil }

    var body: some View {
        VStack(alignment: .leading, spacing: CodePageTheme.blockGap) {
            if !attachments.isEmpty {
                CodeAttachmentRow(files: attachments,
                                  state: attachmentState,
                                  onAttachment: onAttachment,
                                  loadThumbnail: loadThumbnail)
            }
            if hasText {
                CodeUserBubble(text: text)
            }
        }
        // Same conditional trailing inset as the settled row: only a file
        // card needs the room for its shadow.
        .padding(.trailing,
                 attachments.contains { !$0.content.isImage }
                    ? CodePageTheme.userRowShadowInset : 0)
        .overlay(alignment: .bottomLeading) {
            // The delivery state belongs to the whole user row: with
            // attachments the indicator sits beside the last block, not
            // inside the bubble above them. A text-only row places it at the
            // bubble's bottom edge, which is the row's bottom edge.
            if isPending || onDeliveryIssue != nil {
                // When a text bubble is present it is the last block and
                // keeps the 36 pt leading gutter, so the indicator sits
                // inside that gutter. A pure-attachment row ends on the
                // trailing grid, whose leading edge is the row edge; the
                // same negative offset would push the indicator off screen.
                CodeDeliveryGutter(
                    isPending: isPending,
                    onDeliveryIssue: onDeliveryIssue,
                    pendingOffset: hasText ? -26 : 0,
                    issueOffset: hasText ? -30 : 0)
            }
        }
    }

    /// The settled row drops whitespace-only text before it builds blocks;
    /// the optimistic row must use the same rule or a space-plus-attachment
    /// send draws a bubble the measurer priced at zero.
    private var hasText: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// The official row splits an optimistic send into uploaded attachments
/// (drawn as complete) and attachments whose bytes never reached the server
/// (drawn as the failed card). AA tracks upload success per
/// `ChatAttachment.uploaded`, so an attachment with no server reference when
/// the send has already failed maps to `.failed`.
extension V2PendingMessage {
    func codeAttachmentState(
        for content: V2AttachmentContent
    ) -> CodeAttachmentDisplayState {
        let key = content.fileId ?? content.cacheKey
        let uploaded = attachments.contains { attachment in
            (attachment.content.fileId ?? attachment.content.cacheKey) == key
                && attachment.uploaded != nil
        }
        if uploaded { return .complete }
        switch delivery {
        case .sending, .accepted: return .inFlight
        case .confirmed: return .complete
        case .uncertain, .rejected: return .failed
        }
    }
}

/// The delivery state in the leading gutter: a spinner while sending and the
/// retry/issue button after a confirmed failure. Extracted so the text bubble
/// and a pure-attachment row place the same affordance.
struct CodeDeliveryGutter: View {
    var isPending: Bool
    var onDeliveryIssue: (() -> Void)?
    /// Horizontal offset from the row's leading edge. The default places the
    /// indicator inside the text bubble's 36 pt leading gutter; a row with
    /// attachments passes 0 so it stays on screen.
    var pendingOffset: CGFloat = -26
    var issueOffset: CGFloat = -30

    var body: some View {
        if isPending {
            ProgressView().progressViewStyle(.circular).controlSize(.small)
                .frame(width: 18, height: 44).offset(x: pendingOffset)
                .accessibilityLabel(String(localized: "正在发送消息"))
        } else if let onDeliveryIssue {
            Button(action: onDeliveryIssue) {
                AppSymbol("exclamationmark.circle").foregroundStyle(.red)
                    .frame(width: 24, height: 44)
            }
            .buttonStyle(.plain)
            .offset(x: issueOffset)
            .accessibilityLabel(String(localized: "查看发送问题"))
        }
    }
}

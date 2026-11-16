import SwiftUI
import UIKit

/// The optimistic send row. It draws the same shape the settled echo gets —
/// `CodeUserMessageRow`'s text bubble then the attachment grids — because the
/// retired Chat accent bubble changed the message's colour, padding and corner
/// radius the moment the server acknowledged it. The page's only caller always
/// rendered the Code shape, so the old switch is gone with its view.
struct PendingMessageRow: View {
    let pending: V2PendingMessage
    let chat: SessionChatModel
    let onAttachment: (V2AttachmentContent, UIImage?) -> Void
    let onDismiss: () -> Void
    /// Sends this record's payload again as a fresh message (the record is
    /// retired first). Offered only for real sessions — a local-creation
    /// pending has its own edit/discard flow.
    var onRetry: (() -> Void)? = nil
    @State private var confirmsDismiss = false

    var body: some View {
        CodeUserMessageRow(
            text: pending.content,
            attachments: chat.session.attachmentPreviews.resolve(
                pending.attachments.map(\.content), clientID: pending.id),
            // The working row is the send's progress signal (pp 2026-11-16):
            // the bubble itself draws no spinner. A failed delivery still puts
            // its retry affordance in the same gutter.
            isPending: false,
            onDeliveryIssue: deliveryIssue == nil ? nil : { confirmsDismiss = true },
            attachmentState: { content in
                pending.codeAttachmentState(for: content)
            },
            onAttachment: onAttachment,
            loadThumbnail: chat.thumbnail)
        .confirmationDialog(deliveryIssue ?? "", isPresented: $confirmsDismiss, titleVisibility: .visible) {
            if let onRetry, !chat.session.isLocalCreation {
                Button(String(localized: "重新发送")) { onRetry() }
            }
            Button(String(localized: "返回编辑")) {
                if chat.session.isLocalCreation { chat.onEditCreation?(pending) }
                else { _ = chat.session.restoreDraft(from: pending) }
            }
            Button(String(localized: "移除此发送记录")) {
                if chat.session.isLocalCreation { chat.onDiscardCreation?() } else { onDismiss() }
            }
            Button(String(localized: "取消"), role: .cancel) {}
        }
    }

    private var deliveryIssue: String? {
        switch pending.delivery {
        case .uncertain: String(localized: "发送结果尚未确认，草稿已保留。请先检查会话是否已收到消息；移除记录后再次发送可能产生重复消息。")
        case let .rejected(error): error.message
        default: nil
        }
    }
}

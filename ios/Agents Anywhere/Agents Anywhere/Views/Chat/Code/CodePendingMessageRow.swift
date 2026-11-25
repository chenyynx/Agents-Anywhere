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
        // The official queue row never prints a status word: the state is a
        // visual affordance and the copy lives in accessibility (the strings
        // with "Shows options…" are hints). A steer row follows the same rule.
        row
            .accessibilityValue(steerStatusText ?? "")
            .accessibilityHint(
                steerStatus == .heldForNextTurn
                    ? String(localized: "已提交，将在下一轮送达。长按可移除。")
                    : (steerStatus == nil
                        ? ""
                        : String(localized: "显示此等待中消息的操作。")))
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

    /// The held steer has no echo yet and may never get one (the runtime can
    /// restart with the message still in its CLI queue). It must stay neutral
    /// — a red failure mark here would repeat the 2026-11-21 false alarm — but
    /// it needs an escape hatch, so a long press offers an explicit removal
    /// with the duplicate warning.
    @ViewBuilder private var row: some View {
        if steerStatus == .heldForNextTurn {
            baseRow.contextMenu {
                Button(role: .destructive) {
                    onDismiss()
                } label: {
                    Text(String(localized: "移除此等待中的引导（若已送达，重发可能重复）"))
                }
            }
        } else {
            baseRow
        }
    }

    private var baseRow: some View {
        CodeUserMessageRow(
            text: pending.content,
            attachments: chat.session.attachmentPreviews.resolve(
                pending.attachments.map(\.content), clientID: pending.id),
            // The working row is the send's progress signal (pp 2026-11-16):
            // the bubble itself draws no spinner. A failed delivery still puts
            // its retry affordance in the same gutter.
            isPending: false,
            // A steer stays outside the transcript until the runtime echoes
            // it; the dashed outline is the same "waiting" language the
            // send queue uses. The echo retires this row and its settled
            // replacement is solid.
            waitingOutline: pending.isSteer,
            // The held steer's escape hatch is the row-level removal menu; the
            // bubble's copy/select menu would shadow it.
            showsBubbleActions: steerStatus != .heldForNextTurn,
            onDeliveryIssue: deliveryIssue == nil ? nil : { confirmsDismiss = true },
            attachmentState: { content in
                pending.codeAttachmentState(for: content)
            },
            onAttachment: onAttachment,
            loadThumbnail: chat.thumbnail)
    }

    private var steerStatus: SteerPendingStatus? {
        guard pending.isSteer else { return nil }
        return SteerPendingStatusResolver.resolve(
            delivery: pending.delivery,
            runtimeStatus: chat.session.runtime.state?.status)
    }

    private var steerStatusText: String? {
        switch steerStatus {
        case .sending: return String(localized: "发送中")
        case .waiting: return String(localized: "正在等待 Claude")
        case .heldForNextTurn: return String(localized: "已提交，下一轮送达")
        case nil: return nil
        }
    }

    private var deliveryIssue: String? {
        switch pending.delivery {
        case .uncertain:
            return String(localized: "发送结果尚未确认，草稿已保留。请先检查会话是否已收到消息；移除记录后再次发送可能产生重复消息。")
        case let .rejected(error):
            return error.message
        default:
            return nil
        }
    }
}

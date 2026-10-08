import SwiftUI

/// The paused-queue banner: the one place the queue explains itself and the
/// only way to resume it. It mirrors the takeover pill's form (a cohesive
/// glass capsule with a 32 pt visible height inside a 44 pt touch target) and
/// floats in the top overlay stack, below the takeover pill. It is present only
/// while the queue is paused and non-empty — an empty queue pauses nothing, so
/// the banner disappears with its last message.
struct SendQueueBanner: View {
    let model: SessionChatModel
    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric(relativeTo: .footnote) private var pillHeight: CGFloat = 32

    var body: some View {
        if model.session.isSendQueuePaused, !model.session.sendQueue.isEmpty {
            let count = model.session.sendQueue.count
            HStack(spacing: 12) {
                Label(message(count: count), appSymbol: "exclamationmark.circle")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(AppTheme.primaryText(colorScheme))
                    .labelStyle(.titleAndIcon)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Button(String(localized: "重试")) {
                    Task { await model.retrySendQueue() }
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(AppTheme.primaryText(colorScheme))
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
                .accessibilityLabel(String(localized: "重试"))
            }
            .padding(.leading, 14).padding(.trailing, 8)
            .frame(minHeight: pillHeight)
            .glassEffect(.regular.interactive(), in: .capsule)
            .frame(maxWidth: .infinity, alignment: .center)
            // The line reads as one element; the retry button stays a separate
            // element so its action is never folded into a combined label.
            .accessibilityIdentifier("chat.queue.banner")
            .padding(.horizontal, 20)
            .padding(.bottom, 4)
        }
    }

    /// Pause reasons map to one line each. An explicit failure wins over the
    /// offline derivation (`queuePauseForDisplay`), so a send that failed while
    /// offline still reports the failure the user can retry.
    private func message(count: Int) -> String {
        switch model.session.queuePauseForDisplay {
        case .offline?:
            return String(localized: "连接中断，\(count) 条消息未发出")
        default:
            return String(localized: "消息发送失败，\(count) 条未发出")
        }
    }
}

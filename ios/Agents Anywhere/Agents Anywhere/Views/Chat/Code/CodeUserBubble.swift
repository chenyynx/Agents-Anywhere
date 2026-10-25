import SwiftUI

// The Code page's user message: one right-aligned neutral bubble.
//
// This is the Code transcript's own bubble, not the Chat page's
// `UserMessageBubble` (SessionTimelineRow.swift): the Chat page paints the
// user bubble with the app accent, while the Code page keeps it neutral. The
// text is literal and selectable — a user message is never Markdown — and the
// value is laid out by the row, which joins the message's `.text` blocks
// before handing it over.

/// A user message on the Code page.
struct CodeUserBubble: View {
    /// The message body, already joined from the row's `.text` blocks.
    let text: String
    /// Reserved for the message's attachments. The Code page has no captured
    /// official attachment bubble yet, so the slot exists but renders nothing.
    var attachments: [ChatMessageAttachment] = []
    /// The optimistic-send state. The official model carries `isPending` on
    /// the same user role (`DisplayMessage.Role.user(isPending:)`), so the
    /// bubble itself must not change when the echo settles — only this gutter
    /// indicator does.
    var isPending = false
    var onDeliveryIssue: (() -> Void)?

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(alignment: .bottom, spacing: CodePageTheme.userBubbleSpacing) {
            Spacer(minLength: CodePageTheme.userBubbleLeadingGutter)
            VStack(alignment: .trailing, spacing: CodePageTheme.userBubbleSpacing) {
                if !text.isEmpty {
                    CodeUserBubbleText(
                        text: text,
                        color: CodePageTheme.userBubbleText.resolved(for: colorScheme))
                        .padding(.horizontal, CodePageTheme.userBubbleHorizontalPadding)
                        .padding(.vertical, CodePageTheme.userBubbleVerticalPadding)
                        .background(
                            CodePageTheme.userBubbleFill.resolved(for: colorScheme),
                            in: RoundedRectangle(
                                cornerRadius: CodePageTheme.userBubbleCornerRadius,
                                style: .continuous)
                        )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .overlay(alignment: .bottomLeading) {
            // The delivery state sits in the leading gutter so the echo never
            // changes the text width or the bubble's geometry.
            if isPending {
                ProgressView().progressViewStyle(.circular).controlSize(.small)
                    .frame(width: 18, height: 44).offset(x: -26)
                    .accessibilityLabel(String(localized: "正在发送消息"))
            } else if let onDeliveryIssue {
                Button(action: onDeliveryIssue) {
                    AppSymbol("exclamationmark.circle").foregroundStyle(.red)
                        .frame(width: 24, height: 44)
                }
                .buttonStyle(.plain)
                .offset(x: -30)
                .accessibilityLabel(String(localized: "查看发送问题"))
            }
        }
    }
}

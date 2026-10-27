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
    }
}

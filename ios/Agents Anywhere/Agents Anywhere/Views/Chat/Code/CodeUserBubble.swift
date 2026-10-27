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
struct CodeUserBubble<Delivery: View>: View {
    /// The message body, already joined from the row's `.text` blocks.
    let text: String
    /// Leading-gutter content owned by the bubble: the optimistic send's
    /// spinner or its failed-send marker. It is anchored to the bubble itself
    /// so it follows a short, right-aligned bubble instead of the row's
    /// leading edge.
    let delivery: Delivery

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
                        .overlay(alignment: .bottomLeading) { delivery }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

extension CodeUserBubble where Delivery == EmptyView {
    init(text: String) {
        self.text = text
        self.delivery = EmptyView()
    }
}

extension CodeUserBubble {
    init(text: String, @ViewBuilder delivery: () -> Delivery) {
        self.text = text
        self.delivery = delivery()
    }
}

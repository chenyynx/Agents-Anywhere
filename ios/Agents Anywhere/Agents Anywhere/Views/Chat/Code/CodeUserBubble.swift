import SwiftUI

// The Code page's user message: one right-aligned neutral bubble.
//
// This is the Code transcript's own bubble, not the retired Chat page's
// accent bubble: that page painted the user bubble with the app accent, while
// the Code page keeps it neutral. The
// text is literal and selectable — a user message is never Markdown — and the
// value is laid out by the row, which joins the message's `.text` blocks
// before handing it over.

/// A user message on the Code page.
struct CodeUserBubble<Delivery: View>: View {
    /// The message body, already joined from the row's `.text` blocks.
    let text: String
    /// A send the runtime has not read yet (a steer waiting for its echo)
    /// draws the queue's dashed waiting outline instead of the solid bubble;
    /// when the echo lands the settled row replaces this one. The stroke and
    /// secondary text match `QueuedMessageRow`'s waiting state, so "not in
    /// the transcript yet" reads the same in both places.
    var waitingOutline = false
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
                        color: waitingOutline
                            ? AppTheme.secondaryText(colorScheme)
                            : CodePageTheme.userBubbleText.resolved(for: colorScheme))
                        .padding(.horizontal, CodePageTheme.userBubbleHorizontalPadding)
                        .padding(.vertical, CodePageTheme.userBubbleVerticalPadding)
                        .background { bubbleBackground }
                        .overlay(alignment: .bottomLeading) { delivery }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    /// Solid fill for a settled (or already on-the-wire) message; the dashed
    /// outline only for one the runtime has not consumed yet. The dash and
    /// width are `QueuedMessageRow`'s, not new constants.
    @ViewBuilder private var bubbleBackground: some View {
        let shape = RoundedRectangle(
            cornerRadius: CodePageTheme.userBubbleCornerRadius,
            style: .continuous)
        if waitingOutline {
            shape.strokeBorder(
                AppTheme.secondaryControlStroke(colorScheme),
                style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
        } else {
            shape.fill(CodePageTheme.userBubbleFill.resolved(for: colorScheme))
        }
    }
}

extension CodeUserBubble where Delivery == EmptyView {
    init(text: String, waitingOutline: Bool = false) {
        self.text = text
        self.waitingOutline = waitingOutline
        self.delivery = EmptyView()
    }
}

extension CodeUserBubble {
    init(text: String, waitingOutline: Bool = false,
         @ViewBuilder delivery: () -> Delivery) {
        self.text = text
        self.waitingOutline = waitingOutline
        self.delivery = delivery()
    }
}

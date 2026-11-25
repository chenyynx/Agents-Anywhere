import SwiftUI
import UIKit

// The Code page's user message: one right-aligned neutral bubble.
//
// This is the Code transcript's own bubble, not the retired Chat page's
// accent bubble: that page painted the user bubble with the app accent, while
// the Code page keeps it neutral. The text is literal — a user message is
// never Markdown — and the value is laid out by the row, which joins the
// message's `.text` blocks before handing it over. Selection is entered from
// the long-press menu (copy / select text), not by a direct long press.

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
    /// The message menu (copy / select text). A held steer's row owns its own
    /// removal menu and turns this off so the two long-press menus do not
    /// compete.
    var showsActions = true

    @Environment(\.colorScheme) private var colorScheme
    /// "Select Text" hands the bubble to the TextKit view; until then the
    /// long-press menu owns the gesture (the official message menu's split).
    @State private var selectsText = false

    var body: some View {
        HStack(alignment: .bottom, spacing: CodePageTheme.userBubbleSpacing) {
            Spacer(minLength: CodePageTheme.userBubbleLeadingGutter)
            VStack(alignment: .trailing, spacing: CodePageTheme.userBubbleSpacing) {
                if !text.isEmpty {
                    bubbleText
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        // A reused row must not keep the selection mode of the message it
        // used to show.
        .onChange(of: text) { _, _ in selectsText = false }
    }

    @ViewBuilder private var bubbleText: some View {
        let content = CodeUserBubbleText(
            text: text,
            color: waitingOutline
                ? AppTheme.secondaryText(colorScheme)
                : CodePageTheme.userBubbleText.resolved(for: colorScheme),
            isSelectable: selectsText)
            .padding(.horizontal, CodePageTheme.userBubbleHorizontalPadding)
            .padding(.vertical, CodePageTheme.userBubbleVerticalPadding)
            .background { bubbleBackground }
            .overlay(alignment: .bottomLeading) { delivery }
        if showsActions, !selectsText {
            content.contextMenu {
                Button(String(localized: "复制"), systemImage: "doc.on.doc") {
                    UIPasteboard.general.string = text
                }
                Button(String(localized: "选择文本"), systemImage: "text.cursor") {
                    selectsText = true
                }
            }
        } else {
            content
        }
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
    init(text: String, waitingOutline: Bool = false, showsActions: Bool = true) {
        self.text = text
        self.waitingOutline = waitingOutline
        self.showsActions = showsActions
        self.delivery = EmptyView()
    }
}

extension CodeUserBubble {
    init(text: String, waitingOutline: Bool = false, showsActions: Bool = true,
         @ViewBuilder delivery: () -> Delivery) {
        self.text = text
        self.waitingOutline = waitingOutline
        self.showsActions = showsActions
        self.delivery = delivery()
    }
}

import SwiftUI

/// One row of the conversation outline: avatar, speaker, preview and time.
///
/// Metrics follow the official capture (2026-11-18): 24 pt avatar scaled with
/// `.body`, 13/15/13 pt text, 20 pt horizontal padding, one-line divider inset
/// to the text column.
struct ConversationOutlineRow: View {
    let content: ConversationOutlineRowContent
    /// The signed-in viewer's initials, or the photo carried by
    /// `avatarSource`; the official row uses the account, not the message.
    let initials: String
    let avatarSource: AccountAvatarImageSource?
    /// The session's agent mark (Claude, Codex, DSH …); the outline must not
    /// assume every session is Claude.
    let agentAsset: String
    let agentTint: Color?
    let action: () -> Void

    @ScaledMetric(relativeTo: .body) private var avatarSide: CGFloat = 24
    @ScaledMetric(relativeTo: .body) private var speakerSize: CGFloat = 13
    @ScaledMetric(relativeTo: .body) private var titleSize: CGFloat = 15
    @ScaledMetric(relativeTo: .body) private var detailSize: CGFloat = 13
    @ScaledMetric(relativeTo: .body) private var initialsSize: CGFloat = 13
    @ScaledMetric(relativeTo: .body) private var markSize: CGFloat = 14
    /// The extra leading between the row's three lines; the official type
    /// tokens scale it with the reader's text size.
    @ScaledMetric(relativeTo: .body) private var lineGap: CGFloat = 2.5
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Search rows fade in once when they first appear; typing does not
    /// re-trigger it because the row keeps its entry identity.
    @State private var appeared = false

    var body: some View {
        Button(action: action) {
            // The official avatar rides the top of the text column (its
            // center stays ~25 pt below the row top on one- and two-line
            // previews alike); centering it sank it on every 3-line row.
            HStack(alignment: .top, spacing: 12) {
                avatar
                VStack(alignment: .leading, spacing: lineGap) {
                    // The official row type is Anthropic Sans Mobile; using
                    // it lets the Latin "Claude" and the stamp's digits match
                    // the capture's letterforms and widths instead of SF's.
                    Text(content.speaker)
                        .font(ClaudeFont.text(speakerSize))
                        .foregroundStyle(ChatPalette.outlineSpeaker.color)
                    Text(styledTitle)
                        // The official title renders at the regular instance
                        // (stroke 2.60 px); 460 made it visibly bold.
                        .font(ClaudeFont.text(titleSize, weight: 400))
                        .foregroundStyle(ChatPalette.outlineTitle.color)
                        .lineLimit(content.titleLineLimit)
                        .lineSpacing(lineGap)
                        .multilineTextAlignment(.leading)
                        // A rounded background needs bounds per matched
                        // slice; AttributedString's background is square. The
                        // plain outline has no ranges and must not pay for the
                        // custom drawing path (pp 2026-11-21, scroll jank).
                        .modifier(ConversationOutlineHighlightModifier(
                            ranges: content.highlightRanges,
                            color: ChatPalette.outlineSearchHighlight.color))
                    Text(content.detail)
                        .font(ClaudeFont.text(detailSize, weight: 400))
                        .foregroundStyle(ChatPalette.outlineDetail.color)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 20)
            .padding(.trailing, 20)
            .padding(.vertical, 15)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(content.partID == nil || appeared ? 1 : 0)
        .onAppear {
            // Normal rows are never hidden; remember that they appeared so a
            // later search hit on the same entry cannot start at opacity 0.
            guard content.partID != nil else {
                appeared = true
                return
            }
            if reduceMotion {
                appeared = true
            } else {
                withAnimation(.easeOut(duration: 0.25)) { appeared = true }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(content.speaker))
        .accessibilityValue(Text(content.title))
        .accessibilityHint(Text(String(localized: "跳转到对话中的这条消息。")))
    }

    /// Inline code spans carry the official's mono face; the rest keeps the
    /// Anthropic row face set by the outer `.font`.
    private var styledTitle: AttributedString {
        var attributed = content.titleAttributed
        let codeRanges = attributed.runs.compactMap { run in
            run.inlinePresentationIntent?.contains(.code) == true ? run.range : nil
        }
        let codeFont = ClaudeFont.mono(titleSize)
        for range in codeRanges { attributed[range].font = codeFont }
        return attributed
    }

    private var avatar: some View {
        Group {
            if content.isUser {
                if let avatarSource {
                    AccountAvatarView(displayName: initials, source: avatarSource,
                                      size: avatarSide)
                } else {
                    Circle()
                        .fill(ChatPalette.outlineAvatarFill.color)
                        .overlay(
                            Text(initials)
                                .font(.system(size: initialsSize, weight: .semibold))
                                .foregroundStyle(ChatPalette.outlineAvatarInitials.color)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        )
                }
            } else if agentAsset == "aa-AgentClaudeCode" {
                // Claude keeps the official orange disc with the white
                // 12-ray mark.
                Circle()
                    .fill(ChatPalette.outlineClaudeAvatar.color)
                    .overlay(
                        Image(agentAsset)
                            .renderingMode(.template)
                            .resizable()
                            .scaledToFit()
                            .foregroundStyle(.white)
                            .frame(width: markSize, height: markSize)
                    )
            } else {
                // Other runtimes keep the same disc geometry with their own
                // mark and brand tint (DSH blue; Codex/Bot label ink).
                Circle()
                    .fill(ChatPalette.outlineAvatarFill.color)
                    .overlay(
                        Image(agentAsset)
                            .renderingMode(.template)
                            .resizable()
                            .scaledToFit()
                            .foregroundStyle(agentTint ?? ChatPalette.outlineAvatarInitials.color)
                            .frame(width: markSize, height: markSize)
                    )
            }
        }
        .frame(width: avatarSide, height: avatarSide)
        .accessibilityHidden(true)
    }
}

/// Attaches the highlight renderer only when a search actually produced
/// ranges. Mounting a `TextRenderer` on every row forces SwiftUI's custom
/// text-drawing path for the plain outline as well, where it only redraws
/// each line unchanged — measured as part of the scrolling cost
/// (pp 2026-11-21, `outline.frame`).
private struct ConversationOutlineHighlightModifier: ViewModifier {
    let ranges: [Range<Int>]
    let color: Color

    @ViewBuilder
    func body(content: Content) -> some View {
        if ranges.isEmpty {
            content
        } else {
            content.textRenderer(ConversationOutlineSearchHighlightRenderer(
                ranges: ranges, color: color))
        }
    }
}

/// Draws a small rounded highlight behind each matched slice. `Text`'s
/// AttributedString background is square, so the renderer slices each run at
/// the match boundaries and fills the slice's own typographic bounds.
nonisolated struct ConversationOutlineSearchHighlightRenderer: TextRenderer {
    let ranges: [Range<Int>]
    let color: Color
    var cornerRadius: CGFloat = 4

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        guard !ranges.isEmpty else {
            for line in layout { context.draw(line) }
            return
        }
        var offset = 0
        for line in layout {
            for run in line {
                let runEnd = offset + run.count
                for range in ranges {
                    let lower = max(range.lowerBound, offset)
                    let upper = min(range.upperBound, runEnd)
                    guard lower < upper else { continue }
                    let slice = run[(lower - offset)..<(upper - offset)]
                    let rect = slice.typographicBounds.rect.insetBy(dx: -1, dy: 1)
                    context.fill(Path(roundedRect: rect, cornerRadius: cornerRadius),
                                 with: .color(color))
                }
                context.draw(run)
                offset = runEnd
            }
        }
    }
}

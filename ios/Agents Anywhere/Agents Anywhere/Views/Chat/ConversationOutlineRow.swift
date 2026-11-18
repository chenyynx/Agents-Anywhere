import SwiftUI

/// One row of the conversation outline: avatar, speaker, preview and time.
///
/// Metrics follow the official capture (2026-11-18): 24 pt avatar scaled with
/// `.body`, 13/15/13 pt text, 20 pt horizontal padding, one-line divider inset
/// to the text column.
struct ConversationOutlineRow: View {
    let content: ConversationOutlineRowContent
    let action: () -> Void

    @ScaledMetric(relativeTo: .body) private var avatarSide: CGFloat = 24
    @ScaledMetric(relativeTo: .body) private var speakerSize: CGFloat = 13
    @ScaledMetric(relativeTo: .body) private var titleSize: CGFloat = 15
    @ScaledMetric(relativeTo: .body) private var detailSize: CGFloat = 13
    @ScaledMetric(relativeTo: .body) private var initialsSize: CGFloat = 13

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 12) {
                avatar
                VStack(alignment: .leading, spacing: 0) {
                    Text(content.speaker)
                        .font(.system(size: speakerSize))
                        .foregroundStyle(ChatPalette.outlineSpeaker.color)
                    Text(content.title)
                        .font(.system(size: titleSize))
                        .foregroundStyle(ChatPalette.outlineTitle.color)
                        .lineLimit(content.titleLineLimit)
                        .multilineTextAlignment(.leading)
                    Text(content.detail)
                        .font(.system(size: detailSize))
                        .foregroundStyle(ChatPalette.outlineDetail.color)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 20)
            .padding(.trailing, 20)
            .padding(.vertical, 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(content.speaker))
        .accessibilityValue(Text(content.title))
        .accessibilityHint(Text(String(localized: "跳转到对话中的这条消息。")))
    }

    private var avatar: some View {
        Group {
            if content.isUser {
                Circle()
                    .fill(ChatPalette.outlineAvatarFill.color)
                    .overlay(
                        Text(monogram)
                            .font(.system(size: initialsSize, weight: .semibold))
                            .foregroundStyle(ChatPalette.outlineAvatarInitials.color)
                    )
            } else {
                Circle()
                    .fill(ChatPalette.outlineClaudeAvatar.color)
                    .overlay(
                        Image(systemName: "asterisk")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                    )
            }
        }
        .frame(width: avatarSide, height: avatarSide)
        .accessibilityHidden(true)
    }

    /// The official client shows the account's initials. AA has no per-message
    /// account snapshot here, so the row uses the speaker's first character.
    private var monogram: String {
        String(content.speaker.prefix(1))
    }
}

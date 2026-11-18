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
    let action: () -> Void

    @ScaledMetric(relativeTo: .body) private var avatarSide: CGFloat = 24
    @ScaledMetric(relativeTo: .body) private var speakerSize: CGFloat = 13
    @ScaledMetric(relativeTo: .body) private var titleSize: CGFloat = 15
    @ScaledMetric(relativeTo: .body) private var detailSize: CGFloat = 13
    @ScaledMetric(relativeTo: .body) private var initialsSize: CGFloat = 13
    @ScaledMetric(relativeTo: .body) private var markSize: CGFloat = 13
    /// The extra leading between the row's three lines; the official type
    /// tokens scale it with the reader's text size.
    @ScaledMetric(relativeTo: .body) private var lineGap: CGFloat = 3
    @ScaledMetric(relativeTo: .body) private var detailTracking: CGFloat = 0.8

    var body: some View {
        Button(action: action) {
            // The official avatar rides the top of the text column (its
            // center stays ~25 pt below the row top on one- and two-line
            // previews alike); centering it sank it on every 3-line row.
            HStack(alignment: .top, spacing: 12) {
                avatar
                VStack(alignment: .leading, spacing: lineGap) {
                    // The official speaker is the same #525150 ink but a
                    // lighter stroke than ours (core 2.6 px vs 3.6 px at the
                    // same glyph size); SF Regular read visibly bolder.
                    Text(content.speaker)
                        .font(.system(size: speakerSize, weight: .light))
                        .foregroundStyle(ChatPalette.outlineSpeaker.color)
                    Text(content.title)
                        .font(.system(size: titleSize))
                        .foregroundStyle(ChatPalette.outlineTitle.color)
                        .lineLimit(content.titleLineLimit)
                        .lineSpacing(lineGap)
                        .multilineTextAlignment(.leading)
                    // ClaudeFonts sets the stamp wider than SF; the capture's
                    // "11月18日 17:23" runs 222 px where SF sets 199 px, so a
                    // small tracking reproduces the same rhythm.
                    Text(content.detail)
                        .font(.system(size: detailSize))
                        .tracking(detailTracking)
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(content.speaker))
        .accessibilityValue(Text(content.title))
        .accessibilityHint(Text(String(localized: "跳转到对话中的这条消息。")))
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
            } else {
                // The official mark is the 12-ray Claude logo, not SF Symbol's
                // 6-ray asterisk; the app already ships that asset.
                Circle()
                    .fill(ChatPalette.outlineClaudeAvatar.color)
                    .overlay(
                        Image("aa-AgentClaudeCode")
                            .renderingMode(.template)
                            .resizable()
                            .scaledToFit()
                            .foregroundStyle(.white)
                            .frame(width: markSize, height: markSize)
                    )
            }
        }
        .frame(width: avatarSide, height: avatarSide)
        .accessibilityHidden(true)
    }
}

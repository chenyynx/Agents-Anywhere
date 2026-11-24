import SwiftUI

/// The SubAgent panel's first screen (entry A, opened from the capsule): the
/// running count as a centred title over one card per SubAgent — the task name
/// on top and the live activity line underneath in the transcript working
/// row's ink and sweep. Tapping a card pushes the chat-like detail.
///
/// Layout follows the official running-agents card pp sent on 2026-11-24
/// (Grok 1.4.66, reverse-engineered at instruction level): 20 pt side / 12 pt
/// vertical list padding with 12 pt between cards; each card is a 24 pt-radius
/// outline with 16 / 12 pt padding, a 24 pt badge, a 14 pt icon-to-text gap,
/// and a 13 pt semibold title over the subagent's working row, both
/// single-line. The working row keeps the transcript's ink, family and sweep
/// (`CodePageTheme.runningStatusColor` + `CodeCollapsedRowShimmer`, pp
/// 2026-11-24) but scales its type down to the card's 13 pt. The card has no
/// fill; its 1 pt stroke is `primary.opacity(0.04)`, the reference's own value.
struct SubAgentAgentList: View {
    let cards: [SubAgentCard]
    let chat: SessionChatModel
    let onOpen: (String) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric(relativeTo: .footnote) private var iconSize: CGFloat = 24
    @ScaledMetric(relativeTo: .footnote) private var cornerRadius: CGFloat = 24
    @ScaledMetric(relativeTo: .footnote) private var titleFontSize: CGFloat = 13
    /// The working row's own type is 15 pt; the card scales it to the card's
    /// 13 pt so the activity line stays under the title (pp 2026-11-24: 改小).
    private let activityFontSize: CGFloat = 13
    /// The live line refreshes from the same presented rows the detail reads,
    /// so a streaming token or a tool change reaches the list without a timer.
    /// `flushRevision` is read on purpose: a token updates its row model in
    /// place, so the rows array alone would not re-evaluate this view.
    private var timelineItems: [V2TimelineItem] {
        _ = chat.timeline.flushRevision
        return chat.timeline.rows.map(\.value)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                ForEach(cards) { card in
                    Button { onOpen(card.id) } label: { cardRow(card) }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("chat.subagent.card.\(card.id)")
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppTheme.composerSheetBackground(colorScheme))
        // The reference puts the count as the sheet's centred title; the
        // inline navigation title is the same 17 pt semibold, below the
        // grabber, so no custom header is needed.
        .navigationTitle(String(localized: "\(cards.count) 个 Agent 正在运行"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func cardRow(_ card: SubAgentCard) -> some View {
        HStack(spacing: 14) {
            SubAgentMark(size: iconSize, tint: AppTheme.primaryText(colorScheme))
            VStack(alignment: .leading, spacing: 2) {
                Text(card.taskName)
                    .font(.system(size: titleFontSize, weight: .semibold))
                    .foregroundStyle(AppTheme.primaryText(colorScheme))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(SubAgentProgress.liveActivityText(for: card, in: timelineItems,
                                                       cwd: chat.session.metadata?.cwd))
                    .font(.custom(CodePageTheme.sansFontName,
                                  size: activityFontSize,
                                  relativeTo: .footnote))
                    .foregroundStyle(CodePageTheme.runningStatusColor.resolved(for: colorScheme))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .modifier(CodeCollapsedRowShimmer(active: true))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(cardShape)
        .overlay {
            cardShape.stroke(Color.primary.opacity(0.04), lineWidth: 1)
        }
    }

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius)
    }
}

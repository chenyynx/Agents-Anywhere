import SwiftUI

/// The SubAgent panel's first screen (entry A, opened from the capsule): the
/// running count as a centred title over one card per SubAgent — the task name
/// on top and the live activity line underneath in the app's secondary gray.
/// Tapping a card pushes the chat-like detail.
///
/// Layout follows the reference pp sent (2026-11-15, 1179×2556 @3x) as later
/// enlarged on device (pp 2026-11-16: 卡片有点小): the card is 340 pt wide
/// (26 pt side inset), ~68 pt tall with a 22 pt continuous radius and one
/// hairline border; the mark is ~25 pt of ink in a 30 pt frame, 18 pt from the
/// card's leading edge and 16 pt from the text column; the title is 16 pt
/// semibold over a 13 pt gray live line. The colours are our existing
/// composer-sheet surface + Code-page gray tokens, not the reference app's own
/// values.
struct SubAgentAgentList: View {
    let cards: [SubAgentCard]
    let chat: SessionChatModel
    let onOpen: (String) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric(relativeTo: .footnote) private var iconSize: CGFloat = 30
    @ScaledMetric(relativeTo: .footnote) private var cornerRadius: CGFloat = 22
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
            .padding(.horizontal, 26)
            .padding(.top, 20)
            .padding(.bottom, 24)
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
        HStack(spacing: 16) {
            SubAgentStarGlyph(size: iconSize, tint: AppTheme.primaryText(colorScheme))
            VStack(alignment: .leading, spacing: 3) {
                Text(card.taskName)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(AppTheme.primaryText(colorScheme))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(SubAgentProgress.liveActivityText(for: card, in: timelineItems,
                                                       cwd: chat.session.metadata?.cwd))
                    .font(.footnote)
                    .foregroundStyle(CodePageTheme.text400Color.resolved(for: colorScheme))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(AppTheme.composerTileBackground(colorScheme), in: cardShape)
        .overlay(cardShape.strokeBorder(AppTheme.composerTileBorder(colorScheme), lineWidth: 0.5))
        .contentShape(cardShape)
    }

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }
}

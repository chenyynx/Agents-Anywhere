import SwiftUI

/// The official `ClaudeCoreUI.QuestionAnsweredCard` (`InlineCardShell` solid
/// surface, no glass). Values live in `QuestionCardMetrics`, re-calibrated
/// 2026-11-20 against pp's installed official app (smaller than the R32
/// binary table, like the pending card).
///
/// Rendered inline at the question tool row's own position once the row
/// carries answers — the row keeps its place in the transcript, so history
/// (and other devices) replay the same card. A skipped question shows its
/// question line with no answer line (`answer?`).
struct QuestionAnsweredCardView: View {
    let pairs: [QuestionAnsweredPair]

    @Environment(\.colorScheme) private var colorScheme

    /// The answered card's header/question ink (#52514E on device) — darker
    /// than the pending card's `secondary`.
    private var questionInk: Color {
        QuestionCardTheme.color(QuestionCardMetrics.answeredSecondaryInk, colorScheme)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: QuestionCardMetrics.answeredSpacing) {
            typography(String(localized: "问题"),
                       size: QuestionCardMetrics.answeredHeaderSize,
                       lineHeight: QuestionCardMetrics.answeredHeaderLineHeight,
                       weight: QuestionCardMetrics.answeredHeaderWeight)
                .foregroundStyle(questionInk)
                .accessibilityAddTraits(.isHeader)
            // Each question stays with its answer (8 pt); pairs are 12 pt
            // apart — the official ink gaps measure 13.3 / 17.7 pt.
            ForEach(pairs) { pair in
                VStack(alignment: .leading, spacing: QuestionCardMetrics.answeredPairSpacing) {
                    typography(pair.question,
                               size: QuestionCardMetrics.answeredRowSize,
                               lineHeight: QuestionCardMetrics.answeredRowLineHeight,
                               weight: QuestionCardMetrics.answeredRowWeight)
                        .foregroundStyle(questionInk)
                    if let answer = pair.answer {
                        typography(answer,
                                   size: QuestionCardMetrics.answeredRowSize,
                                   lineHeight: QuestionCardMetrics.answeredRowLineHeight,
                                   weight: QuestionCardMetrics.answeredRowWeight)
                            .foregroundStyle(QuestionCardTheme.color(QuestionCardMetrics.answerInk, colorScheme))
                    }
                }
            }
        }
        .padding(.horizontal, QuestionCardMetrics.answeredHorizontalPadding)
        .padding(.vertical, QuestionCardMetrics.answeredVerticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            QuestionCardTheme.color(QuestionCardMetrics.cardSurface, colorScheme),
            in: RoundedRectangle(cornerRadius: QuestionCardMetrics.answeredCornerRadius,
                                 style: .continuous))
    }

    private func typography(_ text: String, size: CGFloat, lineHeight: CGFloat,
                            weight: CGFloat) -> some View {
        Text(text)
            .font(QuestionCardTheme.font(size: size, weight: weight))
            .lineSpacing(QuestionCardTheme.lineSpacing(size: size, lineHeight: lineHeight))
            .fixedSize(horizontal: false, vertical: true)
    }
}

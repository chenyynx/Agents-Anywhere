import SwiftUI

/// The official `ClaudeCoreUI.QuestionAnsweredCard` (`InlineCardShell` solid
/// surface, no glass). Values: CANONICAL/25-question-card.md §3 / R9.
///
/// Rendered inline at the question tool row's own position once the row
/// carries answers — the row keeps its place in the transcript, so history
/// (and other devices) replay the same card. A skipped question shows its
/// question line with no answer line (`answer?`).
struct QuestionAnsweredCardView: View {
    let pairs: [QuestionAnsweredPair]

    @Environment(\.colorScheme) private var colorScheme

    private var secondary: Color {
        QuestionCardTheme.color(QuestionCardMetrics.secondary, colorScheme)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: QuestionCardMetrics.answeredSpacing) {
            typography(String(localized: "问题"),
                       size: QuestionCardMetrics.answeredHeaderSize,
                       lineHeight: QuestionCardMetrics.answeredHeaderLineHeight,
                       weight: QuestionCardMetrics.answeredHeaderWeight)
                .foregroundStyle(secondary)
                .accessibilityAddTraits(.isHeader)
            ForEach(pairs) { pair in
                typography(pair.question,
                           size: QuestionCardMetrics.answeredRowSize,
                           lineHeight: QuestionCardMetrics.answeredRowLineHeight,
                           weight: QuestionCardMetrics.answeredRowWeight)
                    .foregroundStyle(secondary)
                if let answer = pair.answer {
                    typography(answer,
                               size: QuestionCardMetrics.answeredRowSize,
                               lineHeight: QuestionCardMetrics.answeredRowLineHeight,
                               weight: QuestionCardMetrics.answeredRowWeight)
                        .foregroundStyle(QuestionCardTheme.color(QuestionCardMetrics.answerInk, colorScheme))
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

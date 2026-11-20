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

    /// Exact pre-measure height for the collection layout.
    ///
    /// A standalone answered row used to fall back to the generic one-line
    /// tool estimate (44 pt) while the card draws ~96 pt, so every realised
    /// card corrected the layout by +52 under the reader: the tool row's card
    /// overlapped the neighbouring text row, and the content height crept up
    /// in 52 pt steps (pp 2026-11-21; log contentH 26944 → 27516, +52 each).
    static func estimatedHeight(pairs: [QuestionAnsweredPair], width: CGFloat) -> CGFloat {
        let textWidth = max(1, width - 2 * QuestionCardMetrics.answeredHorizontalPadding)
        // A one-line `Text` occupies the face's own line box; extra token
        // line height only applies between lines — the same arithmetic
        // `QuestionCardTheme.lineSpacing` feeds the view.
        func textHeight(_ text: String, size: CGFloat, weight: CGFloat,
                        lineHeight: CGFloat) -> CGFloat {
            let font = MarkdownFontFactory.font(name: CodePageTheme.sansFontName,
                                                size: size, weight: weight)
            let bounds = (text as NSString).boundingRect(
                with: CGSize(width: textWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: font], context: nil)
            let lines = max(1, Int((bounds.height / font.lineHeight).rounded(.up)))
            return font.lineHeight + CGFloat(lines - 1) * lineHeight
        }
        var height = 2 * QuestionCardMetrics.answeredVerticalPadding
        height += textHeight(String(localized: "问题"),
                             size: QuestionCardMetrics.answeredHeaderSize,
                             weight: QuestionCardMetrics.answeredHeaderWeight,
                             lineHeight: QuestionCardMetrics.answeredHeaderLineHeight)
        for pair in pairs {
            height += QuestionCardMetrics.answeredSpacing
            height += textHeight(pair.question,
                                 size: QuestionCardMetrics.answeredRowSize,
                                 weight: QuestionCardMetrics.answeredRowWeight,
                                 lineHeight: QuestionCardMetrics.answeredRowLineHeight)
            if let answer = pair.answer {
                height += QuestionCardMetrics.answeredPairSpacing
                height += textHeight(answer,
                                     size: QuestionCardMetrics.answeredRowSize,
                                     weight: QuestionCardMetrics.answeredRowWeight,
                                     lineHeight: QuestionCardMetrics.answeredRowLineHeight)
            }
        }
        return ceil(height)
    }
}

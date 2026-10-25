import SwiftUI
import UIKit

/// The Code page's persistent thinking row: the official
/// `Block.thinkingContent` → `ThinkingContentRow`.
///
/// Official structure (round24 `thinking-row-detail-and-style.md`): a
/// `CollapsedRowButton` with the `anthropicon.extendedThinking` artwork at
/// the medium preset (16×16 artwork in the 20 pt slot), the fixed
/// `思考过程` label at 15/400/21, and a `caretRight` at the medium preset.
/// The icon and caret use the shared `toolRowSecondaryColor`
/// (#7B7974 light / #97958D dark); the label keeps the default label ink.
/// The button is a single line (`minHeight 24`, vertical padding 6) and a tap
/// opens the full-text sheet; the row never expands in place.
struct CodeThinkingRow: View {
    let action: () -> Void

    @ScaledMetric(relativeTo: CodePageTheme.toolRowTextStyle)
    private var lineHeight = CodePageTheme.toolRowLineHeight

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            HStack(spacing: CodePageTheme.toolRowSpacing) {
                AnthropiconView(name: "anthropicon.extendedThinking", size: .medium)
                    .foregroundStyle(CodePageTheme.toolRowSecondaryColor
                        .resolved(for: colorScheme))

                Text(String(localized: "thought_process"))
                    .font(.custom(CodePageTheme.sansFontName,
                                  size: CodePageTheme.toolRowFontSize,
                                  relativeTo: CodePageTheme.toolRowTextStyle))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)

                Spacer(minLength: 0)

                AnthropiconView(name: "anthropicon.caretRight", size: .medium)
                    .foregroundStyle(CodePageTheme.toolRowSecondaryColor
                        .resolved(for: colorScheme))
            }
            .frame(minHeight: lineHeight, alignment: .leading)
            .padding(.vertical, CodePageTheme.toolRowButtonPadding)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "thought_process"))
    }
}

#Preview("Thinking row") {
    CodeThinkingRow {}
        .padding(.horizontal, CodePageTheme.rowMarginLeading)
}

import SwiftUI
import UIKit

/// The Code page's persistent thinking row: the official
/// `Block.thinkingContent` → `CollapsedStepsRow` (R28 §7). It shares the
/// tool row's component: `anthropicon.extendedThinking` in the 24 pt
/// `IconFrame` (medium 16×16 artwork, `isFramed = true`), the
/// `thought_process` label at Anthropic Sans 15/400/21 in `text400`, and the
/// `caretRight` (medium, frame height 24, `text400`). Status is
/// `ToolPhase.complete`, `failureExtent` is nil, `hasDetails` is true and
/// `diffIndicator` is nil — exactly the official init bytes.
///
/// The button never expands in place; a tap opens the full-text sheet.
struct CodeThinkingRow: View {
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        CodeCollapsedStepsRow(
            icon: "anthropicon.extendedThinking",
            // [E] R28 §7 — the thinking glyph renders at Icon.Size.medium.
            iconSize: .medium,
            text: Text(String(localized: "thought_process"))
                .font(.custom(CodePageTheme.sansFontName,
                              size: CodePageTheme.toolRowFontSize,
                              relativeTo: CodePageTheme.toolRowBodyTextStyle))
                // [E] R28 §7 — non-summary row text is `text400`.
                .foregroundStyle(CodePageTheme.text400Color
                    .resolved(for: colorScheme)),
            status: .complete,
            failureExtent: nil,
            hasDetails: true,
            diffIndicator: nil,
            workingMark: nil,
            isTextHidden: false,
            includesImages: false,
            voiceControlName: nil,
            spokenLabel: nil,
            isRunning: false,
            action: action)
    }
}

#Preview("Thinking row") {
    CodeThinkingRow {}
        .padding(.horizontal, CodePageTheme.rowMarginLeading)
}

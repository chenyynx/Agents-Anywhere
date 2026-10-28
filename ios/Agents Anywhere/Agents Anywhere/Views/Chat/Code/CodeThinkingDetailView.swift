import SwiftUI

/// The Code page's thinking detail: the official `TranscriptDetail.thinkingText`
/// sheet (`0x102c5de1c` → `0x102c5f32c`).
///
/// Official structure (round24 `thinking-row-detail-and-style.md`): a sheet
/// with medium/large detents, an inner `NavigationStack`, and the full raw
/// thinking markdown rendered by `RichMarkdownView`. The title is the same
/// `思考过程` key as the row; the leading close is the system close role.
struct CodeThinkingDetailView: View {
    let text: String

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        NavigationStack {
            ScrollView {
                CodeThinkingMarkdownView(text: text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 16)
            }
            .scrollBounceBehavior(.basedOnSize, axes: .vertical)
            .background {
                CodePageTheme.pageBackgroundColor
                    .resolved(for: colorScheme)
                    .ignoresSafeArea()
            }
            .navigationTitle(Text(String(localized: "thought_process")))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                SheetCloseToolbar { dismiss() }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// The Code page's thinking Markdown: the official `MarkdownText` leaf at the
/// decoded 15/400/21 Typography (relative `.body`, `text100`/`text300` ink),
/// not the Chat renderer's compact 13 pt. The leaf is the same one the Code
/// message body uses, so link/selection behaviour is unchanged.
struct CodeThinkingMarkdownView: View {
    let text: String

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.legibilityWeight) private var legibilityWeight

    var body: some View {
        CodeMarkdownTextLeaf(text: text, typography: typography)
    }

    private var typography: TimelineTypographySnapshot {
        TimelineChatContentAdapter.typography(
            dynamicType: String(describing: dynamicTypeSize),
            layoutDirection: layoutDirection == .rightToLeft ? 1 : 0,
            boldText: legibilityWeight == .bold,
            scale: CodePageTheme.thinkingMarkdownScale)
    }
}

#Preview("Thinking detail") {
    CodeThinkingDetailView(text: """
    Let me check the failing test output before updating the plan.

    The failure comes from the collapsed row keeping a stale height key.
    """)
}

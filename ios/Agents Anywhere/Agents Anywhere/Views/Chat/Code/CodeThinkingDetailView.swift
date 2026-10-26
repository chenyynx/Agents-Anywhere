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
                ChatMarkdownView(text: text,
                                 isStreaming: false,
                                 resolvesFileReferences: true)
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

#Preview("Thinking detail") {
    CodeThinkingDetailView(text: """
    Let me check the failing test output before updating the plan.

    The failure comes from the collapsed row keeping a stale height key.
    """)
}

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
    /// The row's item id, so the sheet can follow an in-place deferred
    /// completion. Nil in previews and the gate.
    var itemID: V2TimelineItemID? = nil
    /// Every settled reasoning row merged into this thinking block. The
    /// message path joins multiple rows; reading only `itemID` would drop the
    /// later ones from the detail.
    var sourceIDs: [V2TimelineItemID] = []
    /// The page's deferred-item reader. Present in the product presentation;
    /// nil in previews and the gate.
    var chat: SessionChatModel? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    private func liveItem(_ id: V2TimelineItemID) -> V2TimelineItem? {
        chat?.session.timeline.first { $0.id == id }?.value
    }

    /// Every row the block was built from, in order.
    private var allIDs: [V2TimelineItemID] {
        sourceIDs.isEmpty ? (itemID.map { [$0] } ?? []) : sourceIDs
    }

    /// The merged block's rows that are still summarized.
    private var deferredIDs: [V2TimelineItemID] {
        allIDs.filter { liveItem($0)?.isDeferred == true }
    }

    private var bodyText: String {
        // A merged thinking block is several rows joined in order. Rebuild the
        // same shape from the window's current rows; fall back to the captured
        // text when any row has left the window.
        let ids = sourceIDs.isEmpty ? (itemID.map { [$0] } ?? []) : sourceIDs
        let liveTexts = ids.compactMap { id -> String? in
            guard let item = liveItem(id), !item.displayText.isEmpty else { return nil }
            return item.displayText
        }
        guard liveTexts.count == ids.count, !liveTexts.isEmpty else { return text }
        return liveTexts.joined(separator: "\n\n")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    CodeThinkingMarkdownView(text: bodyText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let chat,
                       !deferredIDs.isEmpty
                        || allIDs.contains(where: { chat.deferredItems.phase($0) == .loaded }) {
                        DeferredLoadFooter(chat: chat, ids: allIDs, kind: .thinking)
                    }
                }
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

    @MainActor
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

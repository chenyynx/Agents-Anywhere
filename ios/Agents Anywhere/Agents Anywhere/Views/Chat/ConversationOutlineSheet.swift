import Combine
import SwiftUI

/// A one-shot request to scroll the timeline to a message row. The page holds
/// one instance and hands it to both the timeline (which performs the scroll,
/// paging history when needed) and the outline sheet (which posts the target).
@MainActor
final class ConversationOutlineJumpRequest: ObservableObject {
    @Published private(set) var token = 0
    private(set) var rowID: String?

    func request(_ rowID: String) {
        self.rowID = rowID
        token &+= 1
    }
}

/// The conversation outline panel: title + search drawer, a single white card
/// of rows, and the official count line while the list is empty.
struct ConversationOutlineSheet: View {
    let chat: SessionChatModel
    let jump: ConversationOutlineJumpRequest

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var entries: [ConversationOutlineEntry] = []
    /// Rows the local store holds beyond the loaded window. Read off the main
    /// actor when the panel opens and merged under the live timeline.
    @State private var cachedItems: [V2TimelineItem] = []
    @State private var machine = ConversationOutlineJumpMachine()
    /// The official panel title is 20 pt bold and centered; the system inline
    /// title renders 17 pt, so the toolbar carries the measured style.
    @ScaledMetric(relativeTo: .headline) private var titleSize: CGFloat = 20

    var body: some View {
        NavigationStack {
            ScrollView {
                content
            }
            .background(ChatPalette.outlineSheetBackground.color.ignoresSafeArea())
            .navigationTitle(Text(String(localized: "对话大纲")))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(String(localized: "对话大纲"))
                        .font(.system(size: titleSize, weight: .bold))
                        .foregroundStyle(ChatPalette.outlineTitle.color)
                }
                ToolbarItem(placement: .topBarLeading) { closeButton }
            }
            .searchable(
                text: $query,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: Text(String(localized: "消息中的字词"))
            )
            .task { await loadCachedRows() }
            .onChange(of: chat.session.timeline.count) { _, _ in reload() }
        }
    }

    // MARK: - Content

    private struct RowModel: Identifiable {
        let entry: ConversationOutlineEntry
        let hit: ConversationOutlineSearchHit?
        var id: V2TimelineItemID { entry.id }
    }

    private var rowModels: [RowModel] {
        guard !ConversationOutlineSearch.tokens(query).isEmpty else {
            return entries.map { RowModel(entry: $0, hit: nil) }
        }
        let byID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ConversationOutlineSearch.filter(entries, query: query).compactMap { hit in
            byID[hit.entryID].map { RowModel(entry: $0, hit: hit) }
        }
    }

    @ViewBuilder private var content: some View {
        if rowModels.isEmpty {
            // The official empty state is the count line alone — no card, no
            // illustration, and it is the only state that shows the line.
            Text(countLine(shown: 0, total: messageCount))
                .font(.system(size: 15))
                .foregroundStyle(ChatPalette.outlineCount.color)
                .frame(maxWidth: .infinity, alignment: .leading)
                // The capture puts the line's left edge 43.7 pt from the
                // screen edge; the scroll view itself has no inset.
                .padding(.leading, 44)
                .padding(.top, 12)
        } else {
            card(rowModels)
        }
    }

    private func card(_ rows: [RowModel]) -> some View {
        LazyVStack(spacing: 0) {
            ForEach(rows) { row in
                    ConversationOutlineRow(
                        content: ConversationOutlineRowContentMaker.content(
                            for: row.entry,
                            hit: row.hit
                        ),
                        action: { choose(row) }
                    )
                if row.id != rows.last?.id {
                    Rectangle()
                        .fill(ChatPalette.outlineDivider.color)
                        .frame(height: 0.5)
                        .padding(.leading, 54)
                        .padding(.trailing, 20)
                }
            }
        }
        .background(ChatPalette.outlineCard.color)
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    private var closeButton: some View {
        Button { dismiss() } label: {
            Image(systemName: "xmark")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(ChatPalette.outlineTitle.color)
                .frame(width: 38, height: 38)
                .background(Circle().fill(ChatPalette.outlineCard.color))
                .overlay(Circle().stroke(ChatPalette.outlineDivider.color, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(String(localized: "关闭")))
    }

    // MARK: - Data

    private func loadCachedRows() async {
        // The loaded window renders first; the disk read only adds history
        // that is outside it.
        reload()
        let items = await chat.repository.outlineItems(
            sessionId: chat.session.id,
            limit: ConversationOutlineSource.cacheRowLimit,
            byteBudget: ConversationOutlineSource.cacheByteBudget
        )
        guard !Task.isCancelled else { return }
        cachedItems = items
        reload()
    }

    private func reload() {
        entries = ConversationOutlineEntryBuilder.entries(
            from: ConversationOutlineSource.merged(
                live: chat.session.timeline.map { $0.value },
                cached: cachedItems
            )
        )
    }

    /// The official count line counts messages, not outline rows: one row can
    /// hold several messages of the same turn and sender.
    private var messageCount: Int {
        entries.reduce(0) { $0 + $1.parts.count }
    }

    private func countLine(shown: Int, total: Int) -> String {
        String(
            format: String(localized: "已显示 %1$lld/%2$lld 条消息"),
            Int64(shown),
            Int64(total)
        )
    }

    // MARK: - Jump

    private func choose(_ row: RowModel) {
        guard !machine.state.isBusy else { return }
        let partID = row.hit?.partID ?? row.entry.parts.first?.id ?? row.entry.id
        let target = ConversationOutlineJumpTarget(entryID: row.entry.id, partID: partID)
        _ = machine.handle(.choose(target))
        _ = machine.handle(.begin)
        jump.request(partID)
        dismiss()
    }
}

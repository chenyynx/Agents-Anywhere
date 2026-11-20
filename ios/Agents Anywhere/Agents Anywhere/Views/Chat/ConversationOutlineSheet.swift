import Combine
import Foundation
import SwiftUI
import UIKit

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
    @Environment(AppState.self) private var appState
    @State private var query = ""
    @State private var entries: [ConversationOutlineEntry] = []
    /// Rows the local store holds beyond the loaded window. Read off the main
    /// actor when the panel opens and merged under the live timeline.
    @State private var cachedItems: [V2TimelineItem] = []
    /// Snapshot of the live window. The sheet must not observe the streaming
    /// transcript from `body`: a tick that grew an assistant row re-rendered
    /// every outline row and made the sheet crawl while the agent thought
    /// (pp 2026-11-21). A task refreshes this at a calm cadence instead.
    @State private var liveItems: [V2TimelineItem] = []
    @State private var machine = ConversationOutlineJumpMachine()
    /// True while the search field's keyboard is up. A downward drag then
    /// belongs to the keyboard, not the sheet: letting the sheet's own drag
    /// run at the same time put two animations on one finger — the keyboard
    /// interactive dismissal and the detent drag — and read as a stutter
    /// (pp 2026-11-21). With the sheet pinned, the list owns the drag and the
    /// keyboard follows it; once the keyboard is gone the usual drag-dismiss
    /// comes back.
    @State private var keyboardVisible = false
    /// The capture's count line is a 15 pt token that scales with the reader's
    /// text size (≈12.9 pt at the captured setting), not a fixed 15 pt.
    @ScaledMetric(relativeTo: .body) private var countSize: CGFloat = 15

    var body: some View {
        NavigationStack {
            ScrollView {
                content
            }
            // The keyboard follows the drag instead of dropping in its own
            // animation the moment the list starts to scroll — the same
            // interactive dismissal the transcript uses (pp 2026-11-21).
            .scrollDismissesKeyboard(.interactively)
            // Whether a downward drag actually reaches this list, and whether
            // the keyboard follows it, is the question two device rounds could
            // not answer (pp 2026-11-21). Phase changes only: per-frame
            // scrolling would flood the diagnostics trail.
            .onScrollPhaseChange { old, new, _ in
                OutlineProbe.shared.noteScroll(
                    old: old.outlineDiagnosticName,
                    new: new.outlineDiagnosticName
                )
            }
            .background(ChatPalette.outlineSheetBackground.color.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(ChatPalette.outlineSheetBackground.color, for: .navigationBar)
            .toolbarBackgroundVisibility(.visible, for: .navigationBar)
            .toolbar {
                // The app's standard sheet close is the system glass circle;
                // drawing another circle inside it read as a double ring.
                SheetCloseToolbar { dismiss() }
                ToolbarItem(placement: .principal) {
                    Text(String(localized: "对话大纲"))
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(ChatPalette.outlineTitle.color)
                }
            }
            .searchable(
                text: $query,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: Text(String(localized: "消息中的字词"))
            )
            .task {
                OutlineProbe.shared.begin(
                    sessionID: chat.session.id,
                    rows: entries.count,
                    live: liveItems.count,
                    cached: cachedItems.count
                )
                defer { OutlineProbe.shared.end() }
                OutlineProbe.shared.noteStatus(
                    chat.session.runtime.state?.status.rawValue
                )
                refreshLiveItems()
                await loadCachedRows()
                // Keep the outline roughly current without re-rendering on
                // every streaming tick: one refresh per second while open.
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    guard !Task.isCancelled else { break }
                    OutlineProbe.shared.noteStatus(
                        chat.session.runtime.state?.status.rawValue
                    )
                    refreshLiveItems()
                }
            }
        }
        // The official panel opens as the draggable half sheet used by the
        // step-group and add-to-chat pages, not full height.
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(ChatPalette.outlineSheetBackground.color)
        // While the keyboard is up, downward drags drive the keyboard's
        // interactive dismissal instead of the sheet's detent drag; the two
        // at once are what stuttered (pp 2026-11-21).
        .interactiveDismissDisabled(keyboardVisible)
        .onReceive(NotificationCenter.default.publisher(
            for: UIResponder.keyboardWillShowNotification)) { note in
            keyboardVisible = true
            OutlineProbe.shared.noteKeyboard(
                phase: "show",
                height: keyboardHeight(note)
            )
        }
        .onReceive(NotificationCenter.default.publisher(
            for: UIResponder.keyboardWillHideNotification)) { note in
            keyboardVisible = false
            OutlineProbe.shared.noteKeyboard(
                phase: "hide",
                height: keyboardHeight(note)
            )
        }
    }

    // MARK: - Content

    private struct RowModel: Identifiable {
        let entry: ConversationOutlineEntry
        let hit: ConversationOutlineSearchHit?
        var id: V2TimelineItemID { entry.id }
    }

    private func rowModels(from hits: [ConversationOutlineSearchHit]) -> [RowModel] {
        let byID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return hits.compactMap { hit in
            byID[hit.entryID].map { RowModel(entry: $0, hit: hit) }
        }
    }

    /// The official line appears throughout a search, with or without hits:
    /// "已显示 22/72 条消息" sits above the result card. It stays hidden in
    /// the plain, unsearched list.
    private var isSearching: Bool {
        !ConversationOutlineSearch.tokens(query).isEmpty
    }

    private var content: some View {
        // One pass returns both the rows and the count-line numerator; the
        // unsearched list just maps every entry without a hit.
        let result: ConversationOutlineSearchResult? = isSearching
            ? ConversationOutlineSearch.search(entries, query: query)
            : nil
        let rows = result.map { rowModels(from: $0.hits) }
            ?? entries.map { RowModel(entry: $0, hit: nil) }
        return VStack(alignment: .leading, spacing: 0) {
            if let result {
                countLineView(shown: result.messageCount)
            } else if entries.isEmpty {
                // An empty, unsearched outline keeps the measured 0/0 line.
                countLineView(shown: 0)
            }
            if !rows.isEmpty {
                card(rows)
            }
        }
    }

    private func countLineView(shown: Int) -> some View {
        Text(countLine(shown: shown, total: messageCount))
            .font(ClaudeFont.text(countSize, weight: 400))
            .foregroundStyle(ChatPalette.outlineCount.color)
            .frame(maxWidth: .infinity, alignment: .leading)
            // The capture puts the line's left edge 37.3 pt from the screen
            // edge and its ink 41.3 pt below the search pill.
            .padding(.leading, 36)
            .padding(.top, 26)
    }

    private func card(_ rows: [RowModel]) -> some View {
        LazyVStack(spacing: 0) {
            ForEach(rows) { row in
                ConversationOutlineRow(
                    content: rowContent(for: row),
                    initials: viewerInitials,
                    avatarSource: appState.accountAvatarSource,
                    agentAsset: agentMark.asset,
                    agentTint: agentTint,
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
        // With the count line above, the capture puts the card's top edge
        // ~10 pt below that line; without it the old gap stays.
        .padding(.top, isSearching ? 10 : 16)
    }

    /// The agent this session runs (Claude, Codex, DSH …), for the speaker
    /// label and the row's mark. The outline must not assume Claude.
    private var agentRuntime: String { chat.session.metadata?.runtime ?? "" }
    private var agentRuntimeType: String? { chat.session.metadata?.runtimeType }
    private var agentMark: (asset: String, label: String) {
        SessionAgentMark.resolve(runtime: agentRuntime, runtimeType: agentRuntimeType)
    }
    private var agentTint: Color? {
        SessionAgentMark.tint(runtime: agentRuntime, runtimeType: agentRuntimeType)
    }
    private var outlineStrings: ConversationOutlineStrings {
        ConversationOutlineStrings(agentName: chat.agentName)
    }

    /// The official rows wear the signed-in viewer's initials (or photo), not
    /// the speaker's first character. Same rule as the sidebar avatar: the
    /// first letter of the first two words.
    private var viewerInitials: String {
        let words = (appState.me?.displayName ?? "").split(whereSeparator: { $0.isWhitespace })
        let letters = words.prefix(2).compactMap { $0.first }
        return letters.isEmpty ? "?" : String(letters).uppercased()
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

    /// Refresh the live snapshot only when rows actually appear or leave;
    /// text growth inside a streaming row never changes the outline and must
    /// not re-render the sheet.
    private func refreshLiveItems() {
        let items = chat.session.timeline.map { $0.value }
        guard items.map(\.id) != liveItems.map(\.id) else { return }
        liveItems = items
        reload()
    }

    private func reload() {
        let started = CFAbsoluteTimeGetCurrent()
        entries = ConversationOutlineEntryBuilder.entries(
            from: ConversationOutlineSource.merged(
                live: liveItems,
                cached: cachedItems
            )
        )
        OutlineProbe.shared.noteReload(
            ms: (CFAbsoluteTimeGetCurrent() - started) * 1000,
            rows: entries.count,
            live: liveItems.count,
            cached: cachedItems.count
        )
    }

    private func keyboardHeight(_ note: Notification) -> Double {
        let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey]
            as? CGRect
        return Double(frame?.height ?? 0)
    }

    /// Builds one row's content and reports its cost. Kept out of the
    /// `ForEach` closure: statements inside a `ViewBuilder` body made the
    /// compiler resolve `ForEach` to its `Binding` overload and refused the
    /// row array (b1406 app build).
    private func rowContent(for row: RowModel) -> ConversationOutlineRowContent {
        let started = CFAbsoluteTimeGetCurrent()
        let content = ConversationOutlineRowContentMaker.content(
            for: row.entry,
            hit: row.hit,
            strings: outlineStrings
        )
        OutlineProbe.shared.noteContentBuild(
            ms: (CFAbsoluteTimeGetCurrent() - started) * 1000
        )
        return content
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
        OutlineProbe.shared.noteJump(searching: row.hit != nil)
        let partID = row.hit?.partID ?? row.entry.parts.first?.id ?? row.entry.id
        let target = ConversationOutlineJumpTarget(entryID: row.entry.id, partID: partID)
        _ = machine.handle(.choose(target))
        _ = machine.handle(.begin)
        jump.request(partID)
        dismiss()
    }
}

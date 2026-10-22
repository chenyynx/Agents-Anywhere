import Foundation
import Observation

struct ChatTimelineGroup: Identifiable, Equatable {
    // `.agents` no longer reaches the main timeline since L2.1 (the grouping
    // filter in `groups` keeps SubAgent child rows out). It stays declared
    // because `TimelineRowStructure` still classifies those rows and the
    // panel reuses the same row projection — dropping the case would reach
    // into the panel's rendering for no user-visible gain.
    enum Kind: Equatable { case single, tools, reconnect, agents(String) }
    let kind: Kind
    let rows: [ChatTimelineRowModel]
    /// The Code page's message key (`nativeMessageId ?? itemId`). A code group
    /// is one persisted message whose identity is declared by the wire, not by
    /// whichever row happened to arrive first; without this, the first row
    /// landing late would rename the item and drop its height/scroll state.
    /// Groups built by `groups(_:interactionTargets:)` keep nil and stay keyed
    /// on their first row exactly as before.
    var explicitID: String?
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.kind == rhs.kind && lhs.explicitID == rhs.explicitID
            && lhs.rows.elementsEqual(rhs.rows, by: ===)
    }
    // The first row owns the group, even as the second tool arrives. A group
    // growing during a stream does not replace the scroll target or its state.
    var id: String { explicitID ?? rows[0].id }
    var status: V2TimelineItemStatus {
        if rows.contains(where: { $0.structure.status.isActive }) { return .running }
        return rows.first(where: { $0.structure.status.isFailure })?.structure.status ?? .done
    }
    var title: String {
        switch kind {
        case .single: return ""
        case .agents:
            // Nested Agent calls keep the call count; a group that carries a
            // card's progress rows (tool/thinking/text) counts its items —
            // calling those "calls" would misstate what is folded away.
            let calls = rows.filter { SubAgentProgress.isAgentCall($0.value) }.count
            if calls == rows.count { return String(localized: "\(rows.count) 次 SubAgent 调用") }
            return String(localized: "SubAgent 进展 · \(rows.count) 项")
        case .reconnect:
            let attempts = rows.compactMap { $0.structure.reconnectAttempt }
            // The full retry messages remain available in the expanded rows.
            return String(localized: "连接重试 · \(rows.count) 次") + (attempts.last.map { "（\($0)）" } ?? "")
        case .tools:
            let reasoning = rows.filter { $0.structure.isReasoning }.count
            let tools = rows.count - reasoning
            return [reasoning > 0 ? String(localized: "\(reasoning) 段思考") : nil, tools > 0 ? String(localized: "\(tools) 次工具调用") : nil].compactMap { $0 }.joined(separator: " · ")
        }
    }
}

enum TimelineGrouping {
    static func groups(_ rows: [ChatTimelineRowModel], interactionTargets: Set<String>) -> [ChatTimelineGroup] {
        var groups: [ChatTimelineGroup] = []
        var pending: [ChatTimelineRowModel] = []
        var pendingKind = ChatTimelineGroup.Kind.single
        func flush() {
            guard !pending.isEmpty else { return }
            groups.append(ChatTimelineGroup(kind: pending.count > 1 ? pendingKind : .single, rows: pending))
            pending = []
        }
        for row in rows {
            // L2.1 (pp 2026-10-04): the main chat keeps only the dispatch card.
            // Every row the connector attributed to an Agent card — tool,
            // thinking and text alike — leaves the main timeline; its content is
            // read from `chat.timeline.rows` by the panel and the card's 查看详情
            // entry, both of which this filter does not touch.
            // An interaction target is exempt: an approval card anchors on its
            // own row, and that row has to stay visible or the card would fall
            // between the group renderer and the orphan notice list.
            // Grouping reads the row's structure projection, never `row.value`:
            // `groupKind == .agents` is set exactly when the item carries a
            // parentItemId, but reading the value would let a streaming token or
            // tool-output refresh invalidate the list and regroup history.
            if case .agents = row.structure.groupKind, !interactionTargets.contains(row.id) { continue }
            let kind: ChatTimelineGroup.Kind = interactionTargets.contains(row.id) ? .single : row.structure.groupKind
            if kind == .single { flush(); groups.append(ChatTimelineGroup(kind: .single, rows: [row])); continue }
            if pendingKind != kind { flush() }
            pendingKind = kind; pending.append(row)
        }
        flush()
        return groups
    }

    /// The Code page's top-level grouping: one persisted message = one group.
    ///
    /// The wire declares the message boundary (`source.nativeMessageId ??
    /// source.itemId`, server `timeline_message_group_key`), so a group takes
    /// that key as its `explicitID` instead of the first row that arrives.
    /// First-seen message keys define the order; a row without a key — and an
    /// interaction target, which an approval card anchors on — stays a
    /// single-row group so the notice keeps its anchor.
    ///
    /// Rows are filtered exactly as the old grouping filtered them:
    /// `isVisibleInChat` (hidden rows, turn markers, signature-only reasoning)
    /// and sub-agent children (`content.parentItemId`, L2.1 — their content is
    /// read from the sub-agent panel). Stacking follows
    /// `CodeMessageBuilder.isStackable`: reasoning / message / tool / file
    /// change rows join a message group, everything else keeps its own row.
    ///
    /// `profile` decides whether a message still has anything to render: a
    /// message whose only rows are calls the runtime skips (Claude's
    /// `ExitPlanMode` / `AskUserQuestion`) produces no blocks, and a group
    /// with no blocks would still pay row margins and estimate height. The
    /// check mirrors `CodeMessageBuilder.messageRow`'s empty-block guard
    /// without building the blocks twice.
    static func codeGroups(_ rows: [ChatTimelineRowModel],
                           profile: CodeRuntimeProfile,
                           interactionTargets: Set<String>) -> [ChatTimelineGroup] {
        enum Slot: Hashable {
            case message(String)
            case row(String)
        }
        var order: [Slot] = []
        var seen: Set<Slot> = []
        // The projection hands over one version per item id; the first
        // occurrence wins, the same rule `CodeMessageBuilder.rows` applies.
        var consumed: Set<String> = []
        var groupedRows: [String: [ChatTimelineRowModel]] = [:]
        var standalone: [String: ChatTimelineRowModel] = [:]

        for row in rows {
            let item = row.value
            guard item.isVisibleInChat else { continue }
            guard consumed.insert(row.id).inserted else { continue }

            // An approval/notice card targets a row by id; that row has to
            // stay its own item or the card would fall between the message
            // renderer and the orphan notice list. The exemption also wins
            // over the sub-agent filter: a sub-agent's tool can be the very
            // row an approval card anchors on (the old grouping applied the
            // same precedence).
            if interactionTargets.contains(row.id) {
                standalone[row.id] = row
                let slot = Slot.row(row.id)
                if seen.insert(slot).inserted { order.append(slot) }
                continue
            }
            if isSubAgentChild(item) { continue }

            if isCodeStackable(item), let key = CodeMessageBuilder.groupKey(for: item) {
                let slot = Slot.message(key)
                if seen.insert(slot).inserted { order.append(slot) }
                groupedRows[key, default: []].append(row)
            } else {
                standalone[row.id] = row
                let slot = Slot.row(row.id)
                if seen.insert(slot).inserted { order.append(slot) }
            }
        }

        return order.compactMap { slot -> ChatTimelineGroup? in
            switch slot {
            case let .message(key):
                let groupRows = groupedRows[key] ?? []
                guard messageHasContent(groupRows, profile: profile) else { return nil }
                return ChatTimelineGroup(kind: .single, rows: groupRows, explicitID: key)
            case let .row(id):
                guard let row = standalone[id] else { return nil }
                return ChatTimelineGroup(kind: .single, rows: [row])
            }
        }
    }

    // MARK: - Code row predicates

    /// `CodeMessageBuilder.isStackable`, reproduced here because the builder
    /// keeps it private. Kept in the same terms — a message stacks reasoning,
    /// body and tool/file-change rows only — so a row can never land in a
    /// message group the builder would then refuse to render.
    private static func isCodeStackable(_ item: V2TimelineItem) -> Bool {
        item.isReasoning || item.type == .message || isToolRow(item)
    }

    /// A wire `tool` row, or a row declaring `content.kind == "file_change"`
    /// (Codex publishes a file change on an artifact row).
    private static func isToolRow(_ item: V2TimelineItem) -> Bool {
        item.type == .tool || item.type == .fileChange
            || item.raw["content"]?["kind"] == .string("file_change")
    }

    /// `content.parentItemId` is the connector's L2 attribution of a row to
    /// the Agent card that owns it (same reader as `CodeMessageBuilder`); an
    /// empty value is absent.
    private static func isSubAgentChild(_ item: V2TimelineItem) -> Bool {
        TimelineText.first(item.raw["content"]?["parentItemId"]) != nil
    }

    /// Whether the message keeps a timeline item at all. Body and reasoning
    /// rows always do: a reasoning row is the live status line, and keeping
    /// the group through the reasoning→body hand-over avoids a remove/insert
    /// of the message item (which would re-assert the opening scroll). A tool
    /// row only disappears when the profile skips its call and no other row
    /// would render — the same empty-block rule as the builder.
    private static func messageHasContent(_ rows: [ChatTimelineRowModel],
                                          profile: CodeRuntimeProfile) -> Bool {
        rows.contains { row in
            let item = row.value
            if item.type == .message || item.isReasoning { return true }
            guard isToolRow(item) else { return true }
            return !profile.skippedToolNames.contains(CodeToolCall.wireName(for: item))
        }
    }

    static func reconnectMessage(_ item: V2TimelineItem) -> String? {
        guard item.type == .system, item.status == .failed else { return nil }
        let raw = item.raw["content"]
        let message = TimelineText.first(raw?["details"]?["error"]?["message"], raw?["details"]?["message"], raw?["message"], raw?["text"])
        return message?.hasPrefix("Reconnecting...") == true ? message : nil
    }
}

@MainActor @Observable final class TimelineDisclosureState {
    @Observable fileprivate final class Entry { var expanded = false }
    @ObservationIgnored private var entries: [String: Entry] = [:]
    /// Bumped on every toggle. Fold state changes a group's height without
    /// changing its rows, so the collection adapter needs one observable
    /// signal to recompute signatures; reading every entry would couple the
    /// wrapper to ids it does not know yet.
    private(set) var revision = 0
    private func entry(_ id: String) -> Entry {
        if let existing = entries[id] { return existing }
        let value = Entry(); entries[id] = value; return value
    }
    // Each fold observes its own bit. Toggling one tool must not reconstruct
    // every other expanded tool's diff and output subtree.
    func isExpanded(_ id: String) -> Bool { entry(id).expanded }
    func toggle(_ id: String) {
        entry(id).expanded.toggle()
        revision &+= 1
    }
}

import Foundation
import Observation

struct ChatTimelineGroup: Identifiable {
    // `.agents` no longer reaches the main timeline since L2.1 (the grouping
    // filter in `groups` keeps SubAgent child rows out). It stays declared
    // because `TimelineRowStructure` still classifies those rows and the
    // panel reuses the same row projection — dropping the case would reach
    // into the panel's rendering for no user-visible gain.
    enum Kind: Equatable { case single, tools, reconnect, agents(String) }
    let kind: Kind
    let rows: [ChatTimelineRowModel]
    // The first row owns the group, even as the second tool arrives. A group
    // growing during a stream does not replace the scroll target or its state.
    var id: String { rows[0].id }
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
    private func entry(_ id: String) -> Entry {
        if let existing = entries[id] { return existing }
        let value = Entry(); entries[id] = value; return value
    }
    // Each fold observes its own bit. Toggling one tool must not reconstruct
    // every other expanded tool's diff and output subtree.
    func isExpanded(_ id: String) -> Bool { entry(id).expanded }
    /// Non-creating read for the windowed timeline's height estimates: a fold
    /// that has never been toggled has no entry and is collapsed. Reading a
    /// hidden group through `isExpanded` would mint entries for the whole
    /// unloaded history on every estimate pass.
    func isExpandedIfKnown(_ id: String) -> Bool { entries[id]?.expanded ?? false }
    func toggle(_ id: String) { entry(id).expanded.toggle() }
}

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
    /// The row an interaction card (approval / question) is anchored to. A
    /// standalone anchor row draws the Code page's 5 pt row margins and pays
    /// no list gap, so a docked card sits at the same distance as a step-group
    /// anchor. Paying the list's legacy 20 pt gap while drawing no margins put
    /// the question card ~20 pt lower than the approval card (pp 2026-11-16).
    var isInteractionAnchor: Bool = false
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.kind == rhs.kind && lhs.explicitID == rhs.explicitID
            && lhs.isInteractionAnchor == rhs.isInteractionAnchor
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

extension ChatTimelineGroup {
    /// The standalone compaction divider: one marker row with no declared
    /// message key. It draws its own 16 pt vertical padding.
    var isStandaloneCompactDivider: Bool {
        explicitID == nil && rows.count == 1
            && TimelineEntryPresentation.isCompactItem(rows[0].value)
    }

    /// Whether the row supplies its own vertical breathing room. Code/chat
    /// message and step rows carry 5 pt row margins; the compaction divider
    /// carries 16 pt padding. The list must not add its 20 pt gap after
    /// these — paying it on the divider's trailing side alone left 20 pt
    /// more space below the divider than above it (device 2026-11-15).
    var isSelfMargined: Bool {
        explicitID != nil || isStandaloneCompactDivider || isInteractionAnchor
    }

    /// The vertical gap the collection list adds after this group.
    var listSpacing: CGFloat { isSelfMargined ? 0 : TimelineListMetrics.itemSpacing }
}

enum TimelineGrouping {
    static func groups(_ rows: [ChatTimelineRowModel], interactionTargets: Set<String>,
                       standaloneTargets: Set<String>? = nil) -> [ChatTimelineGroup] {
        grouped(rows, interactionTargets: interactionTargets,
                standaloneTargets: standaloneTargets, includeAgentRows: false)
    }

    /// C0 fallback (2026-10-23): the whole window can be rows the connector
    /// attributed to an Agent card — the server used to return them inside the
    /// latest page. The default grouping drops every one of them (L2.1), so the
    /// main timeline would render nothing at all. Keeping them here groups the
    /// window exactly as the card's own fold does (consecutive rows of one
    /// parent merge); the panel still reads `chat.timeline.rows`, so nothing is
    /// hidden from it.
    static func fallbackGroups(_ rows: [ChatTimelineRowModel], interactionTargets: Set<String>,
                               standaloneTargets: Set<String>? = nil) -> [ChatTimelineGroup] {
        grouped(rows, interactionTargets: interactionTargets,
                standaloneTargets: standaloneTargets, includeAgentRows: true)
    }

    /// The fallback applies only when the window holds no main-agent row: the
    /// default grouping then leaves the reader looking at a blank page. An
    /// interaction-anchored child row keeps its own default group, but the card
    /// it belongs to is still outside the window, so it must not suppress the
    /// fallback either.
    static func needsAgentFallback(_ rows: [ChatTimelineRowModel]) -> Bool {
        !rows.isEmpty && !rows.contains { row in
            if case .agents = row.structure.groupKind { return false }
            return true
        }
    }

    /// The older-history spinner is released by its anchor group's layout.
    /// With no rows the page has no group to lay out, so a request started then
    /// must not create a position that could never settle.
    static func usesHistoryAnchor(_ rows: [ChatTimelineRowModel]) -> Bool { !rows.isEmpty }

    private static func grouped(
        _ rows: [ChatTimelineRowModel],
        interactionTargets: Set<String>,
        standaloneTargets: Set<String>?,
        includeAgentRows: Bool
    ) -> [ChatTimelineGroup] {
        // Session-blocking cards are docked above the composer; their rows can
        // merge into a step group. Only the inline (non-blocking) anchors need
        // a standalone row (pp 2026-11-16).
        let standalone = standaloneTargets ?? interactionTargets
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
            // entry, both of which this filter does not touch. `includeAgentRows`
            // is the C0 fallback for a window that has nothing else to show.
            // An interaction target is exempt: an approval card anchors on its
            // own row, and that row has to stay visible or the card would fall
            // between the group renderer and the orphan notice list.
            // Grouping reads the row's structure projection, never `row.value`:
            // `groupKind == .agents` is set exactly when the item carries a
            // parentItemId, but reading the value would let a streaming token or
            // tool-output refresh invalidate the list and regroup history.
            if case .agents = row.structure.groupKind, !interactionTargets.contains(row.id), !includeAgentRows { continue }
            let isInteractionAnchor = standalone.contains(row.id)
            let kind: ChatTimelineGroup.Kind = isInteractionAnchor ? .single : row.structure.groupKind
            if kind == .single {
                flush()
                groups.append(ChatTimelineGroup(kind: .single, rows: [row],
                                                isInteractionAnchor: isInteractionAnchor))
                continue
            }
            if pendingKind != kind { flush() }
            pendingKind = kind; pending.append(row)
        }
        flush()
        return groups
    }

    /// The Code page's top-level grouping: one unit from the shared planner =
    /// one group.
    ///
    /// The planner (`CodeMessageBuilder.units`) owns the row sequence: for the
    /// Claude profile a serial tool run is one cross-message span and a
    /// message's own body keeps its tools; for other runtimes the declared
    /// message key still groups the rows. This function only applies the
    /// page's visibility rules and turns each unit into a group:
    /// - `.message` keeps its declared key as `explicitID`,
    /// - `.span` takes the planner's stable span id (the first tool's
    ///   `source.itemId`), so a new serial call grows the same top-level item,
    /// - `.standalone` draws through `CodeStandaloneRowView` and stays keyless
    ///   on purpose: that renderer owns the inline interaction cards, the turn
    ///   footer and the interrupted notice, which the explicit-key branch does
    ///   not draw.
    ///
    /// Rows are filtered before planning exactly as the old grouping filtered
    /// them: `isVisibleInChat` (hidden rows, turn markers, signature-only
    /// reasoning). Sub-agent children and interaction targets are the
    /// planner's job, so both the builder and the grouping apply one rule.
    ///
    /// `profile` decides whether a message unit still has anything to render: a
    /// unit whose only rows are calls the runtime skips produces no blocks, and
    /// a group with no blocks would still pay row margins and estimate height.
    /// The check mirrors the builder's empty-block guard without building the
    /// blocks twice.
    static func codeGroups(_ rows: [ChatTimelineRowModel],
                           profile: CodeRuntimeProfile,
                           interactionTargets: Set<String>,
                           standaloneTargets: Set<String>? = nil) -> [ChatTimelineGroup] {
        let standalone = standaloneTargets ?? interactionTargets
        // The projection hands over one version per item id; the first
        // occurrence wins, the same rule the planner applies. Keeping the row
        // model alongside its item lets the unit list map back without a
        // second scan of the window.
        var rowsByID: [V2TimelineItemID: ChatTimelineRowModel] = [:]
        var visibleItems: [V2TimelineItem] = []
        rowsByID.reserveCapacity(rows.count)
        visibleItems.reserveCapacity(rows.count)
        for row in rows {
            let item = row.value
            guard item.isVisibleInChat else { continue }
            if rowsByID[item.id] == nil { rowsByID[item.id] = row }
            visibleItems.append(item)
        }

        let units = CodeMessageBuilder.units(for: visibleItems,
                                             profile: profile,
                                             interactionTargets: interactionTargets)
        var groups: [ChatTimelineGroup] = []
        groups.reserveCapacity(units.count)
        for unit in units {
            let unitRows = unit.items.compactMap { rowsByID[$0.id] }
            guard !unitRows.isEmpty else { continue }
            switch unit {
            case let .message(key, _):
                guard messageHasContent(unitRows, profile: profile) else { continue }
                groups.append(ChatTimelineGroup(kind: .single, rows: unitRows, explicitID: key))
            case let .span(id, _):
                groups.append(ChatTimelineGroup(kind: .single, rows: unitRows, explicitID: id))
            case .standalone:
                // Deliberately keyless even when the row is a message: the
                // standalone renderer carries the interaction cards, the turn
                // footer and the interrupted notice, which the explicit-key
                // branch does not draw. The first-frame estimate uses the Chat
                // typography for these (rare) rows; hosting measurement
                // settles the real height.
                //
                // An interaction target is self-margined like a message row:
                // its card docks directly below, so the list's 20 pt gap
                // would read as a blank band under the card's anchor row
                // (pp 2026-11-16).
                let isInteractionAnchor = unitRows.contains { standalone.contains($0.id) }
                groups.append(ChatTimelineGroup(kind: .single, rows: unitRows,
                                               isInteractionAnchor: isInteractionAnchor))
            }
        }
        return groups
    }

    // MARK: - Code row predicates

    /// A wire `tool` row, or a row declaring `content.kind == "file_change"`
    /// (Codex publishes a file change on an artifact row).
    private static func isToolRow(_ item: V2TimelineItem) -> Bool {
        item.type == .tool || item.type == .fileChange
            || item.raw["content"]?["kind"] == .string("file_change")
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
            let name = CodeToolCall.wireName(for: item)
            guard profile.skippedToolNames.contains(name) else { return true }
            // An answered AskUserQuestion draws its own card, so its message
            // group must survive even when the question row is the only one.
            return name == "AskUserQuestion" && QuestionAnsweredModel(item: item) != nil
        }
    }

    static func reconnectMessage(_ item: V2TimelineItem) -> String? {
        guard item.type == .system, item.status == .failed else { return nil }
        let raw = item.raw["content"]
        let message = TimelineText.first(raw?["details"]?["error"]?["message"], raw?["details"]?["message"], raw?["message"], raw?["text"])
        return message?.hasPrefix("Reconnecting...") == true ? message : nil
    }
}

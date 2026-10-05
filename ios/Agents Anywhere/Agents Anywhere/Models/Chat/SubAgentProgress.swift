import Foundation

/// L2 SubAgent progress projection (claude-subagent-progress-tasks.md §3.2/§3.3).
///
/// Everything here is derived from persisted timeline items, so the capsule and
/// the panel restore after a relaunch or on another device without extra state.
/// The keys read are the connector's read-only conventions (content free JSON,
/// `claude/runtimes/claude/timeline/agent_calls.py`): an Agent card is a tool
/// item whose `content.kind == "agent_call"`, carrying `description`, `agentType`,
/// `prompt`, `agents[taskId] = {status, lastToolName, subagentType, …}`,
/// `usage = {toolCalls, tokens, durationMs}` and the overlay's flat `summary`.
/// Rows belonging to one card carry `content.parentItemId == card.id`
/// (`messages.py` for tool rows, `lifecycle.py` for thinking/text rows).

// MARK: - Phase

/// One card's phase, mapped defensively from the item status. An unrecognized
/// status keeps its wire text verbatim instead of being flattened to "unknown"
/// (the design's 防御式透传: 运行中/已完成/失败/已中断/未知原文).
enum SubAgentPhase: Equatable {
    case running
    /// Dispatched, but the subagent has not reported its first task event yet
    /// (the connector's `async_launched` receipt is still the agent's status).
    case starting
    case completed
    case failed
    case interrupted
    case unknown(String?)

    /// `launching` comes from the card's **agents entry** status, never from
    /// the item status: during the launch window the item already reads
    /// `running`, so an item-level test would never see the launch.
    static func from(itemStatus: V2TimelineItemStatus, rawStatus: String?, launching: Bool) -> SubAgentPhase {
        switch itemStatus {
        case .pending, .running, .waitingApproval: return launching ? .starting : .running
        // 防御行: a connector that stamps `done` on a still-launched agent must
        // not close the card — the live entry outranks the item status, which
        // also heals the cards misjudged before the server-side clamp landed.
        case .done: return launching ? .starting : .completed
        case .failed: return .failed
        case .interrupted, .cancelled: return .interrupted
        case .hidden, .unknown: return .unknown(rawStatus)
        }
    }

    /// Starting counts as active everywhere "still working" is asked
    /// (capsule, default tab, the final-output gate).
    var isActive: Bool { self == .running || self == .starting }
    var isFailure: Bool { self == .failed || self == .interrupted }

    /// The panel's status word. Unknown statuses show the wire text as-is.
    var word: String {
        switch self {
        case .running: return String(localized: "运行中")
        case .starting: return String(localized: "启动中")
        case .completed: return String(localized: "已完成")
        case .failed: return String(localized: "失败")
        case .interrupted: return String(localized: "已中断")
        case .unknown(let raw): return raw ?? String(localized: "未知")
        }
    }
}

// MARK: - Card

/// One SubAgent as seen on the timeline: an Agent call card plus the aggregate
/// state the task events folded onto it. Read-only projection of the item.
struct SubAgentCard: Identifiable, Equatable {
    let id: String
    let orderSeq: Int
    let taskName: String
    let agentType: String?
    let prompt: String?
    let phase: SubAgentPhase
    let toolCalls: Int?
    let tokens: Int?
    let durationMs: Int?
    /// The subagent's verbatim final reply (task_notification fold).
    let summary: String?
    /// Non-nil for a nested card (a frame parented to another Agent call).
    let parentItemID: String?
    let isBackgrounded: Bool?
    /// The card's dispatch moment (item creation). The capsule's failure rule
    /// compares it against a failure's end to tell a new batch from an older one.
    let dispatchedAt: Date?
    /// When a failure/interruption ended: the overlay's epoch-ms `endTime`,
    /// else the item's completion (or last update) time. Only consulted for
    /// failed/interrupted cards.
    let failedAt: Date?

    var isTopLevel: Bool { parentItemID == nil }

    /// The tab chip badge: only non-default agent types earn one.
    var badge: String? {
        guard let agentType, !agentType.isEmpty, agentType != SubAgentProgress.defaultAgentType else { return nil }
        return agentType
    }
}

// MARK: - Progress

enum SubAgentProgress {
    /// The CLI resolves an omitted subagent_type to this name (A1 findings §6).
    static let defaultAgentType = "general-purpose"

    /// The connector's "dispatched, not started yet" marker on an agents entry
    /// (`agent_calls.py` async receipt). While it holds, the subagent is alive
    /// whatever the item status says.
    static let asyncLaunchedStatus = "async_launched"

    /// An Agent call card: a tool item whose content kind is `agent_call`.
    static func isAgentCall(_ item: V2TimelineItem) -> Bool {
        item.type == .tool && item.raw["content"]?["kind"] == .string("agent_call")
    }

    /// The card a child row belongs to (the connector's `parentItemId`
    /// convention). Main-agent rows carry no such key.
    static func parentItemID(_ item: V2TimelineItem) -> String? {
        TimelineText.first(item.raw["content"]?["parentItemId"])
    }

    /// Parse one Agent call item; nil for every other item.
    static func card(_ item: V2TimelineItem) -> SubAgentCard? {
        guard isAgentCall(item) else { return nil }
        let raw = item.raw["content"] ?? .object([:])
        let agents = raw["agents"]?.objectValue ?? [:]
        let entry = primaryAgentEntry(raw: raw, agents: agents)
        let usage = raw["usage"]?.objectValue ?? [:]
        let parent = parentItemID(item)
        return SubAgentCard(
            id: item.id,
            orderSeq: item.orderSeq,
            taskName: TimelineText.first(raw["description"], raw["title"]) ?? String(localized: "Agent"),
            agentType: TimelineText.first(raw["agentType"], entry?["subagentType"]),
            prompt: TimelineText.first(raw["prompt"]),
            // The unrecognized status text lives on the item itself; the
            // agents entry is the fallback when the item one is missing.
            // The launch signal, on the other hand, is read from the entry
            // alone: while a subagent starts the item status is already
            // "running", so an item-level test could never show 启动中.
            phase: .from(itemStatus: item.status,
                         rawStatus: TimelineText.first(item.raw["status"], entry?["status"]),
                         launching: entry?["status"]?.stringValue == asyncLaunchedStatus),
            toolCalls: usage["toolCalls"]?.intValue,
            tokens: usage["tokens"]?.intValue,
            durationMs: usage["durationMs"]?.intValue,
            summary: TimelineText.first(raw["summary"]),
            parentItemID: parent,
            isBackgrounded: entry?["isBackgrounded"]?.boolValue ?? raw["runInBackground"]?.boolValue,
            dispatchedAt: Self.date(item.createdAt),
            failedAt: Self.terminalDate(raw: raw, item: item)
        )
    }

    /// Every Agent call card in the window, in dispatch (order) sequence.
    static func cards(in items: [V2TimelineItem]) -> [SubAgentCard] {
        items.compactMap(card).sorted { $0.orderSeq < $1.orderSeq }
    }

    /// The cards the capsule and the panel tabs surface: v1 renders one layer,
    /// so nested cards (child rows of another card) stay inside the parent.
    static func topLevelCards(in items: [V2TimelineItem]) -> [SubAgentCard] {
        cards(in: items).filter(\.isTopLevel)
    }

    /// One turn's page (pp 2026-10-05: 每轮都是新的页): the top-level cards
    /// sharing the opening card's turn, so a dispatch point on an older turn
    /// reopens that turn's page and a new dispatch opens the new one.
    ///
    /// The wire carries no turn id — `turnId` is a runtime field the server
    /// strips before publishing (`_without_runtime_turn_ids`), so the model's
    /// `turnId` decodes to nil in production and cannot anchor a page. The
    /// turn is bounded by the app's own visible-turn rule instead: from the
    /// last `startsVisibleTurn` user row at or before the anchor to the next
    /// one after it (steering messages and interrupt placeholders never split
    /// a turn). Falls back to the whole presented window when the anchor is
    /// gone — the pre-scope behaviour, kept deliberately.
    static func turnScopedTopLevelCards(in items: [V2TimelineItem], containing cardID: String?) -> [SubAgentCard] {
        let all = topLevelCards(in: items)
        guard let cardID, let anchor = items.firstIndex(where: { $0.id == cardID }) else { return all }
        let start = items[0...anchor].lastIndex(where: { $0.startsVisibleTurn }) ?? 0
        let end = items[(anchor + 1)...].firstIndex(where: { $0.startsVisibleTurn }) ?? items.count
        let scoped = topLevelCards(in: Array(items[start..<end]))
        return scoped.isEmpty ? all : scoped
    }

    /// The card's child rows, in timeline order (tool, thinking and text rows
    /// the connector attributed with `content.parentItemId`).
    static func children(of cardID: String, in items: [V2TimelineItem]) -> [V2TimelineItem] {
        items.filter { parentItemID($0) == cardID }
    }

    /// One card's activity rows: every child row the chat would show, in
    /// timeline order — tools, reasoning and text interleaved exactly as the
    /// connector published them (pp 2026-10-05: the panel shows one
    /// chronological activity list, not per-kind sections). The same
    /// `isVisibleInChat` gate the main chat uses, so a row hidden there (an
    /// empty reasoning, a hidden status) never enters the panel either.
    static func activityRows(of cardID: String, in items: [V2TimelineItem]) -> [V2TimelineItem] {
        children(of: cardID, in: items).filter(\.isVisibleInChat)
    }

    /// Opening rule (§3.2/§3.3): an explicitly requested card wins; otherwise
    /// the first running tab, else the first card.
    static func defaultSelection(_ cards: [SubAgentCard], requested: String?) -> String? {
        if let requested, cards.contains(where: { $0.id == requested }) { return requested }
        return cards.first(where: { $0.phase.isActive })?.id ?? cards.first?.id
    }

    /// The capsule: visible exactly while a top-level SubAgent runs or is still
    /// starting; a failure of the newest batch tints the whole capsule red
    /// (§3.2, rule below).
    static func capsuleState(_ items: [V2TimelineItem]) -> SubAgentCapsuleState {
        let cards = topLevelCards(in: items)
        let running = cards.filter { $0.phase.isActive }
        return SubAgentCapsuleState(
            runningCount: running.count,
            hasFailure: hasLiveFailure(in: cards),
            singleTaskName: running.count == 1 ? running[0].taskName : nil,
            latestRunningID: running.last?.id,
            // The word follows the card the capsule speaks for (the newest
            // active one), so a subagent that is still starting is not read
            // out as "运行中".
            phaseWord: running.last?.phase.word ?? String(localized: "运行中")
        )
    }

    // MARK: Active-card sidecar

    /// How long a card may go unconfirmed before the sidecar drops it.
    ///
    /// The API has no single-timeline-item read (`GET /sessions/{id}/timeline`
    /// serves latest / changes / history ranges only), so a card cannot be
    /// reconciled by id after a disconnect; ageing is the backstop for the one
    /// case the recovery replay cannot cover — a terminal frame lost while
    /// offline, or a card that never reported again. The threshold is
    /// deliberately long (宁长勿短): the connector writes the card on every task
    /// event, so a genuinely active card is confirmed orders of magnitude more
    /// often than this, while a real SubAgent run has been observed at 30+
    /// minutes and may block on a single long tool call without writing
    /// anything. Six hours therefore never hides live work, and a card whose
    /// terminal frame was missed cannot pin the capsule for a whole workday.
    static let activeCardStaleAfter: TimeInterval = 6 * 60 * 60

    /// Memory fuse. Concurrent top-level SubAgents beyond this are not a real
    /// shape (the field is 1 while a card runs); the oldest dispatch is evicted
    /// so the newest work survives if the bound is ever reached.
    static let maximumActiveAgentCards = 20

    /// Fold one timeline item into the sidecar: a top-level card that has not
    /// reached a terminal phase is stored, a terminal one is removed, and any
    /// other row is ignored. Callers feed **every** item, before any window
    /// guard — a card that has been pushed out of the loaded timeline still
    /// reaches here, which is the whole point of the sidecar.
    ///
    /// A version older than the stored one changes nothing in either direction:
    /// a stale "running" frame cannot revive a newer card and a stale "done"
    /// cannot close it (the same rule the timeline window uses).
    static func absorbingActiveCards(
        _ item: V2TimelineItem,
        into stored: [V2ActiveAgentCard],
        now: Date
    ) -> [V2ActiveAgentCard] {
        // Ageing runs here as well as at read time, and on every row rather than
        // only on card rows, so a session that is visited but never re-confirms
        // an entry cannot keep it alive.
        var cards = liveCards(stored, now: now)
        guard isAgentCall(item) else { return cards }
        let index = cards.firstIndex { $0.item.id == item.id }
        if let index, !item.supersedes(cards[index].item) { return cards }
        guard let parsed = card(item), parsed.isTopLevel, parsed.phase.isActive else {
            // Nested cards never entered, so removing a miss is a no-op.
            guard let index else { return cards }
            cards.remove(at: index)
            return cards
        }
        let entry = V2ActiveAgentCard(item: item, confirmedAt: now)
        if let index { cards[index] = entry } else { cards.append(entry) }
        guard cards.count > maximumActiveAgentCards else { return cards }
        cards.sort { $0.item.orderSeq < $1.item.orderSeq }
        return Array(cards.suffix(maximumActiveAgentCards))
    }

    /// The entries still inside the ageing window. Every timeline row runs this,
    /// so the check keeps the common path allocation-free.
    private static func liveCards(_ stored: [V2ActiveAgentCard], now: Date) -> [V2ActiveAgentCard] {
        guard stored.contains(where: { now.timeIntervalSince($0.confirmedAt) >= activeCardStaleAfter })
        else { return stored }
        return stored.filter { now.timeIntervalSince($0.confirmedAt) < activeCardStaleAfter }
    }

    /// The capsule's item set: the loaded window plus the sidecar, unioned by id
    /// with the newer version winning so a card present in both is counted once.
    /// This is what makes the capsule's visibility independent of the window
    /// (§3.2: 显隐只由有无活跃 SubAgent 决定).
    static func capsuleItems(
        inWindow window: [V2TimelineItem],
        activeCards: [V2ActiveAgentCard],
        now: Date = Date()
    ) -> [V2TimelineItem] {
        var byID = Dictionary(uniqueKeysWithValues: window.map { ($0.id, $0) })
        for entry in activeCards where now.timeIntervalSince(entry.confirmedAt) < activeCardStaleAfter {
            if let existing = byID[entry.item.id], !entry.item.supersedes(existing) { continue }
            byID[entry.item.id] = entry.item
        }
        return byID.values.sorted { ($0.orderSeq, $0.id) < ($1.orderSeq, $1.id) }
    }

    /// The capsule over the window plus the sidecar. The item-level overload
    /// stays the one place the state itself is derived.
    static func capsuleState(
        inWindow window: [V2TimelineItem],
        activeCards: [V2ActiveAgentCard],
        now: Date = Date()
    ) -> SubAgentCapsuleState {
        capsuleState(capsuleItems(inWindow: window, activeCards: activeCards, now: now))
    }

    /// The panel's reach for the capsule's count
    /// (ios-capsule-activity-window §8): every active card the capsule counts
    /// that the opening turn's page does not already list — a dispatch from an
    /// earlier turn, or one the loaded window has moved past. Read from the same
    /// window ∪ sidecar union as the capsule, so the panel can never show fewer
    /// cards than the capsule promises.
    static func otherActiveCards(
        inWindow window: [V2TimelineItem],
        activeCards: [V2ActiveAgentCard],
        page: [SubAgentCard],
        now: Date = Date()
    ) -> [SubAgentCard] {
        let listed = Set(page.map(\.id))
        return topLevelCards(in: capsuleItems(inWindow: window, activeCards: activeCards, now: now))
            .filter { $0.phase.isActive && !listed.contains($0.id) }
    }

    /// Whether a card's own rows are loaded, i.e. it is one of the rows this
    /// client holds. False means the panel can still show the card's own facts
    /// (name, phase, prompt) but has none of its tool / thinking / output rows,
    /// and must say so rather than render an empty body or a silent "finished".
    static func isContentLoaded(_ card: SubAgentCard, in items: [V2TimelineItem]) -> Bool {
        items.contains { $0.id == card.id }
    }

    /// The capsule's failure rule (pp 2026-10-03, option A): the capsule reds
    /// for the newest batch's failures only — dispatching a new SubAgent clears
    /// older ones. A failure counts while no top-level card was dispatched
    /// after it ended; a failure whose end time cannot be read always counts
    /// (missing timing must not swallow the signal).
    private static func hasLiveFailure(in cards: [SubAgentCard]) -> Bool {
        let latestDispatch = cards.compactMap(\.dispatchedAt).max()
        return cards.contains { card in
            guard card.phase.isFailure else { return false }
            guard let failedAt = card.failedAt, let latestDispatch else { return true }
            return latestDispatch <= failedAt
        }
    }

    /// An ISO-8601 wire timestamp; the server writes it with and without
    /// fractional seconds.
    static func date(_ text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    /// A terminal card's end: the overlay's epoch-ms `endTime`, else the
    /// item's completion (or last update) time.
    private static func terminalDate(raw: JSONValue, item: V2TimelineItem) -> Date? {
        if let millis = raw["endTime"]?.intValue {
            return Date(timeIntervalSince1970: Double(millis) / 1000)
        }
        return date(item.completedAt) ?? date(item.updatedAt)
    }

    /// The panel's metrics, beside the status badge: "12 个工具 · 8.1s · 31.2k".
    /// Bare values only — the phase word is the badge's job and the unit words
    /// are the spoken label's. Empty when every counter is missing or zero;
    /// the values freeze when the card closes because the task events stop
    /// writing.
    static func statsLine(for card: SubAgentCard) -> String {
        metrics(for: card).joined(separator: " · ")
    }

    /// The same row as one spoken sentence: "已完成，12 个工具，用时 8.1s，31.2k
    /// tokens". VoiceOver needs the words "用时"/"tokens" — a bare "8.1s" is
    /// read as a stray letter — and it needs the phase word, which the badge
    /// already carries visually.
    static func statsAccessibilityLabel(for card: SubAgentCard) -> String {
        let spoken = metrics(for: card,
            duration: { String(localized: "用时 \(SubAgentUsageFormat.duration(milliseconds: $0))") },
            tokens: { String(localized: "\(SubAgentUsageFormat.tokens($0)) tokens") })
        return ([card.phase.word] + spoken).joined(separator: "，")
    }

    /// The counters in display order, dropping the missing and the zero ones
    /// (缺失不显、不留 "0"). Only the unit wording changes between the visible
    /// line and the spoken label, so the drop rule stays in one place.
    private static func metrics(for card: SubAgentCard,
                                duration: (Int) -> String = { SubAgentUsageFormat.duration(milliseconds: $0) },
                                tokens: (Int) -> String = { SubAgentUsageFormat.tokens($0) }) -> [String] {
        var parts: [String] = []
        if let toolCalls = card.toolCalls, toolCalls > 0 {
            parts.append(String(localized: "\(toolCalls) 个工具"))
        }
        if let durationMs = card.durationMs, durationMs > 0 {
            parts.append(duration(durationMs))
        }
        if let tokenCount = card.tokens, tokenCount > 0 {
            parts.append(tokens(tokenCount))
        }
        return parts
    }

    /// The `agents` entry that belongs to the card. The map is normally keyed
    /// by one task id; a receipt's `content.agentId` names it outright, and the
    /// remaining fallbacks stay deterministic for multi-entry maps.
    private static func primaryAgentEntry(raw: JSONValue, agents: [String: JSONValue]) -> [String: JSONValue]? {
        if let agentID = raw["agentId"]?.stringValue, let entry = agents[agentID]?.objectValue { return entry }
        if agents.count == 1 { return agents.values.first?.objectValue }
        let keys = agents.keys.sorted()
        for key in keys where agents[key]?.objectValue?["status"]?.stringValue != asyncLaunchedStatus {
            return agents[key]?.objectValue
        }
        return keys.first.flatMap { agents[$0]?.objectValue }
    }
}

// MARK: - Capsule state

struct SubAgentCapsuleState: Equatable {
    let runningCount: Int
    let hasFailure: Bool
    let singleTaskName: String?
    /// The newest running card. With per-turn pages (pp 2026-10-05) the
    /// capsule opens the turn where the newest work lives, so a fresh
    /// dispatch shows its own page instead of the oldest running one's.
    let latestRunningID: String?
    /// The newest active card's phase word, so a subagent that is still
    /// starting is announced as 启动中 rather than 运行中.
    let phaseWord: String

    var isVisible: Bool { runningCount > 0 }

    /// "任务名" for one running SubAgent, "N 个 SubAgent" for several.
    var title: String {
        if runningCount == 1, let singleTaskName, !singleTaskName.isEmpty { return singleTaskName }
        return String(localized: "\(runningCount) 个 SubAgent")
    }

    var accessibilityText: String {
        "\(title)，\(hasFailure ? String(localized: "失败") : phaseWord)"
    }
}

// MARK: - Number formats

enum SubAgentUsageFormat {
    /// Tokens: `<1000` verbatim, `≥1000` "31.2k", `≥1M` "1.2M" (§3.3).
    static func tokens(_ value: Int) -> String {
        guard value >= 1_000 else { return String(value) }
        if value < 1_000_000 {
            let text = trimmed(Double(value) / 1_000)
            // 999_999 rounds to "1000k"; the design's next unit is "1M".
            return text == "1000" ? "1M" : text + "k"
        }
        return trimmed(Double(value) / 1_000_000) + "M"
    }

    /// Elapsed time: "4.9s" below a minute, "1.5m" above.
    static func duration(milliseconds: Int) -> String {
        if milliseconds < 60_000 { return trimmed(Double(milliseconds) / 1_000) + "s" }
        return trimmed(Double(milliseconds) / 60_000) + "m"
    }

    private static func trimmed(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        if rounded == rounded.rounded() { return String(Int(rounded)) }
        return String(format: "%.1f", rounded)
    }
}

// MARK: - Local JSON accessors

extension JSONValue {
    nonisolated var intValue: Int? {
        guard case let .number(value) = self, value.rounded() == value else { return nil }
        return Int(exactly: value)
    }
}

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
    case completed
    case failed
    case interrupted
    case unknown(String?)

    static func from(itemStatus: V2TimelineItemStatus, rawStatus: String?) -> SubAgentPhase {
        switch itemStatus {
        case .pending, .running, .waitingApproval: return .running
        case .done: return .completed
        case .failed: return .failed
        case .interrupted, .cancelled: return .interrupted
        case .hidden, .unknown: return .unknown(rawStatus)
        }
    }

    var isActive: Bool { self == .running }
    var isFailure: Bool { self == .failed || self == .interrupted }

    /// The panel's status word. Unknown statuses show the wire text as-is.
    var word: String {
        switch self {
        case .running: return String(localized: "运行中")
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
            phase: .from(itemStatus: item.status,
                         rawStatus: TimelineText.first(item.raw["status"], entry?["status"])),
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

    /// The card's child rows, in timeline order (tool, thinking and text rows
    /// the connector attributed with `content.parentItemId`).
    static func children(of cardID: String, in items: [V2TimelineItem]) -> [V2TimelineItem] {
        items.filter { parentItemID($0) == cardID }
    }

    /// Opening rule (§3.2/§3.3): an explicitly requested card wins; otherwise
    /// the first running tab, else the first card.
    static func defaultSelection(_ cards: [SubAgentCard], requested: String?) -> String? {
        if let requested, cards.contains(where: { $0.id == requested }) { return requested }
        return cards.first(where: { $0.phase.isActive })?.id ?? cards.first?.id
    }

    /// The capsule: visible exactly while a top-level SubAgent runs; a failure
    /// of the newest batch tints the whole capsule red (§3.2, rule below).
    static func capsuleState(_ items: [V2TimelineItem]) -> SubAgentCapsuleState {
        let cards = topLevelCards(in: items)
        let running = cards.filter { $0.phase.isActive }
        return SubAgentCapsuleState(
            runningCount: running.count,
            hasFailure: hasLiveFailure(in: cards),
            singleTaskName: running.count == 1 ? running[0].taskName : nil,
            firstRunningID: running.first?.id
        )
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

    /// The stats line under the panel header: "运行中 · N 个工具 · 用时 X · Y tokens".
    /// Zero/missing counters stay out (缺失不显、不留 "0"); the values freeze when
    /// the card closes because the task events stop writing.
    static func statsLine(for card: SubAgentCard) -> String {
        var parts = [card.phase.word]
        if let toolCalls = card.toolCalls, toolCalls > 0 {
            parts.append(String(localized: "\(toolCalls) 个工具"))
        }
        if let durationMs = card.durationMs, durationMs > 0 {
            parts.append(String(localized: "用时 \(SubAgentUsageFormat.duration(milliseconds: durationMs))"))
        }
        if let tokens = card.tokens, tokens > 0 {
            parts.append(String(localized: "\(SubAgentUsageFormat.tokens(tokens)) tokens"))
        }
        return parts.joined(separator: " · ")
    }

    /// The `agents` entry that belongs to the card. The map is normally keyed
    /// by one task id; a receipt's `content.agentId` names it outright, and the
    /// remaining fallbacks stay deterministic for multi-entry maps.
    private static func primaryAgentEntry(raw: JSONValue, agents: [String: JSONValue]) -> [String: JSONValue]? {
        if let agentID = raw["agentId"]?.stringValue, let entry = agents[agentID]?.objectValue { return entry }
        if agents.count == 1 { return agents.values.first?.objectValue }
        let keys = agents.keys.sorted()
        for key in keys where agents[key]?.objectValue?["status"]?.stringValue != "async_launched" {
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
    let firstRunningID: String?

    var isVisible: Bool { runningCount > 0 }

    /// "任务名" for one running SubAgent, "N 个 SubAgent" for several.
    var title: String {
        if runningCount == 1, let singleTaskName, !singleTaskName.isEmpty { return singleTaskName }
        return String(localized: "\(runningCount) 个 SubAgent")
    }

    var accessibilityText: String {
        "\(title)，\(hasFailure ? String(localized: "失败") : String(localized: "运行中"))"
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
    nonisolated var objectValue: [String: JSONValue]? {
        if case let .object(value) = self { return value }
        return nil
    }

    nonisolated var intValue: Int? {
        guard case let .number(value) = self, value.rounded() == value else { return nil }
        return Int(exactly: value)
    }

    nonisolated var boolValue: Bool? {
        if case let .bool(value) = self { return value }
        return nil
    }
}

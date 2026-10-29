import Foundation

// The chat profile's step model.
//
// A step group is one run of consecutive reasoning/tool rows between body text
// (or a turn boundary): the shape the official Chat page renders as a single
// `CollapsedStepsRow` — while it runs the row shows the group's last item, and
// when it settles the row shows a summary; the ordered steps live in the
// detail sheet (`EVIDENCE/round29/chat-thinking-tool-dots-1.261023.20.md` §2,
// addendum §J). The Code profile keeps its own merged model in
// `CodeMessageTimeline`; nothing here is used on that path.
//
// Deliberately nonisolated and free of SwiftUI: the gate and the unit tests
// build these values without the timeline model.

nonisolated enum TimelineStep: Identifiable, Hashable {
    case thinking(id: String, text: String, status: V2TimelineItemStatus)
    case tool(call: CodeToolCall)

    var id: String {
        switch self {
        case let .thinking(id, _, _): return id
        case let .tool(call): return call.id
        }
    }

    var status: V2TimelineItemStatus {
        switch self {
        case let .thinking(_, _, status): return status
        case let .tool(call): return call.item.status
        }
    }

    /// The client-wide `isActive` predicate, spelled out here because this
    /// enum is `nonisolated` and the shared extension is MainActor-isolated
    /// under the package's default isolation. `.unknown` proves nothing and
    /// must not keep a row in the running pose forever.
    var isRunning: Bool {
        switch status {
        case .pending, .running, .waitingApproval: return true
        case .done, .failed, .cancelled, .interrupted, .hidden, .unknown: return false
        }
    }

    var thinkingText: String? {
        guard case let .thinking(_, text, _) = self else { return nil }
        return text
    }

    var toolCall: CodeToolCall? {
        guard case let .tool(call) = self else { return nil }
        return call
    }

    /// The one line the live row shows for a thinking step: the last non-empty
    /// line of the thinking text. AA substitutes the thinking body for the
    /// official summary, which the wire does not carry (pp 2026-10-29); an
    /// empty text yields nil and the view falls back to its running label.
    var liveThinkingLine: String? {
        guard let thinkingText, !thinkingText.isEmpty else { return nil }
        // Scan back from the tail one line at a time: the signature asks for
        // this on every streaming refresh, so it must not split/allocate the
        // whole (possibly long) text.
        var end = thinkingText.endIndex
        while true {
            let newline = thinkingText[..<end].lastIndex(of: "\n")
            let start = newline.map { thinkingText.index(after: $0) } ?? thinkingText.startIndex
            let line = String(thinkingText[start..<end])
                .trimmingCharacters(in: .whitespaces)
            if !line.isEmpty { return line }
            guard let newline else { return nil }
            end = newline
        }
    }
}

nonisolated struct TimelineStepGroup: Identifiable, Hashable {
    let id: String
    let steps: [TimelineStep]

    var isRunning: Bool { steps.contains { $0.isRunning } }

    var hasFailure: Bool {
        steps.contains {
            if case .failed = $0.status { return true }
            return false
        }
    }

    /// The step the live row shows: the trailing-most running step, else the
    /// last one (the official running branch reads `items.last`).
    var liveStep: TimelineStep? {
        steps.last(where: { $0.isRunning }) ?? steps.last
    }

    var toolCalls: [CodeToolCall] { steps.compactMap(\.toolCall) }

    var thinkingCount: Int {
        steps.reduce(0) { $0 + ($1.thinkingText == nil ? 0 : 1) }
    }
}

/// The settled row's counts: 「思考 N 次 · 读取 X 个文件 · 运行 Y 个命令 ·
/// 编辑 Z 个文件」 (pp 2026-10-29). File categories count distinct targets,
/// the same rule `CodeToolLabelPlan` uses for its summary phrases.
nonisolated struct TimelineStepSummary: Equatable {
    var thinkingCount = 0
    var readFiles = 0
    var ranCommands = 0
    var editedFiles = 0
    var toolCount = 0

    var isEmpty: Bool {
        thinkingCount == 0 && readFiles == 0 && ranCommands == 0
            && editedFiles == 0 && toolCount == 0
    }
}

nonisolated enum TimelineStepSummarizer {
    static func summary(steps: [TimelineStep], cwd: String?) -> TimelineStepSummary {
        var summary = TimelineStepSummary()
        var read: Set<String> = []
        var ran: Set<String> = []
        var edited: Set<String> = []
        for step in steps {
            if step.thinkingText != nil {
                summary.thinkingCount += 1
                continue
            }
            guard let call = step.toolCall else { continue }
            summary.toolCount += 1
            guard let plan = CodeToolLabelPlan.make(calls: [call], cwd: cwd),
                  let verb = plan.verb else { continue }
            let target = plan.target ?? call.id
            switch verb {
            case .read: read.insert(target)
            case .ran: ran.insert(target)
            case .edited, .created, .updated: edited.insert(target)
            default: break
            }
        }
        summary.readFiles = read.count
        summary.ranCommands = ran.count
        summary.editedFiles = edited.count
        return summary
    }
}

/// The settled row's one-line text: 「思考 N 次 · 读取 X 个文件 · 运行 Y 个命令 ·
/// 编辑 Z 个文件」. Kept next to the counts so the row, the detail title and
/// the gate cannot drift.
nonisolated enum TimelineStepSummaryText {
    static func line(_ summary: TimelineStepSummary,
                     locale: Locale = .autoupdatingCurrent) -> String {
        var parts: [String] = []
        if summary.thinkingCount > 0 {
            parts.append(String(localized: "思考 \(summary.thinkingCount) 次", locale: locale))
        }
        if summary.readFiles > 0 {
            parts.append(String(localized: "读取 \(summary.readFiles) 个文件", locale: locale))
        }
        if summary.ranCommands > 0 {
            parts.append(String(localized: "运行 \(summary.ranCommands) 个命令", locale: locale))
        }
        if summary.editedFiles > 0 {
            parts.append(String(localized: "编辑 \(summary.editedFiles) 个文件", locale: locale))
        }
        if parts.isEmpty, summary.toolCount > 0 {
            parts.append(String(localized: "工具调用 \(summary.toolCount) 次", locale: locale))
        }
        if parts.isEmpty {
            parts.append(String(localized: "thought_process", locale: locale))
        }
        return parts.joined(separator: " · ")
    }
}

/// One ordered element the chat profile's timeline renders as a top-level row.
nonisolated enum TimelineChatUnit: Identifiable {
    case stepGroup(TimelineStepGroup, rowIDs: [String])
    case message(key: String, rowIDs: [String])
    case standalone(rowID: String)

    var id: String {
        switch self {
        case let .stepGroup(group, _): return group.id
        case let .message(key, _): return key
        case let .standalone(rowID): return rowID
        }
    }
}

/// Splits the wire rows into the chat profile's ordered units.
///
/// Rules (the chat profile is chronological by design; it never merges across
/// messages the way the Code planner does):
/// - consecutive reasoning/tool rows form one step group, broken by body text,
///   a user message, a declared turn change, or any other row;
/// - consecutive body rows sharing a message key form one message group
///   (the key is the Code planner's `groupKey`, so live and history agree);
/// - an interaction target keeps its own standalone row;
/// - sub-agent child rows stay out of the main timeline (L2.1).
nonisolated enum TimelineChatGrouping {
    static func units(items: [V2TimelineItem],
                      profile: CodeRuntimeProfile,
                      interactionTargets: Set<String>) -> [TimelineChatUnit] {
        var units: [TimelineChatUnit] = []
        var stepItems: [V2TimelineItem] = []
        var messageKey: String?
        var messageRows: [V2TimelineItem] = []
        var consumed: Set<String> = []
        var currentTurnID: V2TurnID?

        func flushSteps() {
            guard !stepItems.isEmpty else { return }
            let steps = stepItems.map { step(for: $0, profile: profile) }
            let firstID = stepItems.first.map(spanID) ?? steps.first?.id ?? "steps"
            units.append(.stepGroup(TimelineStepGroup(id: "steps:\(firstID)", steps: steps),
                                    rowIDs: stepItems.map(\.id)))
            stepItems.removeAll()
        }

        func flushMessage() {
            guard let key = messageKey, !messageRows.isEmpty else {
                messageKey = nil
                messageRows.removeAll()
                return
            }
            units.append(.message(key: key, rowIDs: messageRows.map(\.id)))
            messageKey = nil
            messageRows.removeAll()
        }

        func flushAll() {
            flushSteps()
            flushMessage()
        }

        for item in items.sorted(by: wireOrder) {
            guard consumed.insert(item.id).inserted else { continue }
            if isSubAgentChild(item) { continue }
            if interactionTargets.contains(item.id) {
                flushAll()
                units.append(.standalone(rowID: item.id))
                continue
            }
            if let declared = item.turnId {
                if let currentTurnID, currentTurnID != declared { flushAll() }
                currentTurnID = declared
            }

            if isReasoning(item) || isToolRow(item) {
                flushMessage()
                stepItems.append(item)
                continue
            }

            if item.type == .message {
                flushSteps()
                if item.role == .user { flushMessage() }
                let key = CodeMessageBuilder.groupKey(for: item) ?? item.id
                if key != messageKey {
                    flushMessage()
                    messageKey = key
                }
                messageRows.append(item)
                continue
            }

            flushAll()
            units.append(.standalone(rowID: item.id))
        }

        flushAll()
        return units
    }

    private static func step(for item: V2TimelineItem,
                             profile: CodeRuntimeProfile) -> TimelineStep {
        if isReasoning(item) {
            return .thinking(id: item.id, text: item.displayText, status: item.status)
        }
        let call = CodeToolCall(
            item: item,
            kind: profile.kind(for: CodeToolCall.wireName(for: item),
                               wireKind: CodeToolCall.wireKind(for: item)))
        return .tool(call: call)
    }

    /// The group's stable address: the first step's declared item id when the
    /// connector provides one, else its row id (the Code planner's span rule).
    private static func spanID(for item: V2TimelineItem) -> String {
        TimelineText.first(item.source["itemId"]) ?? item.id
    }

    private static func isReasoning(_ item: V2TimelineItem) -> Bool {
        item.type == .reasoning
            || (item.type == .system && item.raw["content"]?["kind"] == .string("reasoning"))
    }

    private static func isToolRow(_ item: V2TimelineItem) -> Bool {
        item.type == .tool || item.type == .fileChange
            || item.raw["content"]?["kind"] == .string("file_change")
    }

    private static func isSubAgentChild(_ item: V2TimelineItem) -> Bool {
        TimelineText.first(item.raw["content"]?["parentItemId"]) != nil
    }

    private static func wireOrder(_ lhs: V2TimelineItem, _ rhs: V2TimelineItem) -> Bool {
        lhs.orderSeq == rhs.orderSeq ? lhs.id < rhs.id : lhs.orderSeq < rhs.orderSeq
    }
}

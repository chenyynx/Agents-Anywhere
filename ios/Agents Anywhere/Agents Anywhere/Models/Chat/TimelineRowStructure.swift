import Foundation

/// The list observes this small projection, not each row's changing token text
/// or tool output. A streaming append updates its row without regrouping history.
struct TimelineRowStructure: Equatable {
    let type: V2TimelineItemType
    let role: V2MessageRole?
    let status: V2TimelineItemStatus
    let startsTurn: Bool
    let isFileChange: Bool
    let isReasoning: Bool
    let isStreamingText: Bool
    let groupKind: ChatTimelineGroup.Kind
    let reconnectAttempt: String?

    init(_ item: V2TimelineItem) {
        type = item.type; role = item.role; status = item.status
        startsTurn = item.startsVisibleTurn; isFileChange = item.isFileChange
        isReasoning = item.isReasoning; isStreamingText = item.isStreamingText
        // L2: every row the connector attributed to an Agent card — tool,
        // thinking and text rows alike — folds under that card's SubAgent group
        // instead of flowing into the main-agent tool run (the grouping used to
        // require kind == "agent_call", which only caught nested Agent calls).
        if let parent = SubAgentProgress.parentItemID(item) { groupKind = .agents(parent) }
        else if TimelineGrouping.reconnectMessage(item) != nil { groupKind = .reconnect }
        else if item.isReasoning || [.tool, .fileChange, .artifact].contains(item.type) { groupKind = .tools }
        else { groupKind = .single }
        reconnectAttempt = TimelineGrouping.reconnectMessage(item).flatMap { message in
            message.range(of: "\\d+\\s*/\\s*\\d+", options: .regularExpression).map { String(message[$0]) }
        }
    }
}

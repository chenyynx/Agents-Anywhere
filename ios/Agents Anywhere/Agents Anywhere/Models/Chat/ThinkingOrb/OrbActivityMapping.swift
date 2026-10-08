import Foundation

/// The orb's raw activity signals for one chat page (§6.1). Pure data; the
/// priority between them lives in `OrbActivityResolver`.
struct OrbActivitySignals {
    /// The projected runtime status, only while live facts are fresh.
    var status: V2RuntimeStatus?
    /// A visible interaction notice the user can answer right now.
    var hasRespondableNotice: Bool
    /// Running top-level SubAgents — the capsule's own count.
    var runningSubagentCount: Int
    var hasActiveToolItem: Bool
    var hasActiveCompactItem: Bool
    var isStreamingAssistantText: Bool
    var hasActiveReasoningItem: Bool
}

/// The orb's one priority table: top to bottom, the first hit wins.
///
/// Everything the signals cannot prove (a queued turn, a submit window, the
/// stopping / blocked / error / unknown states) falls through to the final
/// scan — the requirement's allowed fallback, not a gap.
enum OrbActivityResolver {
    static func resolve(_ s: OrbActivitySignals) -> OrbActivity {
        if s.hasRespondableNotice || s.status == .waitingApproval { return .waitingForUser }
        if s.runningSubagentCount > 0 { return .parallelWork }
        if s.hasActiveToolItem { return .toolRunning }
        if s.hasActiveCompactItem { return .summarizing }
        if s.isStreamingAssistantText { return .writing }
        if s.hasActiveReasoningItem { return .thinking }
        return .toolRunning
    }
}

extension SessionChatModel {
    /// Collects the orb's signals from this page's live sources (§6.1). The
    /// row read mirrors `SubAgentCapsuleSlot` — presented rows plus the
    /// projection's active-card sidecar — so the orb and the capsule can never
    /// disagree about what is running. Every item predicate reuses the
    /// presentation's own definitions; nothing is re-derived here.
    var orbActivitySignals: OrbActivitySignals {
        let fresh = session.runtime.isFresh
        let items = timeline.rows.map(\.value)
        return OrbActivitySignals(
            status: fresh ? session.runtime.state?.status : nil,
            hasRespondableNotice: session.notices.visibleNotices.contains { $0.canRespond(fresh: fresh) },
            runningSubagentCount: SubAgentProgress.capsuleState(
                inWindow: items, activeCards: session.activeAgentCards).runningCount,
            hasActiveToolItem: items.contains { TimelineEntryPresentation.isToolKindItem($0) && $0.status.isActive },
            hasActiveCompactItem: items.contains {
                TimelineEntryPresentation.isCompactItem($0) && TimelineEntryPresentation.isActiveCompactItem($0)
            },
            isStreamingAssistantText: items.contains {
                ($0.status == .pending || $0.status == .running) && $0.type == .message && $0.role == .assistant
            },
            hasActiveReasoningItem: items.contains { $0.isReasoning && $0.status.isActive })
    }

    var orbActivity: OrbActivity { OrbActivityResolver.resolve(orbActivitySignals) }
}

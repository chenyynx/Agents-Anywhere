import Foundation

/// The official turn-status phases (`ClaudeChat.TurnStatus.Phase`): idle=0,
/// thinking=1, writing=2, usingTool=3. AA derives them from the same live
/// signals the orb uses, so the streaming haptics and the status view agree.
nonisolated enum ChatTurnPhase: Int, Equatable, CaseIterable {
    case idle = 0
    case thinking = 1
    case writing = 2
    case usingTool = 3

    /// Priority mirrors the orb's tool-first table: a running tool outranks
    /// streaming text, which outranks reasoning; nothing running is idle.
    static func resolve(toolActive: Bool,
                        writing: Bool,
                        reasoning: Bool) -> ChatTurnPhase {
        if toolActive { return .usingTool }
        if writing { return .writing }
        if reasoning { return .thinking }
        return .idle
    }
}

/// The official `TurnStatusView` haptic decision (haptics inventory §1.2):
///
/// - `writing -> idle` plays `.impact(weight: .light, intensity: 1.0)` — the
///   only end-of-stream haptic; success and failure share it.
/// - Every other phase change plays `.selection`, except entering `thinking`
///   behind a caption predicate whose exact semantics are still UNKNOWN; AA
///   does not have that caption, so it keeps the selection.
/// - Streamed tokens never play a haptic.
nonisolated enum TurnPhaseHaptics {
    enum Feedback: Equatable {
        case impactLight
        case selection
        case none
    }

    static func feedback(from old: ChatTurnPhase,
                         to new: ChatTurnPhase) -> Feedback {
        guard old != new else { return .none }
        if old == .writing, new == .idle { return .impactLight }
        return .selection
    }
}

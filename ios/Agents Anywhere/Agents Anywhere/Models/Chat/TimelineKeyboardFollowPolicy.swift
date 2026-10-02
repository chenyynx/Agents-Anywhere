import Foundation

/// K5 coordination gate (2026-10-02): decides what the timeline does around a
/// system keyboard transition. Pure so ClientCore tests pin every branch; the
/// view only executes the outcome. The keyboard animation and any programmatic
/// scroll must never run as two independent animations (F11).
nonisolated struct TimelineKeyboardFollowPolicy {
    enum Event: Equatable {
        case willShow
        case willHide
        /// The transition window closed (its duration elapsed).
        case transitionEnded
    }

    enum Action: Equatable {
        case none
        /// Return to the bottom once, matched to the keyboard's own duration
        /// and curve so the page travels with the keyboard.
        case requestReturn(ReturnStyle)
        /// The system clamp already carries the content down when the keyboard
        /// hides; a programmatic scroll would fight it.
        case suppressProgrammatic
        /// The bottom is still unreached and a return is owed: release it for
        /// exactly one make-up landing.
        case recheckAtEnd
    }

    enum ReturnStyle: Equatable {
        case keyboardMatched
    }

    struct Context: Equatable {
        var event: Event
        var isAtBottom: Bool
        var mode: TimelineScrollState.Mode
        var phase: TimelineScrollState.Phase
        var navigationIsSuspended: Bool
        /// An ungated return is still outstanding in the scroll state.
        var hasPendingRequest: Bool
    }

    static func action(for context: Context) -> Action {
        // The drawer owns navigation; an interrupted callback is not a fresh
        // vertical intent. A drag (any non-idle phase, the K4 path) owns the
        // keyboard's interactive dismissal itself.
        guard !context.navigationIsSuspended, context.phase == .idle else { return .none }
        // Reading — including a presented interaction card — owns the
        // position, and an in-flight return needs no second opinion: only a
        // steady following timeline follows the keyboard.
        guard context.mode == .following else { return .none }
        switch context.event {
        case .willShow:
            // The keyboard covers the bottom and there is no native follow on
            // appearance; this gate is the only thing that fills it, so fill
            // it in the keyboard's own turn and with its own curve.
            return context.isAtBottom ? .requestReturn(.keyboardMatched) : .none
        case .willHide:
            // The system clamp animates the content down with the keyboard.
            // Returning to the bottom is the reader's own clamp's job.
            return context.isAtBottom ? .suppressProgrammatic : .none
        case .transitionEnded:
            // The window closed with the bottom still unreached and a return
            // owed: release it for one make-up landing.
            return !context.isAtBottom && context.hasPendingRequest ? .recheckAtEnd : .none
        }
    }
}

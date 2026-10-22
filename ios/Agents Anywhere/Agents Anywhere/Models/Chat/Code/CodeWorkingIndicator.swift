import Foundation

// One turn, one working indicator.
//
// The official Code page draws its `••• Verb…` row inside the message stack
// (`CodeThinkingView`). AA also has a tail row; while a message row owns the
// status line, the tail must not draw a second one (device report 2026-10-23:
// the orange status and the legacy blue orb were both visible). This tiny
// predicate lives in the model target so it can be tested without UIKit.

nonisolated enum CodeWorkingIndicator {
    /// True when the tail is the only place a working status can appear.
    ///
    /// - `hasPlaceholder`: the session has a live "waiting / working" line.
    /// - `hasActiveReasoningStatus`: a message row already renders the
    ///   official status line for an active reasoning block.
    static func showsTailStatusLine(hasPlaceholder: Bool,
                                    hasActiveReasoningStatus: Bool) -> Bool {
        hasPlaceholder && !hasActiveReasoningStatus
    }
}

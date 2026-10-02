import Foundation

/// Single point for the composer's trigger-style keyboard gesture numbers
/// (K2, 2026-10-02 spec; round 1.1 judges the claim on release). A drag claims
/// once it is judged, after 10pt of net vertical dominance; while the keyboard
/// is visible a downward release of ≥400pt/s or ≥60pt resigns; while it is
/// hidden an upward release of ≥300pt/s or ≥24pt focuses. Real-device feel is
/// tuned here, never at the call sites.
nonisolated enum ComposerKeyboardGestureThresholds {
    static let claimDistance: CGFloat = 10
    static let claimDirectionRatio: CGFloat = 1
    static let dismissVelocity: CGFloat = 400
    static let dismissDisplacement: CGFloat = 60
    static let presentVelocity: CGFloat = 300
    static let presentDisplacement: CGFloat = 24
}

/// Decides what a finished drag on the composer bar means. The view layer
/// hands over UIKit samples and executes the returned action; direction
/// dominance, thresholds and state arbitration all live here so ClientCore
/// tests can pin them without a simulator.
nonisolated struct ComposerKeyboardGesturePolicy {
    enum Action: Equatable {
        case none
        case focus
        case resign
    }

    /// How the recognizer finished. A cancelled gesture was taken over by the
    /// system (a selection drag, an interrupting animation, …) and is not a
    /// decision the user made, so it is never judged.
    enum Outcome: Equatable {
        case ended
        case cancelled
    }

    struct Context: Equatable {
        /// Net horizontal translation over the whole drag at release in
        /// points; positive is right.
        var translationX: CGFloat
        /// Net vertical translation at release in points; positive is down.
        var translationY: CGFloat
        /// Vertical velocity at release in points per second; positive is down.
        var velocityY: CGFloat
        /// The editor's focus flag, the authoritative keyboard state here.
        var keyboardIsVisible: Bool
        /// IME marked-text state, carried for completeness: the spec allows
        /// closing the keyboard while composing, so it never vetoes an action.
        var isComposing: Bool
        /// A long-press selection drag owns the touch while it is running.
        var isSelecting: Bool
        var outcome: Outcome
    }

    /// Claim gate for a released drag, judged once over the whole net travel:
    /// the drag must be vertically dominant at 1:1 and have travelled the
    /// claim distance. The begin never samples it — a one-shot sample could
    /// kill a real swipe whose first frames were sideways — so the release
    /// decision below is the single judge of direction and distance.
    static func claims(dx: CGFloat, dy: CGFloat) -> Bool {
        abs(dy) > ComposerKeyboardGestureThresholds.claimDirectionRatio * abs(dx)
            && abs(dy) >= ComposerKeyboardGestureThresholds.claimDistance
    }

    /// The one-shot, trigger-style decision. Each rule is directional by the
    /// sign of its own sample, so an upward release never dismisses and a
    /// downward release never focuses.
    static func action(for context: Context) -> Action {
        guard context.outcome == .ended else { return .none }
        if context.isSelecting { return .none }
        // The claim is judged once on release, over the whole drag: the begin no
        // longer samples it (a one-shot sample could kill a real swipe whose first
        // frames were sideways). A short or horizontally-dominant travel is never
        // a keyboard intent, whatever its vertical component says.
        guard claims(dx: context.translationX, dy: context.translationY) else { return .none }
        if context.keyboardIsVisible {
            let flick = context.velocityY >= ComposerKeyboardGestureThresholds.dismissVelocity
            let drag = context.translationY >= ComposerKeyboardGestureThresholds.dismissDisplacement
            return flick || drag ? .resign : .none
        }
        let flick = context.velocityY <= -ComposerKeyboardGestureThresholds.presentVelocity
        let drag = context.translationY <= -ComposerKeyboardGestureThresholds.presentDisplacement
        return flick || drag ? .focus : .none
    }
}

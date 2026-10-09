import Foundation

/// Decides whether a keyboard-driven geometry sample must be corrected by an
/// explicit pin to the bottom.
///
/// While the keyboard animates, the page mutes every one of its own follow
/// paths (the publication gate, the bottom reconcile) and the newest row rests
/// on the scroll view's default anchor alone. That anchor is a default, not a
/// guarantee — a manual scroll detaches it — and a detached anchor leaves the
/// newest row under the keyboard with nothing left to pull it back until the
/// next content change. Mature clients never delegate this: a reader who is at
/// the bottom keeps it, by pinning on every delivered sample for as long as
/// the keyboard moves.
///
/// The guards are the bottom reconcile's own, minus the parts that make that
/// path fragile — its once-per-episode latch, its in-flight command and its
/// pending-request dedup. A pin is idempotent and re-derived from the freshest
/// sample every frame, so it needs no latch and no command, and a request
/// already travelling must not refuse it.
nonisolated enum TimelineKeyboardBottomPin {
    static func shouldPin(isFollowing: Bool, isScrolling: Bool, navigationSuspended: Bool,
                          isMeasured: Bool, atBottom: Bool) -> Bool {
        guard isMeasured, !navigationSuspended, !isScrolling, isFollowing else { return false }
        return !atBottom
    }
}

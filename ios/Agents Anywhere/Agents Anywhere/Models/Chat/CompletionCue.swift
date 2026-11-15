import Foundation

/// Whether the shared finish cue may play for an authoritative turn end.
///
/// A stop tap suppresses the cue even when the authoritative idle wins the
/// race against the interrupt ack: the tap flag (`stopRequested`) is set
/// synchronously, the ack's `predictedIdle` may arrive later, and
/// `lastTurnEndWasStop` is only set from that ack. Without the two stop flags
/// the cue played its double pulse at the queued send after an interrupt
/// (device 2026-11-14).
nonisolated enum CompletionCue {
    static func allows(isOpeningReady: Bool, isFresh: Bool, isIdle: Bool,
                       lastTurnEndWasStop: Bool,
                       stopRequested: Bool, predictedIdle: Bool) -> Bool {
        isOpeningReady && isFresh && isIdle
            && !lastTurnEndWasStop && !stopRequested && !predictedIdle
    }
}

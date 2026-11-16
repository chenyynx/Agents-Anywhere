import Foundation

/// Visibility rules for the two rows a send adds: the pending bubble and the
/// standalone working row.
///
/// They must enter the list in the same apply. The working row used to be
/// driven by `session.pendingMessages` while the bubble came from the
/// presentation's own tick; the row landed first, started a +38 follow, and
/// the 53 pt bubble joined mid-flight (pp 2026-11-16, probe
/// `timeline.rows.frame`). Waiting for the bubble makes one +91 follow: the
/// page scrolls once and the row arrives already in place.
enum SendFramePresentation {
    /// Whether the standalone working row may join the list.
    ///
    /// - Parameters:
    ///   - pendingIDs: ids of the turn-opening records still on screen, in
    ///     append order. The newest one is the send frame this row belongs to.
    ///   - publishedPendingIDs: ids the presentation has published.
    ///   - echoedPendingIDs: ids whose echo row is already in the timeline
    ///     (the pending row leaves the presentation on that same transition).
    static func showsWorkingRow(
        placeholderVisible: Bool,
        pendingIDs: [String],
        publishedPendingIDs: Set<String>,
        echoedPendingIDs: Set<String>,
        isStepsProfile: Bool,
        hasLiveSteps: Bool,
        queueCount: Int
    ) -> Bool {
        guard placeholderVisible else { return false }
        // In the steps profile the live step group carries the mark; a queued
        // bubble already shows its own in-flight state.
        if isStepsProfile, hasLiveSteps || queueCount > 0 { return false }
        guard let latest = pendingIDs.last else { return true }
        return publishedPendingIDs.contains(latest) || echoedPendingIDs.contains(latest)
    }

    /// Whether the working row draws its status text.
    ///
    /// The three-dot mark alone is the optimistic send. Text is reserved for
    /// "the server holds this message": the acknowledgement turns the bubble's
    /// old spinner into this line (pp 2026-11-16).
    static func showsWorkingRowText(
        latestDelivery: V2PendingMessage.Delivery?,
        runtimeIsInFlight: Bool
    ) -> Bool {
        guard let latestDelivery else { return true }
        switch latestDelivery {
        case .sending: return runtimeIsInFlight
        default: return true
        }
    }
}

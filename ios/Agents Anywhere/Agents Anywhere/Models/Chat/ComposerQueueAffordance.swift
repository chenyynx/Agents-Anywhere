import Foundation

/// Which control the composer's trailing slot shows, and whether it is live.
///
/// The three shapes the input bar can take while a turn is or is not running,
/// resolved as a pure function so the decision is unit-testable without a view
/// tree. The view still owns the pixels; this owns only the branch — the branch
/// that decides whether a running turn's send key stops, enqueues, or sends.
struct ComposerQueueAffordance: Equatable {
    enum Shape: Equatable {
        /// The plain stop key: a running turn with nothing typed. There is
        /// nothing to enqueue, so the whole slot is the stop affordance.
        case stop
        /// The queue form: a running turn with text. The single accent key
        /// shows the arrow and enqueues; clearing the text brings the stop key
        /// back, so one key carries both actions and no second entry exists.
        case queueSend
        /// The plain send key: no turn in flight.
        case send
    }

    let shape: Shape
    /// Whether the accent (arrow / stop) action is enabled. For `.queueSend`
    /// the queue capability decides; for `.stop` the stop capability; for
    /// `.send` the send capability plus draft composability.
    let isActionEnabled: Bool

    /// - `isStreaming`: a turn is in flight as the *composer* sees it
    ///   (`isComposerStreaming`: authoritative, minus the optimistic idle that
    ///   an accepted stop opens early). This is not `isRunning`.
    /// - `hasCommittableContent`: the draft holds something the mid-turn key
    ///   can actually deliver — non-blank text, or an attachment-only draft
    ///   whose steer path accepts files (`session.steer.parameters.attachments`).
    ///   An attachment-only draft on a runtime that cannot steer files keeps
    ///   the stop key: enqueueing it would be a no-op (the queue is text-fed).
    /// - `canQueue`: the session permits a mid-turn commit (capability, freshness).
    /// - `canStop`: the interrupt gate, for the plain stop key's enablement.
    /// - `canSend`: the idle send key's full gate, including draft composability.
    static func resolve(isStreaming: Bool, hasCommittableContent: Bool, canQueue: Bool, canStop: Bool, canSend: Bool) -> ComposerQueueAffordance {
        guard isStreaming else {
            return ComposerQueueAffordance(shape: .send, isActionEnabled: canSend)
        }
        guard hasCommittableContent else {
            return ComposerQueueAffordance(shape: .stop, isActionEnabled: canStop)
        }
        return ComposerQueueAffordance(shape: .queueSend, isActionEnabled: canQueue)
    }
}

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
        /// The split form: a running turn with text. A small outlined stop key
        /// keeps the interrupt reachable while the accent arrow enqueues.
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
    /// - `hasText`: the draft has non-blank text. Only text can become a queued
    ///   message — the queue key is deliberately not offered for an
    ///   attachment-only draft, which keeps the existing stop key instead.
    /// - `canQueue`: the session permits an enqueue (capability, freshness).
    /// - `canStop`: the interrupt gate, for the plain stop key's enablement.
    /// - `canSend`: the idle send key's full gate, including draft composability.
    static func resolve(isStreaming: Bool, hasText: Bool, canQueue: Bool, canStop: Bool, canSend: Bool) -> ComposerQueueAffordance {
        guard isStreaming else {
            return ComposerQueueAffordance(shape: .send, isActionEnabled: canSend)
        }
        guard hasText else {
            return ComposerQueueAffordance(shape: .stop, isActionEnabled: canStop)
        }
        return ComposerQueueAffordance(shape: .queueSend, isActionEnabled: canQueue)
    }
}

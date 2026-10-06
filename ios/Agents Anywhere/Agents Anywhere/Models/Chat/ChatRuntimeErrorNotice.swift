import Foundation

/// A runtime-state error rendered as one chat notice.
///
/// The runtime's `error` field is durable state, not an event: it stays on the
/// session until a later state replaces or clears it, so every observation
/// re-derives the notice from the field. The only question the dedup has to
/// answer is "is this the same incident the user already saw?", and the answer
/// is the payload: a re-disclosure is a new event exactly when its parameters
/// change (pp 2026-10-06 invariants), because a changed payload is the only
/// part a person can tell apart. `Identity` carries that — the code and
/// `params`.
///
/// The state's `updatedSeq` is deliberately NOT part of the identity, even
/// though it looks like a natural event stamp. It advances on state updates
/// that keep the same error (status edges, fresh live reads), and folding it
/// in would revive a dismissed notice for an error that never changed. The
/// projection layer documents the same fact from the other side: a durable
/// sequence may replay A -> B -> A, so it cannot be used as an event identity.
struct ChatRuntimeErrorNotice: Equatable {
    /// The distinguishable part of one incident: the error code plus the
    /// payload whose change marks a new event.
    struct Identity: Hashable {
        let code: String
        let params: JSONValue?
    }

    let title: String
    let message: String
    /// Disclosure copy carries no retry semantics: "请重新发起" is the user's
    /// own next message, not a refresh button (pp 2026-10-06).
    let canRetry: Bool
    let identity: Identity

    /// The notice for `error`, or nil when there is none or its code is not in
    /// the authored-copy table.
    ///
    /// Only table-hit codes are surfaced — the gate is the pure
    /// `runtimeErrorCopyKey` lookup — so a code this build has never reviewed
    /// keeps today's behaviour (no chat notice) instead of guessing copy for
    /// a sentence it has not seen. The message prefers the reviewed copy and
    /// degrades to the error's own description when the catalog cannot serve
    /// it (an untranslated catalog, the unit-test bundle); that description
    /// already falls back to the Connector's sentence and finally a generic
    /// one, so this can never surface the raw catalog key or an empty string.
    static func make(for error: V2RuntimeError?) -> ChatRuntimeErrorNotice? {
        guard let error, let code = error.code,
              RuntimeLocalizedCopy.runtimeErrorCopyKey(for: code) != nil else { return nil }
        return ChatRuntimeErrorNotice(
            title: String(localized: "任务已中断"),
            message: RuntimeLocalizedCopy.runtimeErrorText(code: code, params: error.params)
                ?? error.errorDescription
                ?? String(localized: "The runtime reported an error."),
            canRetry: false,
            identity: Identity(code: code, params: error.params)
        )
    }
}

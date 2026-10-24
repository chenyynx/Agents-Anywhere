import Foundation

// W6: the Code profile's streaming publisher.
//
// The official Code page has no per-character reveal, no mask and no reveal
// timeline: `TextPacing` is hard-coded to `.none` and the shared binding never
// builds a `RevealDriver` (CANONICAL/03-streaming.md §9.1; CANONICAL/10-chat-page.md
// §3). What reaches the screen is a series of full text snapshots:
//
//   - Publishing is a 0.1 s leading-edge throttle with no timer. Inside the
//     window a publish request only sets `publishPending`; the next event that
//     arrives after the window flushes it (CANONICAL/03-streaming.md §5.1).
//   - A publish is the whole current text of the block, not a chunk and not a
//     delta: the assembler keeps the full text per block index and the
//     snapshot carries `text` verbatim (CANONICAL/03-streaming.md §4.2–4.3).
//     The 4–8 words / 50–100 ms append cadence of the 60 fps demo video is a
//     recording observation, not a client policy; it is produced by the
//     network delta grouping the 0.1 s throttle merges
//     (CANONICAL/03-streaming.md §9.2, INFERENCE/UNKNOWN).
//   - Catch-up is free: the first snapshot (no `lastPublishAt`) and the first
//     event after a long pause both publish everything received so far.
//   - The row identity is the fixed `.streamingText` kind and never changes.
//     Completion is exposed only as `isComplete`; the wiring layer replaces the
//     row by deleting it and inserting the persisted message (§8.1–§8.2).
//
// Identity contract (P2-3): one `CodeStreamingPublisher` owns exactly one text
// block. A message with multiple blocks is the caller's concern — each live
// block gets its own publisher so every block publishes on its own 0.1 s
// window.
//
// This type is pure logic with an injected clock. It starts no timer, imports
// no UI module, and is isolated from Chat's `StreamingRevealTimeline`: there is
// no character cursor, no mask, and no reveal here — only text snapshots.

/// One on-screen text snapshot. `text` is the full visible text, not a delta
/// and not a character cursor, so applying a snapshot is idempotent.
nonisolated struct CodeStreamingSnapshot: Equatable, Sendable {
    /// The official fixed identity for the in-flight assistant text row
    /// (`.streamingText`, ID tag 7). It never changes on completion.
    static let streamingRowID = "streamingText"

    let id: String
    let text: String
    let isComplete: Bool
}

nonisolated struct CodeStreamingPublisher: Equatable, Sendable {
    nonisolated struct Config: Equatable, Sendable {
        /// `Duration(attoseconds: 1e17)` = 0.1 s leading-edge throttle
        /// (CANONICAL/03-streaming.md §5.1).
        var publishInterval: TimeInterval = 0.1
    }

    let config: Config

    /// Text currently on screen (the last published snapshot).
    private(set) var publishedText: String = ""
    /// Completion is a data field; it does not change the row identity
    /// (CANONICAL/03-streaming.md §6 and §8).
    private(set) var isComplete: Bool = false
    /// Mirrors the official `publishPending` flag (+0x78): a publish was
    /// requested inside the throttle window and is waiting for the next event.
    private(set) var publishPending: Bool = false

    /// The whole text received for this block, published or not.
    ///
    /// The wire sends the block's cumulative text on every event
    /// (CANONICAL/03-streaming.md §4.2), so this is replaced by reference
    /// instead of being rebuilt from `publishedText + buffer`: the old
    /// computed property copied the whole block on every network frame and
    /// again inside `attemptPublish` (R6 P1-1). A native `String` assignment
    /// is a constant-time copy-on-write reference.
    private(set) var receivedText: String = ""
    /// Monotonic high-water mark of publish instants. Never moves backwards so
    /// a rollback of the injected clock cannot trigger a publish burst.
    private var lastPublishedAt: TimeInterval?

    init(config: Config = Config()) {
        self.config = config
    }

    var hasPendingText: Bool {
        receivedText != publishedText
    }

    /// Append an incremental text delta received at `now`.
    ///
    /// Returns a snapshot when this event opens the throttle; otherwise
    /// returns nil and leaves the whole received text buffered. Nothing is
    /// scheduled: a pending publish is flushed by a later `receive`/`flush`
    /// event, never by a timer (CANONICAL/03-streaming.md §5.1).
    mutating func receive(delta: String, at now: TimeInterval) -> CodeStreamingSnapshot? {
        guard !isComplete else { return nil }

        if !delta.isEmpty { receivedText += delta }

        return attemptPublish(at: now)
    }

    /// Feed a cumulative full text (the official assembler keeps full text per
    /// block, CANONICAL/03-streaming.md §4.2). Anything that is not a prefix
    /// extension replaces the received text; the publish step then sends the
    /// whole snapshot, so an append and a correction take the same path.
    mutating func receive(fullText: String, at now: TimeInterval) -> CodeStreamingSnapshot? {
        guard !isComplete else { return nil }

        // Compare before assigning so an unchanged event does not retain the
        // caller's storage. Both are native strings, so `==` is a byte
        // comparison with no allocation.
        if fullText != receivedText { receivedText = fullText }

        return attemptPublish(at: now)
    }

    /// Event hook that models "the next event after the throttle window".
    ///
    /// Production has no caller: every wire event reaches the publisher
    /// through `receive(fullText:at:)`, including an event whose text did not
    /// change (that call still flushes a pending publish). The Code profile
    /// gate uses this entry point to step the injected clock with no new text,
    /// so the official no-timer rule stays directly testable.
    mutating func flush(at now: TimeInterval) -> CodeStreamingSnapshot? {
        attemptPublish(at: now)
    }

    /// Publishes everything received and marks the row complete.
    ///
    /// Completion is exempt from the 0.1 s throttle: the official completion
    /// channel (`message_stop` / other `message_*` stop payloads) publishes
    /// directly (CANONICAL/03-streaming.md §5.1). `content_block_stop` does not
    /// complete the message and is ignored by the official consumer (§3.4).
    /// After this call further input is ignored — nothing is aggregated again.
    mutating func complete(at now: TimeInterval) -> CodeStreamingSnapshot? {
        guard !isComplete else { return nil }

        isComplete = true
        publishedText = receivedText
        publishPending = false
        recordPublish(at: now)
        return snapshot()
    }

    // MARK: - Publishing

    private mutating func attemptPublish(at now: TimeInterval) -> CodeStreamingSnapshot? {
        // The publish payload is always the block's whole current text
        // (CANONICAL/03-streaming.md §4.2): an append and a correction both
        // send what `receivedText` now holds.
        guard receivedText != publishedText else {
            // A correction can bring the text back to what is already on
            // screen; the queued request has nothing left to publish.
            publishPending = false
            return nil
        }

        guard throttleAllows(at: now) else {
            publishPending = true
            return nil
        }

        publishedText = receivedText
        publishPending = false
        recordPublish(at: now)
        return snapshot()
    }

    private func snapshot() -> CodeStreamingSnapshot {
        CodeStreamingSnapshot(id: CodeStreamingSnapshot.streamingRowID,
                              text: publishedText,
                              isComplete: isComplete)
    }

    private func throttleAllows(at now: TimeInterval) -> Bool {
        guard let lastPublishedAt else { return true }
        // A negative elapsed time means the clock went backwards; it is treated
        // as "the window has not elapsed yet".
        return now - lastPublishedAt >= Self.nonNegative(config.publishInterval)
    }

    private mutating func recordPublish(at now: TimeInterval) {
        // `ContinuousClock` never runs backwards. With an injected clock we
        // keep the newest instant so a rollback cannot create a publish burst.
        lastPublishedAt = max(now, lastPublishedAt ?? now)
    }

    private static func nonNegative(_ value: TimeInterval) -> TimeInterval {
        value.isFinite ? max(0, value) : 0
    }
}

import Foundation

// W6: the Code profile's chunked streaming publisher.
//
// The official Code page has no per-character reveal, no mask and no reveal
// timeline: `TextPacing` is hard-coded to `.none` and the shared binding never
// builds a `RevealDriver` (CANONICAL/03-streaming.md §9.1; CANONICAL/10-chat-page.md
// §3). What reaches the screen is a series of full text snapshots:
//
//   - Publishing is a 0.1 s leading-edge throttle with no timer. Inside the
//     window a publish request only sets `publishPending`; the next event that
//     arrives after the window flushes it (CANONICAL/03-streaming.md §5.1).
//   - Snapshots append whole chunks: 4–8 English words, roughly 50–100 ms
//     apart (CANONICAL/03-streaming.md §9.2, 60 fps video observation). Text
//     without word boundaries (CJK and other unspaced scripts) falls back to a
//     character count because there is no whitespace to split on.
//   - Catch-up: the first snapshot and an oversized backlog are published
//     whole. Opening a session in the middle of a stream delivers a large
//     accumulated text at once; pacing it at 8 words / 0.1 s would keep the
//     screen seconds behind.
//   - The row identity is the fixed `.streamingText` kind and never changes.
//     Completion is exposed only as `isComplete`; the wiring layer replaces the
//     row by deleting it and inserting the persisted message (§8.1–§8.2).
//
// Identity contract (P2-3): one `CodeStreamingPublisher` owns exactly one text
// block. A message with multiple blocks is the caller's concern — concatenate
// the blocks in block order and feed the combined text into one publisher.
// This layer always reports a single fixed row id (`.streamingText`).
//
// This type is pure logic with an injected clock. It starts no timer, imports
// no UI module, and is isolated from Chat's `StreamingRevealTimeline`: there is
// no character cursor, no mask, and no reveal here — only text snapshots.

/// Chunk boundaries for the Code profile. Official values come from the 60 fps
/// video observation in CANONICAL/03-streaming.md §9.2 (4–8 English words per
/// append, 50–100 ms apart); they are INFERENCE, not binary constants.
nonisolated struct CodeChunkPolicy: Equatable, Sendable {
    /// Words a chunk should hold before it may be released early (at
    /// `minimumWait`). A chunk below this size waits for `maximumWait`.
    var minimumWords: Int = 4
    /// Hard cap. A burst larger than this is split across publishes.
    var maximumWords: Int = 8
    /// Earliest a chunk that has reached `minimumWords` may be released.
    var minimumWait: TimeInterval = 0.05
    /// Latest a chunk may be held. When it expires, whitespace text releases
    /// its complete words, and an unspaced run is published whole rather than
    /// being cut. This is the "最多等 50–100 ms" bound.
    var maximumWait: TimeInterval = 0.1
    /// Character fallback for text without word boundaries: how many
    /// characters count as one "word". One CJK character carries roughly the
    /// information of two Latin characters, so 4–8 words maps to 8–16 CJK
    /// characters.
    var charactersPerWord: Int = 2
}

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
        var chunk: CodeChunkPolicy = CodeChunkPolicy()
        /// Catch-up threshold in word-units. When a non-first buffer already
        /// holds at least this much, it is published whole instead of being
        /// paced at `chunk.maximumWords` per publish. The default (32) is four
        /// maximum-size chunks.
        var catchUpWordThreshold: Int = 32
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

    /// Received but not yet on screen.
    private var buffer: String = ""
    /// When the oldest currently buffered character arrived. Used for the
    /// 50–100 ms chunk wait.
    private var bufferStartedAt: TimeInterval?
    /// Monotonic high-water mark of publish instants. Never moves backwards so
    /// a rollback of the injected clock cannot trigger a publish burst.
    private var lastPublishedAt: TimeInterval?
    /// A cumulative update that was not an append; the visible text must be
    /// replaced. Corrections bypass chunk aggregation but not the throttle.
    private var correctionText: String?

    init(config: Config = Config()) {
        self.config = config
    }

    /// Full text received so far, including text not yet published.
    var receivedText: String {
        correctionText ?? publishedText + buffer
    }

    var hasPendingText: Bool {
        !buffer.isEmpty || correctionText != nil
    }

    /// Append an incremental text delta received at `now`.
    ///
    /// Returns a snapshot when this event crosses both gates (chunk ready and
    /// throttle open); otherwise returns nil. Nothing is scheduled: a pending
    /// publish is flushed by a later `receive`/`flush` event.
    mutating func receive(delta: String, at now: TimeInterval) -> CodeStreamingSnapshot? {
        guard !isComplete else { return nil }

        if !delta.isEmpty {
            if let correctionText {
                self.correctionText = correctionText + delta
            } else {
                if buffer.isEmpty { bufferStartedAt = now }
                buffer += delta
            }
        }

        return attemptPublish(at: now)
    }

    /// Feed a cumulative full text (the official assembler keeps full text per
    /// block, CANONICAL/03-streaming.md §4.2). A prefix extension is treated as
    /// a delta; anything else is a correction that replaces the visible text.
    mutating func receive(fullText: String, at now: TimeInterval) -> CodeStreamingSnapshot? {
        guard !isComplete else { return nil }

        let current = receivedText
        if fullText == current { return attemptPublish(at: now) }
        if fullText.hasPrefix(current) {
            return receive(delta: String(fullText.dropFirst(current.count)), at: now)
        }

        // The server replaced text that was already shown. This is rare, so it
        // bypasses chunk aggregation; it still respects the publish throttle.
        correctionText = fullText
        buffer = ""
        bufferStartedAt = nil
        return attemptPublish(at: now)
    }

    /// Event-driven flush for the caller's clock tick (display link, coalesced
    /// callback, or any later event). It never bypasses the chunk or throttle
    /// gates; it only supplies an event when no new text arrived. The publisher
    /// itself starts no timer.
    mutating func flush(at now: TimeInterval) -> CodeStreamingSnapshot? {
        attemptPublish(at: now)
    }

    /// Publishes everything buffered and marks the row complete.
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
        buffer = ""
        bufferStartedAt = nil
        correctionText = nil
        publishPending = false
        recordPublish(at: now)
        return CodeStreamingSnapshot(id: CodeStreamingSnapshot.streamingRowID,
                                     text: publishedText,
                                     isComplete: true)
    }

    // MARK: - Publishing

    private mutating func attemptPublish(at now: TimeInterval) -> CodeStreamingSnapshot? {
        if let correctionText {
            guard throttleAllows(at: now) else {
                publishPending = true
                return nil
            }
            publishedText = correctionText
            self.correctionText = nil
            buffer = ""
            bufferStartedAt = nil
            publishPending = false
            recordPublish(at: now)
            return snapshot()
        }

        guard let prefix = releasablePrefix(at: now) else { return nil }
        guard throttleAllows(at: now) else {
            publishPending = true
            return nil
        }

        publishedText += prefix
        buffer.removeFirst(prefix.count)
        if buffer.isEmpty { bufferStartedAt = nil }
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

    /// The prefix of the buffer that may go on screen at `now`, or nil when the
    /// chunk is not ready. Whole words only in whitespace-delimited text.
    private func releasablePrefix(at now: TimeInterval) -> String? {
        guard !buffer.isEmpty else { return nil }

        let limits = Limits(chunk: config.chunk,
                            catchUpWordThreshold: config.catchUpWordThreshold)
        let waited = max(now - (bufferStartedAt ?? now), 0)

        // Catch-up (P2-2): the first snapshot and an oversized backlog skip
        // chunk pacing. Opening a session mid-stream must not replay the
        // backlog at 8 words / 0.1 s.
        if publishedText.isEmpty
            || Self.wordUnits(in: buffer, charactersPerWord: limits.charactersPerWord)
                >= limits.catchUpWords {
            return buffer
        }

        if buffer.contains(where: { $0.isWhitespace }) {
            let ends = Self.completeWordEnds(in: buffer)
            if ends.isEmpty {
                // Only a trailing ASCII word may still be growing; hold it
                // (bounded by maximumWait) so a chunk never contains half a
                // word. Anything else — leading whitespace plus CJK, dashes,
                // punctuation — has no word boundary to wait for, so it falls
                // through to the character fallback instead of stalling (P1).
                if Self.isASCIIWordRun(Self.tailAfterLastWhitespace(in: buffer)) {
                    return waited >= limits.maximumWait ? buffer : nil
                }
                return characterPrefix(limits: limits, waited: waited)
            }

            let count: Int
            if ends.count >= limits.maximumWords {
                count = limits.maximumWords
            } else if waited >= limits.maximumWait {
                count = ends.count
            } else if waited >= limits.minimumWait, ends.count >= limits.minimumWords {
                count = ends.count
            } else {
                return nil
            }
            return String(buffer[..<ends[count - 1]])
        }

        if Self.isASCIIWordRun(buffer) {
            // A long hash or identifier has no whitespace to wait for. Hold it
            // only until maximumWait, then publish the whole word rather than
            // cutting it into character-sized pieces (P2-1).
            return waited >= limits.maximumWait ? buffer : nil
        }

        return characterPrefix(limits: limits, waited: waited)
    }

    private func characterPrefix(limits: Limits, waited: TimeInterval) -> String? {
        let minimumCharacters = limits.minimumWords * limits.charactersPerWord
        let maximumCharacters = limits.maximumWords * limits.charactersPerWord
        let count: Int
        if buffer.count >= maximumCharacters {
            count = maximumCharacters
        } else if waited >= limits.maximumWait {
            count = buffer.count
        } else if waited >= limits.minimumWait, buffer.count >= minimumCharacters {
            count = buffer.count
        } else {
            return nil
        }
        guard count > 0 else { return nil }
        let end = buffer.index(buffer.startIndex, offsetBy: count)
        return String(buffer[..<end])
    }

    // MARK: - Text scanning

    /// End index of every complete word, including its trailing whitespace.
    /// A word is complete only when whitespace follows it; a trailing token
    /// with no whitespace may still grow and is not complete.
    private static func completeWordEnds(in text: String) -> [String.Index] {
        var ends: [String.Index] = []
        var index = text.startIndex
        var insideWord = false

        while index < text.endIndex {
            if text[index].isWhitespace {
                if insideWord {
                    var end = index
                    while end < text.endIndex, text[end].isWhitespace {
                        end = text.index(after: end)
                    }
                    ends.append(end)
                    insideWord = false
                    index = end
                    continue
                }
            } else {
                insideWord = true
            }
            index = text.index(after: index)
        }
        return ends
    }

    private static func tailAfterLastWhitespace(in text: String) -> String {
        guard let last = text.lastIndex(where: { $0.isWhitespace }) else { return text }
        return String(text[text.index(after: last)...])
    }

    private static func isASCIIWordRun(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        return text.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar)
                || scalar.value == 0x5F) // "_"
        }
    }

    /// Word-units in a buffer, used only by the catch-up gate. Whitespace text
    /// counts whitespace-separated tokens; unspaced text uses the same
    /// characters-per-word mapping as the chunk fallback.
    private static func wordUnits(in text: String, charactersPerWord: Int) -> Int {
        if text.contains(where: { $0.isWhitespace }) {
            return text.split(whereSeparator: { $0.isWhitespace }).count
        }
        return text.count / max(1, charactersPerWord)
    }

    private static func nonNegative(_ value: TimeInterval) -> TimeInterval {
        value.isFinite ? max(0, value) : 0
    }

    /// Normalized policy so injected nonsense cannot invert the gates or
    /// overflow the word/character multiplications (P2-4). Integer parameters
    /// are clamped to 1...4096; 4096 * 4096 is far below `Int.max`.
    private struct Limits {
        let minimumWords: Int
        let maximumWords: Int
        let minimumWait: TimeInterval
        let maximumWait: TimeInterval
        let charactersPerWord: Int
        let catchUpWords: Int

        init(chunk policy: CodeChunkPolicy, catchUpWordThreshold: Int) {
            maximumWords = Self.clamp(policy.maximumWords)
            minimumWords = min(Self.clamp(policy.minimumWords), maximumWords)
            maximumWait = CodeStreamingPublisher.nonNegative(policy.maximumWait)
            minimumWait = min(CodeStreamingPublisher.nonNegative(policy.minimumWait),
                              maximumWait)
            charactersPerWord = Self.clamp(policy.charactersPerWord)
            catchUpWords = Self.clamp(catchUpWordThreshold)
        }

        private static func clamp(_ value: Int) -> Int {
            min(max(value, 1), 4096)
        }
    }
}

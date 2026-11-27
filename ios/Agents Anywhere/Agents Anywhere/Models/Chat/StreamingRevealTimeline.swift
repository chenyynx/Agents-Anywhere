import Foundation

/// Pure reveal cursor for the official Chat-style streaming text.
///
/// The cursor advances continuously in "characters" (the caller's unit; AA
/// uses UTF-16 offsets because the mask ranges feed `NSRange`/TextKit). The
/// timeline is deliberately free of UIKit so the three-segment pacing can be
/// unit-tested with a deterministic clock.
///
/// Official values: 320 chars/s, 640 chars/s catch-up, 2.0 s drain. The last
/// `cps * drain = 640` characters are revealed linearly at `cps`; the segment
/// before that decays exponentially with τ = drain.
nonisolated struct StreamingRevealTimeline: Equatable {
    struct Config: Equatable {
        var charactersPerSecond: Double = 320
        var maxCharactersPerSecond: Double = 640
        var drainSeconds: Double = 2.0
        /// Present in the official provider's config, unused by the timeline
        /// formula (kept so the values stay in one place).
        var settleSeconds: Double = 0.6

        var backlogThreshold: Double { charactersPerSecond * drainSeconds }
        var tailWindow: Double { maxCharactersPerSecond * drainSeconds }
    }

    struct Segment: Equatable {
        var time: TimeInterval
        var total: Int
        var head: Double
    }

    var config: Config
    private(set) var segment: Segment?

    init(config: Config = Config()) {
        self.config = config
    }

    /// Total characters of the current anchor (0 before the first retarget).
    var total: Int { segment?.total ?? 0 }

    /// Anchor head: characters already shown when the current segment started.
    var head: Double { segment?.head ?? 0 }

    /// A correction/recovery restarts the stream: the caller drops the
    /// timeline and retargets from the new text.
    mutating func reset() {
        segment = nil
    }

    /// Anchor a new received-text total. Already-shown characters never move
    /// backwards; a shorter total (correction) clamps the head.
    mutating func retarget(total: Int, at now: TimeInterval) {
        let clampedTotal = max(total, 0)
        let current = shownThrough(at: now)
        let previousTotal = segment?.total ?? 0
        let head = min(max(Double(max(previousTotal, current)), 0),
                       Double(clampedTotal))
        segment = Segment(time: now, total: clampedTotal, head: head)
    }

    /// Start a cursor at an explicit position. Used when a text first appears:
    /// everything already received is shown at once, because opening a page
    /// mid-stream must not replay the answer from its first character.
    mutating func anchor(total: Int, at now: TimeInterval, head: Int) {
        let clampedTotal = max(total, 0)
        segment = Segment(time: now, total: clampedTotal,
                          head: Double(min(max(head, 0), clampedTotal)))
    }

    /// Re-anchor a cursor at its **own** current position. Unlike `retarget`,
    /// the head follows `shownThrough(now)` rather than the previous total, so
    /// a paused cursor (see `StreamingRevealClock`) freezes where it stood and
    /// later anchors on a larger total resume from that point instead of
    /// jumping over the backlog. `maxBacklog` drops stale backlog beyond the
    /// official `longestLagSeconds` budget: the oldest characters are skipped,
    /// the tail is still revealed at the usual pace.
    mutating func reanchor(total: Int, at now: TimeInterval,
                           maxBacklog: Int? = nil) {
        let clampedTotal = max(total, 0)
        var head = min(max(Double(shownThrough(at: now)), 0), Double(clampedTotal))
        if let maxBacklog, maxBacklog >= 0 {
            head = max(head, Double(max(clampedTotal - maxBacklog, 0)))
        }
        segment = Segment(time: now, total: clampedTotal, head: head)
    }

    /// Integer characters to display at `now`, using the official formula and
    /// `floor(position + 1e-9)`.
    func shownThrough(at now: TimeInterval) -> Int {
        guard let segment else { return 0 }
        let position = position(at: now, segment: segment)
        guard position.isFinite else { return 0 }
        let floored = floor(position + 1e-9)
        guard floored.isFinite else { return 0 }
        return min(max(Int(floored), 0), segment.total)
    }

    /// Continuous cursor position (exposed for tests and for the visual layer
    /// when it needs sub-character precision).
    func position(at now: TimeInterval, segment: Segment) -> Double {
        let total = Double(segment.total)
        let remaining = total - segment.head
        let elapsed = now - segment.time
        let cps = config.charactersPerSecond
        let maxCps = config.maxCharactersPerSecond
        let drain = config.drainSeconds
        guard cps > 0, maxCps > 0, drain > 0 else { return total }

        if remaining <= 0 || elapsed <= 0 {
            return min(segment.head, total)
        }

        if remaining <= cps * drain {
            let advance = min(elapsed * cps, remaining)
            return total - (remaining - advance)
        }

        let tail = min(maxCps * drain, remaining)
        let bulk = remaining - tail
        let tBulk = bulk / maxCps
        if elapsed <= tBulk {
            let advance = min(elapsed * maxCps, remaining)
            return total - (remaining - advance)
        }

        let delta = elapsed - tBulk
        let ratio = tail / (cps * drain)
        let ln = log(ratio)
        let switchAt = drain * ln
        let tailRemaining: Double
        if delta < switchAt {
            tailRemaining = tail * exp(-delta / drain)
        } else {
            // Linear 320/s finish: this branch starts at 640 characters and
            // reaches 0 after exactly `drain` seconds.
            tailRemaining = cps * (drain * (1 + ln) - delta)
        }
        return total - min(max(tailRemaining, 0), remaining)
    }
}

/// Wall-clock mapping for a reveal cursor.
///
/// The official `RevealDriver` keeps its progress in the content model and
/// only advances it while the page's frame source runs; a hidden page freezes
/// where it stood and continues from there when it returns (CANONICAL/29
/// §18). AA's text pipeline publishes whole snapshots on applies, so the same
/// effect comes from sampling the cursor with a clock that stops while the
/// page is off screen: hidden time is accumulated and subtracted, and the
/// timeline never sees it.
nonisolated struct StreamingRevealClock: Equatable {
    private(set) var isVisible = true
    private var hiddenSince: TimeInterval?
    private var hiddenTotal: TimeInterval = 0

    init() {}

    mutating func setVisible(_ visible: Bool, at wall: TimeInterval) {
        guard visible != isVisible else { return }
        if visible {
            if let hiddenSince { hiddenTotal += max(0, wall - hiddenSince) }
            hiddenSince = nil
        } else {
            hiddenSince = wall
        }
        isVisible = visible
    }

    /// The reveal clock at `wall`. While hidden it reads the instant the page
    /// left; afterwards it continues from that instant.
    func now(at wall: TimeInterval) -> TimeInterval {
        if let hiddenSince { return hiddenSince - hiddenTotal }
        return wall - hiddenTotal
    }
}

/// One streaming text's reveal progress, in characters.
///
/// This is the AA counterpart of the official `Progress.released`: the count
/// only grows, it survives batches because the owner keeps it, and a hidden
/// page freezes it. The cursor is **sampled**, not ticked: the Code page
/// draws whole-text snapshots per apply, so a display link would recompute a
/// prefix nothing re-renders. Sampling at the refresh cadence paints exactly
/// what that update can show.
nonisolated struct StreamingRevealCursor: Equatable {
    var config: StreamingRevealTimeline.Config
    /// Hidden time replays at most this many seconds of backlog; older
    /// characters are skipped like the official `longestLagSeconds` cap.
    var longestLagSeconds: Double
    private(set) var timeline: StreamingRevealTimeline
    private(set) var clock = StreamingRevealClock()
    /// The first sample shows everything already received (see
    /// `StreamingRevealTimeline.anchor`).
    private var hasAnchored = false

    init(config: StreamingRevealTimeline.Config = StreamingRevealTimeline.Config(),
         longestLagSeconds: Double = 3) {
        self.config = config
        self.longestLagSeconds = longestLagSeconds
        timeline = StreamingRevealTimeline(config: config)
    }

    var isVisible: Bool { clock.isVisible }

    var maxBacklogCharacters: Int {
        max(0, Int((config.charactersPerSecond * longestLagSeconds).rounded()))
    }

    mutating func setVisible(_ visible: Bool, at wall: TimeInterval) {
        clock.setVisible(visible, at: wall)
    }

    /// Begin with only the last `maxBacklogCharacters` owed.
    ///
    /// Used when a text first appears while its page is off screen: the whole
    /// answer arrived behind the reader's back, so the return replays its tail
    /// at the usual pace (official `longestLagSeconds`) instead of either
    /// flashing everything or replaying a very long answer from its first
    /// character.
    mutating func startFromTail(total: Int, at wall: TimeInterval) {
        let now = clock.now(at: wall)
        let clamped = max(total, 0)
        hasAnchored = true
        timeline = StreamingRevealTimeline(config: config)
        timeline.anchor(total: clamped, at: now,
                        head: max(0, clamped - maxBacklogCharacters))
    }

    /// Characters of `total` that may be drawn now.
    mutating func revealedCount(total: Int, at wall: TimeInterval) -> Int {
        let now = clock.now(at: wall)
        if !hasAnchored {
            hasAnchored = true
            timeline.anchor(total: total, at: now, head: total)
        } else if timeline.total != total {
            timeline.reanchor(total: total, at: now,
                              maxBacklog: maxBacklogCharacters)
        }
        return min(timeline.shownThrough(at: now), max(total, 0))
    }

    /// The visible prefix of `text`.
    mutating func reveal(_ text: String, at wall: TimeInterval) -> String {
        let count = revealedCount(total: text.count, at: wall)
        return count >= text.count ? text : String(text.prefix(count))
    }
}

/// Which settled assistant messages may enter a tail replay on return.
///
/// Only a row that **first appeared while the page was off screen** may do
/// so. A row that was already in the window before the hide is text the
/// reader has seen; replaying it made 18 old messages animate on one return
/// (pp 2026-11-27, backlog 9698). A page that was never sampled while visible
/// cannot tell "new while away" from "existing", so it shows everything whole.
nonisolated enum StreamingRevealReplayPolicy {
    static func shouldReplay(isAssistantText: Bool,
                             hasSampledVisible: Bool,
                             isKnownRow: Bool,
                             hasCursor: Bool,
                             isResuming: Bool,
                             textEmpty: Bool) -> Bool {
        isAssistantText && hasSampledVisible && !isKnownRow
            && !hasCursor && isResuming && !textEmpty
    }

    /// Whether a row carries assistant text the reader could already have
    /// seen. Row *presence* is not enough: the turn's assistant row can exist
    /// with no text yet (or only tool calls) while the reply is still being
    /// generated. Marking that empty row as seen is what swallowed the replay
    /// for a reply that arrived while the reader was on another tab
    /// (pp 2026-11-27, after b1709).
    static func hasSeenText(isAssistantText: Bool, textEmpty: Bool) -> Bool {
        isAssistantText && !textEmpty
    }
}

/// Visual run granularity: official draws in runs of 24...64 characters and

/// waits at most 0.35 s for a run to fill. The generator mirrors the official
/// xorshift64 + splitmix sequence; the policy is pure so the gate can test it.
nonisolated struct StreamingRevealRunGenerator: Equatable {
    var range: ClosedRange<Int> = 24...64
    private var state: UInt64

    init(seed: UInt64 = 0) {
        // Official attach: (seed * 0x9E3779B97F4A7C15) | 1; reset: state = 1.
        let mixed = seed &* 0x9E3779B97F4A7C15 | 1
        state = mixed == 0 ? 1 : mixed
    }

    mutating func reset() {
        state = 1
    }

    mutating func nextRun() -> Int {
        var x = state
        x ^= x >> 12
        x ^= x << 25
        x ^= x >> 27
        state = x
        let value = x &* 0x2545F4914F6CDD1D
        let span = UInt64(range.upperBound - range.lowerBound + 1)
        return range.lowerBound + Int(value % span)
    }
}

/// What the cell needs to run the reveal: the anchored timeline, the message's
/// character total, and whether the text itself has stopped growing.
nonisolated struct StreamingRevealState: Equatable {
    var timeline: StreamingRevealTimeline
    var total: Int
    var isTextComplete: Bool

    func shownThrough(at now: TimeInterval) -> Int {
        min(timeline.shownThrough(at: now), total)
    }

    func isCaughtUp(at now: TimeInterval) -> Bool {
        shownThrough(at: now) >= total
    }
}

nonisolated struct StreamingRevealRunPolicy: Equatable {
    var patience: TimeInterval = 0.35

    enum Decision: Equatable {
        case advance
        case wait
    }

    /// `waitingSince` is the first moment the caller observed a short run; nil
    /// means this is the first short observation (the caller starts waiting).
    func decision(released: Int,
                  target: Int,
                  nextRun: Int,
                  waitingSince: TimeInterval?,
                  now: TimeInterval) -> Decision {
        guard target > released else { return .wait }
        if target - released >= max(1, nextRun) { return .advance }
        guard let waitingSince else { return .wait }
        return now - waitingSince >= patience ? .advance : .wait
    }
}

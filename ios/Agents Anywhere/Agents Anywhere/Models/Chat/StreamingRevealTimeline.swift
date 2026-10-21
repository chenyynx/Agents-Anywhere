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

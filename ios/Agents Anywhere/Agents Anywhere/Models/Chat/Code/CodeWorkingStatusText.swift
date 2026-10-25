import Foundation

/// What the Code page's working row is reporting, mirroring the official
/// `DisplayMessage.WorkingStatus` cases (`CANONICAL/20-working-mark.md` §4).
///
/// The official row is **not** event text from the server: `.server` rotates
/// the 20 connecting verbs, while `compacting` and `connecting` are fixed
/// localised strings. The selection branch is `0x102a8507c` (tag 0 →
/// `ccr_compacting`, tag 1 → `connecting`, tag 2 → the verb table at
/// `0x1055aacc0`; the `.server` payload is not passed to the rotation).
nonisolated enum CodeWorkingStatusPhase: Equatable, Sendable {
    /// Session/connection not ready (sent, no agent start yet).
    case connecting
    /// The runtime is compacting the conversation.
    case compacting
    /// Normal work. The verb rotates with the official phase timing, anchored
    /// at the work block's start.
    case working(startedAt: Date)
    /// A thinking block is in progress. `startedAt` is the turn start, not the
    /// block start: the official live tiers measure `now − turnStartedAt`
    /// (`0x102a89010`).
    case thinking(startedAt: Date)
    /// The turn's last thinking block just settled. The official label is
    /// `思考了 X` only while `now < endedAt + 2 s`; past that window the
    /// selector returns nil and the caller falls back to the verb rotation
    /// anchored at the turn start (`0x102a88f20-f50`).
    case thoughtFor(seconds: Int, endedAt: Date, fallbackStartedAt: Date)
}

/// The official `.server` verb rotation.
///
/// `index = (abs(baseDate) % 20 + phase(elapsed)) % 20`, with
/// `baseDate = Date.distantPast` making the first term 0 and
/// `phase(d) = 0 (d < 3s) / 1 (3s ≤ d < 7s) / floor((d - 7) / 6) + 2 (≥ 7s)`
/// (`0x102a85174` + `0x102a89f6c`). So the verb holds for 3 s, then 4 s, then
/// changes every 6 s — it is not a wall-clock `% 20` per second.
nonisolated enum CodeWorkingStatusText {
    /// `0x1055aacc0` element order, read verbatim (20 entries).
    static let verbs = ["Clauding", "Cogitating", "Computing", "Contemplating",
                        "Cooking", "Deliberating", "Generating", "Imagining",
                        "Musing", "Noodling", "Pondering", "Processing",
                        "Scheming", "Synthesizing", "Thinking", "Tinkering",
                        "Working", "Ruminating", "Percolating", "Brewing"]

    /// The verb for `elapsed` seconds since the work block started.
    static func index(elapsed: TimeInterval) -> Int {
        let elapsed = max(0, elapsed)
        let phase: Double
        if elapsed < 3 { phase = 0 }
        else if elapsed < 7 { phase = 1 }
        else { phase = ((elapsed - 7) / 6).rounded(.down) + 2 }
        return Int(phase) % verbs.count
    }

    static func verb(elapsed: TimeInterval) -> String {
        verbs[index(elapsed: elapsed)]
    }
}

/// The official thinking labels.
///
/// Live: five tiers read straight from `0x102a89080`'s comparisons against
/// `max(0, trunc(now − turnStartedAt))` — 0–14, 15–29, 30–44, 45–59, ≥ 60 s.
/// Closed: the official `thinking_status_thought_for_duration`
/// (`thought for %@` / `思考了 %@`) fed by `Duration.UnitsFormatStyle` with
/// the exact parameters decoded from `0x100bb7810`
/// (R24 `live-thinking-timer.md` §4).
nonisolated enum CodeThinkingText {

    /// The closed label lives only while `now < endedAt + 2.0`
    /// (`0x102a88f20`: `fmov d0, #2.0`; `0x102a88f4c`: `now < endedAt+2`).
    static let closedWindow: TimeInterval = 2

    /// The five tiers in official order. The raw values are the official
    /// string keys so the catalog stays traceable to the bundle.
    enum LiveTier: String, Equatable, Sendable {
        case thinking = "thinking_status_thinking"
        case stillThinking = "thinking_status_still_thinking"
        case thinkingMore = "thinking_status_thinking_more"
        case thinkingSomeMore = "thinking_status_thinking_some_more"
        case almostDone = "thinking_status_almost_done_thinking"
    }

    /// `0x102a89118` (`cmp x25, 0xe`), `0x102a89128` (`0x1d`),
    /// `0x102a89138` (`0x2c`), `0x102a89148` (`0x3b`); input is already
    /// `max(0, trunc(Δ))`.
    static func liveTier(elapsed: TimeInterval) -> LiveTier {
        let seconds = Int(max(0, elapsed))
        switch seconds {
        case ...14: return .thinking
        case ...29: return .stillThinking
        case ...44: return .thinkingMore
        case ...59: return .thinkingSomeMore
        default: return .almostDone
        }
    }

    static func liveText(elapsed: TimeInterval, locale: Locale = .autoupdatingCurrent) -> String {
        switch liveTier(elapsed: elapsed) {
        case .thinking:
            return String(localized: "thinking_status_thinking", locale: locale)
        case .stillThinking:
            return String(localized: "thinking_status_still_thinking", locale: locale)
        case .thinkingMore:
            return String(localized: "thinking_status_thinking_more", locale: locale)
        case .thinkingSomeMore:
            return String(localized: "thinking_status_thinking_some_more", locale: locale)
        case .almostDone:
            return String(localized: "thinking_status_almost_done_thinking", locale: locale)
        }
    }

    /// Official closed rounding: `frinta` (half away from zero) then
    /// `max(1, n)` (`0x102a88f60`, `0x102a88f90`).
    static func closedSeconds(_ interval: TimeInterval) -> Int {
        let rounded = interval.rounded()
        guard rounded.isFinite, rounded < Double(Int.max), rounded > Double(Int.min) else {
            return 1
        }
        return max(1, Int(rounded))
    }

    /// `0x102a891bc`: allowed `{hours, minutes, seconds}`, width `.narrow`,
    /// `maximumUnitCount: 2`, zero-value units `.hide`, no value length,
    /// fractional part `.hide`, locale passed in from
    /// `Locale.autoupdatingCurrent` at the call site (`0x102a84cf4`).
    static func durationText(seconds: Int, locale: Locale = .autoupdatingCurrent) -> String {
        let duration = Duration.seconds(max(1, seconds))
        let style = Duration.UnitsFormatStyle(
            allowedUnits: [.hours, .minutes, .seconds],
            width: .narrow,
            maximumUnitCount: 2,
            zeroValueUnits: .hide,
            valueLength: nil,
            fractionalPart: .hide
        )
        .locale(locale)
        return duration.formatted(style)
    }

    /// `0x102cda6dc`: the format string is localized and the formatted
    /// duration is the only argument.
    static func closedText(seconds: Int, locale: Locale = .autoupdatingCurrent) -> String {
        let amount = durationText(seconds: seconds, locale: locale)
        let format = String(localized: "thought for %@", locale: locale)
        return String(format: format, amount)
    }
}

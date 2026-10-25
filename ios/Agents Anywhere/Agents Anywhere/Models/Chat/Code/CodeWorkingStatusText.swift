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

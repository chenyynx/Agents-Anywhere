import Foundation
import Observation
#if canImport(os)
import os
#endif

/// One entry of the timeline's on-device decision log. The windowed timeline
/// decides several times per layout (gate → plan → commit → measure →
/// correct); on device each of those used to be invisible, and a regression
/// could only be chased by shipping another build. Every decision lands here
/// instead: the chat page shows the log on screen and copies it out whole.
nonisolated struct TimelineDiagEvent: Equatable, Identifiable {
    enum Kind: Equatable {
        /// A gate refused to judge a move; `item` is the member that closed it
        /// (`TimelineWindowMoveGate.Refusal`), `phase` the reader's phase.
        case gateRefused(item: String, phase: String)
        /// A boundary move committed: `units` whole units, `estimatedHeight`
        /// their summed estimate — the height the spacer was charged/released —
        /// and `measuredHeight`, how much of that block had already been
        /// measured (`estimated − measured` is the move's estimate exposure).
        case plannedMove(move: String, units: Int, estimatedHeight: CGFloat, measuredHeight: CGFloat)
        /// The anchor's correction was evaluated: the unit that stayed
        /// rendered, the displacement it removes (real height minus estimate),
        /// the offset it would write, the phase it would write under, and
        /// whether it actually did (`TimelineAnchorWritePolicy`).
        case correction(anchor: String, delta: CGFloat, targetOffset: CGFloat, phase: String, wrote: Bool)
        /// The write was refused by the per-write fuse: a displacement past
        /// `TimelineAnchorWritePolicy.maxWrittenDelta` is uncorrected
        /// structure, not a residual — writing it would fling the reader.
        case correctionCapped(anchor: String, delta: CGFloat, phase: String)
        /// A unit an expand just materialised reported its first measurement —
        /// the height model's residual for that unit, the Δ a correction eats.
        case materialized(id: String, estimated: CGFloat, measured: CGFloat)
        /// A history prepend landed through the coalescer: how many rows it
        /// added to what was already presented.
        case prependLanding(addedRows: Int, presentedRows: Int)
        /// The rendered slice changed (a membership rebuild or a committed
        /// move): the raw row index the view cuts `rows` on, the boundary
        /// unit, the render set's size and the spacer it stood up.
        case sliceChange(startRowIndex: Int, boundary: String?, renderedUnits: Int, spacerHeight: CGFloat)

        /// One line for one event at one clock reading — the transcript the
        /// buffer stores and the line the os.Logger double-write emits, so
        /// the on-screen log and Console carry the same text.
        func line(at clock: TimeInterval) -> String {
            let stamp = String(format: "%.3f", clock)
            switch self {
            case let .gateRefused(item, phase):
                return "\(stamp) gate refused: \(item) (\(phase))"
            case let .plannedMove(move, units, estimatedHeight, measuredHeight):
                return "\(stamp) move: \(move) \(units) units, est \(Self.points(estimatedHeight))pt measured \(Self.points(measuredHeight))pt"
            case let .correction(anchor, delta, targetOffset, phase, wrote):
                return "\(stamp) correct: \(anchor) Δ\(Self.signed(delta)) → \(Self.points(targetOffset)) (\(phase)) \(wrote ? "wrote" : "absorbed")"
            case let .correctionCapped(anchor, delta, phase):
                return "\(stamp) capped: \(anchor) Δ\(Self.signed(delta)) (\(phase)) — not written"
            case let .materialized(id, estimated, measured):
                return "\(stamp) measured: \(id) est \(Self.points(estimated)) vs \(Self.points(measured)) Δ\(Self.signed(measured - estimated))"
            case let .prependLanding(addedRows, presentedRows):
                return "\(stamp) prepend: +\(addedRows) rows (presented \(presentedRows))"
            case let .sliceChange(startRowIndex, boundary, renderedUnits, spacerHeight):
                return "\(stamp) slice: start=\(startRowIndex) boundary=\(boundary ?? "-") rendered=\(renderedUnits) spacer=\(Self.points(spacerHeight))"
            }
        }

        private static func points(_ value: CGFloat) -> String {
            String(format: "%.1f", Double(value))
        }

        private static func signed(_ value: CGFloat) -> String {
            (value >= 0 ? "+" : "−") + points(abs(value))
        }
    }

    /// Monotonic sequence number (survives the ring's head dropping).
    let id: Int
    /// `ProcessInfo` uptime when the entry was appended.
    let at: TimeInterval
    let kind: Kind

    /// The one-line transcript entry: stable enough to paste into a bug
    /// report and grep in a Console export.
    var formatted: String { kind.line(at: at) }
}

/// The ring itself: append-only, bounded, oldest-first. Pure bookkeeping with
/// no framework at all, so the cap, the order and the transcript formatting
/// are pinned by unit tests.
nonisolated struct TimelineDiagBuffer {
    private(set) var events: [TimelineDiagEvent] = []
    private var nextID = 1
    /// The hard cap. A continuous storm (a backfill flood, a token stream)
    /// must never grow the log without bound.
    let capacity: Int

    init(capacity: Int = 400) { self.capacity = max(1, capacity) }

    var isEmpty: Bool { events.isEmpty }

    mutating func append(_ kind: TimelineDiagEvent.Kind, at: TimeInterval) {
        let event = TimelineDiagEvent(id: nextID, at: at, kind: kind)
        nextID += 1
        events.append(event)
        if events.count > capacity { events.removeFirst(events.count - capacity) }
    }

    mutating func removeAll() { events.removeAll() }

    /// The copyable transcript — one line per event, oldest first.
    func formatted() -> String {
        events.map(\.formatted).joined(separator: "\n")
    }
}

/// The log's facade: the one entry point every call site uses. Disabled by
/// default (the toggle lives in Settings, plus the `AA_TIMELINE_DIAG=1` env
/// override); while it is off, `record` evaluates nothing — the payload is an
/// autoclosure, so not even the event's fields are built.
///
/// Appends are synchronous. The one call site that runs inside a view body
/// (the store's slice note) hops a runloop turn *before* calling in: writing
/// observed state mid-update is undefined, and the hop keeps the panel's
/// re-render out of the update that caused it.
@MainActor @Observable
final class TimelineDiag {
    static let shared = TimelineDiag()
    /// The `@AppStorage`/UserDefaults key behind the Settings toggle.
    static let enabledKey = "timelineDiagnosticsEnabled"

    /// Whether the log is collecting. Observed, so the chat page mounts (and
    /// unmounts) its panel from the toggle without polling.
    private(set) var isEnabled = false
    /// Observed append counter: the panel re-reads the buffer when it moves.
    /// The buffer itself is ignored, so an append costs one integer write.
    private(set) var revision = 0

    /// The hot-path flag `record` reads: *not* observed, so a call site inside
    /// a body cannot make the timeline invalidate on the toggle.
    @ObservationIgnored private var collecting = false
    @ObservationIgnored private var buffer = TimelineDiagBuffer()
    #if canImport(os)
    @ObservationIgnored private let logger = Logger(subsystem: "agents.anywhere", category: "timeline-diag")
    #endif

    /// Whether collection is on — the cheap pre-check call sites run before
    /// doing work only the log would need (a render-set scan, a dictionary).
    /// Reads the *unobserved* flag, so a body cannot invalidate on the toggle.
    var isCollecting: Bool { collecting }

    /// Static forwarders: call sites spell the type, not the singleton, and
    /// the autoclosure survives the hop (a disabled log still builds nothing).
    static var isCollecting: Bool { shared.isCollecting }

    static func record(_ kind: @autoclosure () -> TimelineDiagEvent.Kind) {
        shared.record(evaluating: kind)
    }

    private init() { refresh() }

    /// Re-reads the persisted toggle and the env override. Settings calls it
    /// when the switch moves; the facade reads them once at cold start.
    func refresh() {
        let forced = ProcessInfo.processInfo.environment["AA_TIMELINE_DIAG"] == "1"
        let stored = UserDefaults.standard.bool(forKey: Self.enabledKey)
        isEnabled = forced || stored
        collecting = isEnabled
        if !isEnabled { buffer.removeAll() }
    }

    /// The one call site. `kind` is an autoclosure: a disabled log evaluates
    /// nothing at all (the discipline that keeps the hot path free). Appends
    /// are synchronous — the one call site that runs inside a view body hops
    /// a runloop turn *before* calling in (see the store's slice note), so
    /// observed state is never written mid-update.
    func record(_ kind: @autoclosure () -> TimelineDiagEvent.Kind) {
        record(evaluating: kind)
    }

    private func record(evaluating kind: () -> TimelineDiagEvent.Kind) {
        guard collecting else { return }
        let value = kind()
        buffer.append(value, at: ProcessInfo.processInfo.systemUptime)
        revision &+= 1
        #if canImport(os)
        logger.notice("\(value.line(at: ProcessInfo.processInfo.systemUptime), privacy: .public)")
        #endif
    }

    /// The buffer's contents. Reading `revision` on the way out is what makes
    /// the call the panel's observation hook — the buffer itself is ignored,
    /// so an append costs one integer write and this one read per render.
    func snapshot() -> [TimelineDiagEvent] {
        _ = revision
        return buffer.events
    }

    func formatted() -> String { buffer.formatted() }
    func clear() { buffer.removeAll(); revision &+= 1 }
}

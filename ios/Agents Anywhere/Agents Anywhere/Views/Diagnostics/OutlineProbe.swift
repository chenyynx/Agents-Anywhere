import Foundation
import QuartzCore
import SwiftUI
import UIKit

/// Device-side measurements for the conversation outline sheet.
///
/// The sheet used to be invisible to the diagnostics trail: it opens and
/// closes, takes drags, and renders its own list, but every `kind` in the log
/// came from the timeline behind it. Two device reports (pp 2026-11-21) —
/// "拖动收键盘不顺" and "思考时大纲页滑动掉帧" — therefore could not be
/// checked against anything, and two rounds of fixes shipped on guesses.
///
/// This probe records, once per second while the sheet is open:
/// - frame cadence and hitches (> two 60 Hz frames), so the stutter is a
///   number rather than an impression;
/// - how often the sheet rebuilt its rows and what that cost, so a rebuild
///   storm (which would make scrolling stutter) is distinguishable from a
///   plain rendering cost;
/// - the runtime status, so a hitch that only appears while the agent runs
///   points at the streaming transcript behind the sheet rather than the
///   sheet's own list.
///
/// On state changes it records scroll phases (does the drag reach the list?),
/// keyboard transitions (does that drag actually dismiss the keyboard?) and
/// reload cost. Counts and timings only — never message text.
@MainActor
final class OutlineProbe: NSObject {
    static let shared = OutlineProbe()

    private var link: CADisplayLink?
    private var windowStart: CFTimeInterval = 0
    private var lastFrame: CFTimeInterval = 0
    private var frames = 0
    private var hitches = 0
    private var worstMs: Double = 0
    private var builds = 0
    private var buildMs: Double = 0
    private var rows = 0
    private var sessionID: String?
    private var openedAt: CFTimeInterval = 0
    private var isOpen = false

    // The display link targets this object through ObjC, so it must be an
    // NSObject; `private` keeps other callers on `shared`.
    private override init() { super.init() }

    // MARK: - Lifecycle

    /// The sheet appeared. Starting here (not in `init`) keeps the display
    /// link out of the app's launch path and out of every other screen.
    func begin(sessionID: String?, rows: Int, live: Int, cached: Int) {
        guard ClientDiagnosticsLog.shared.isEnabled else { return }
        end()
        self.sessionID = sessionID
        self.rows = rows
        runtimeStatus = "?"
        isOpen = true
        openedAt = CACurrentMediaTime()
        windowStart = openedAt
        lastFrame = 0
        frames = 0
        hitches = 0
        worstMs = 0
        builds = 0
        buildMs = 0
        record(
            kind: "outline.open",
            detail: [
                "rows": String(rows),
                "live": String(live),
                "cached": String(cached),
            ]
        )
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        // Measure at the panel's own ceiling; a hitch is a gap well past one
        // refresh at either 60 or 120 Hz, so the link rate only decides how
        // finely the gap is sampled.
        link.preferredFrameRateRange = CAFrameRateRange(
            minimum: 60, maximum: 120, preferred: 120
        )
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    /// The sheet went away (dismissed or the page itself was dismissed).
    func end() {
        guard isOpen else { return }
        link?.invalidate()
        link = nil
        isOpen = false
        flushWindow(force: true)
        record(
            kind: "outline.close",
            detail: [
                "openSec": String(format: "%.1f", CACurrentMediaTime() - openedAt),
                "rows": String(rows),
            ]
        )
        sessionID = nil
    }

    // MARK: - Measurements from the sheet

    /// One row's content build (`ConversationOutlineRowContentMaker.content`).
    /// Aggregated into the once-a-second frame line; a per-row log line would
    /// flood the trail.
    func noteContentBuild(ms: Double) {
        guard isOpen else { return }
        builds += 1
        buildMs += ms
    }

    /// The sheet rebuilt its entry list (a row id appeared or left).
    func noteReload(ms: Double, rows: Int, live: Int, cached: Int) {
        guard isOpen else { return }
        self.rows = rows
        record(
            kind: "outline.reload",
            detail: [
                "ms": String(format: "%.1f", ms),
                "rows": String(rows),
                "live": String(live),
                "cached": String(cached),
            ]
        )
    }

    /// The search field's keyboard appeared or went away. Paired with the
    /// `outline.scroll` line this says whether a downward drag reached the
    /// list and whether the keyboard followed it.
    func noteKeyboard(phase: String, height: Double) {
        guard isOpen else { return }
        record(
            kind: "outline.keyboard",
            detail: [
                "phase": phase,
                "height": String(format: "%.0f", height),
            ]
        )
    }

    /// A scroll phase change inside the sheet's list.
    func noteScroll(old: String, new: String) {
        guard isOpen else { return }
        record(
            kind: "outline.scroll",
            detail: ["from": old, "to": new]
        )
    }

    /// A row was chosen. Records whether the sheet closed from a search hit,
    /// so a keyboard that lingers past the close is readable as its own step
    /// (close without a following hide).
    func noteJump(searching: Bool) {
        guard isOpen else { return }
        record(
            kind: "outline.jump",
            detail: ["searching": searching ? "1" : "0"]
        )
    }

    // MARK: - Frame window

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        if lastFrame > 0 {
            let ms = (now - lastFrame) * 1000
            frames += 1
            // Two 60 Hz frames: a single dropped frame at 120 Hz reads as
            // ~16.7 ms, and ordinary scheduling noise must not count.
            if ms > 33.4 { hitches += 1 }
            if ms > worstMs { worstMs = ms }
        }
        lastFrame = now
        if now - windowStart >= 1 {
            flushWindow(force: false)
            windowStart = now
        }
    }

    private func flushWindow(force: Bool) {
        guard frames > 0 || builds > 0 else { return }
        let seconds = max(0.001, CACurrentMediaTime() - windowStart)
        record(
            kind: "outline.frame",
            detail: [
                "fps": String(format: "%.0f", Double(frames) / seconds),
                "hitches": String(hitches),
                "worstMs": String(format: "%.0f", worstMs),
                "builds": String(builds),
                "buildMs": String(format: "%.1f", buildMs),
                "rows": String(rows),
                "status": status(),
                "openSec": String(format: "%.0f", CACurrentMediaTime() - openedAt),
            ],
            force: force
        )
        frames = 0
        hitches = 0
        worstMs = 0
        builds = 0
        buildMs = 0
    }

    private var runtimeStatus = "?"

    /// The drawer status the frame line is filed under: a hitch that only
    /// shows up while the agent runs comes from the streaming transcript
    /// behind the sheet, not from the sheet's own list. The sheet hands this
    /// in from its own refresh loop, which already runs once a second.
    func noteStatus(_ value: String?) {
        guard isOpen else { return }
        runtimeStatus = value ?? "?"
    }

    private func status() -> String { runtimeStatus }

    private func record(
        kind: String,
        detail: [String: String],
        force: Bool = false
    ) {
        ClientDiagnosticsLog.shared.record(
            kind: kind,
            sessionID: sessionID,
            detail: detail,
            dedupe: false,
            force: force
        )
    }
}

// MARK: - Scroll phase names

extension ScrollPhase {
    /// Stable names for the diagnostics trail; `String(describing:)` would
    /// print the enum's case name and change with the SDK.
    var outlineDiagnosticName: String {
        switch self {
        case .idle: return "idle"
        case .tracking: return "tracking"
        case .interacting: return "interacting"
        case .decelerating: return "decelerating"
        case .animating: return "animating"
        }
    }
}

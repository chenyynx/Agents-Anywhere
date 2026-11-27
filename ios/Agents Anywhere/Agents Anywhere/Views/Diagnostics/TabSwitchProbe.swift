import Foundation
import QuartzCore
import UIKit

/// Frame cadence around one bottom-tab switch, plus an idle control sample.
///
/// "切 tab 卡" has to be a number before it can be fixed. The switch already
/// logs when the bar wrote the selection and when the pages committed it, but
/// neither line can show whether the transition itself dropped frames: a
/// display link samples the main thread across the whole window and reports
/// the longest gap at the end. `worstAt` says *when* that gap started (from
/// the tap), which separates a stall inside the tap/transition (near 0 ms)
/// from one at the transition's tail (200–400 ms); the idle window samples a
/// quiet stretch with no switch so a stall that also happens when nobody is
/// switching is not misread as the tab bar's fault.
///
/// One line per switch and one per idle window (`shell.tabs.frame`).
@MainActor
final class TabSwitchProbe: NSObject {
    static let shared = TabSwitchProbe()

    /// Long enough to cover the bar's transition plus the page commit that
    /// used to land at ~0.5 s (b1660). Shorter windows hid the tail.
    private static let window: CFTimeInterval = 0.7
    /// A scroll window is longer than a tab tap: the reader keeps dragging
    /// after the switch-settling tail would have ended.
    private static let scrollWindow: CFTimeInterval = 2.0
    private var windowLength: CFTimeInterval = TabSwitchProbe.window
    /// Two 60 Hz frames: one dropped frame at 120 Hz reads as ~16.7 ms and
    /// ordinary scheduling noise must not count.
    private static let hitchMs: Double = 33.4
    /// Quiet time after a switch window before the idle control sample runs.
    /// Shorter windows overlap the transition's own tail; longer ones rarely
    /// fit between the reader's taps.
    private static let idleDelay: TimeInterval = 2.0

    private var link: CADisplayLink?
    private var startedAt: CFTimeInterval = 0
    private var lastTick: CFTimeInterval = 0
    private var frames = 0
    private var hitches = 0
    private var worstMs: Double = 0
    /// Milliseconds from the window start to the beginning of the worst gap.
    private var worstAtMs: Double = 0
    /// Every gap above `hitchMs` inside this window, at its absolute start
    /// time (the display link's `timestamp` base). The sampler's `MH` lines
    /// use them to name what the main thread was doing *inside* each gap.
    private var hitchSamples: [(at: TimeInterval, ms: Double)] = []
    private var tab = ""
    /// The kind this window reports under: `shell.tabs.frame` for tab
    /// switches, `keyboard.frame` for the keyboard's show/hide windows.
    private var kind = "shell.tabs.frame"
    private var isIdleWindow = false
    private var idleWorkItem: DispatchWorkItem?

    // The display link targets this object through ObjC; `private` keeps
    // callers on `shared`.
    private override init() { super.init() }

    /// A selection write the bar made. Called from the binding's setter, so
    /// the window starts at the tap, not at the first SwiftUI update.
    func begin(tab: String, kind: String = "shell.tabs.frame") {
        guard ClientDiagnosticsLog.shared.isEnabled else { return }
        // A second switch inside the 0.7 s window used to cancel the first
        // one silently, so quick taps (and every switch to a light tab
        // between two chat taps) left no frame data. Log the partial window;
        // it is still the only measurement of that switch.
        if link != nil { finish(partial: true) }
        idleWorkItem?.cancel()
        idleWorkItem = nil
        startWindow(tab: tab, kind: kind, idle: false)
    }

    /// A scroll gesture on a page that is already visible. Probe builds use
    /// this to catch scroll hitches that `shell.tabs.frame` cannot see: its
    /// windows only bracket tab taps.
    func beginScroll(tab: String) {
        guard ClientDiagnosticsLog.shared.isEnabled else { return }
        if link != nil { finish(partial: true) }
        idleWorkItem?.cancel()
        idleWorkItem = nil
        startWindow(tab: tab, kind: "scroll.frame", idle: false,
                    duration: Self.scrollWindow)
    }

    /// Mark a phase inside the current switch window. No-op when no switch is
    /// in flight, so call sites can mark unconditionally (page appear also
    /// fires on a session open).
    func mark(_ name: String, extra: [String: String] = [:]) {
        guard link != nil, ClientDiagnosticsLog.shared.isEnabled else { return }
        var detail = extra
        detail["mark"] = name
        detail["t"] = String(format: "%.0f", (CACurrentMediaTime() - startedAt) * 1000)
        detail["tab"] = tab
        ClientDiagnosticsLog.shared.record(
            kind: "shell.tabs.phase",
            detail: detail,
            dedupe: false)
    }

    private func startWindow(tab: String, kind: String = "shell.tabs.frame", idle: Bool,
                             duration: CFTimeInterval = TabSwitchProbe.window) {
        link?.invalidate()
        self.tab = tab
        self.kind = kind
        isIdleWindow = idle
        windowLength = duration
        startedAt = CACurrentMediaTime()
#if AA_TIMELINE_PROBE
        // Probe builds sample the main thread's stack through the same
        // window. b1663 proved the stall starts at the tap (worstAt ≈ 0)
        // while every piece we timed stayed under its threshold, so only a
        // stack can name the code that owns the 200–500 ms. b1694 showed the
        // tick-driven window stops before the stall (the freeze *is* the
        // missing ticks): record a fixed-length burst instead.
        if !idle {
            MainThreadStackSampler.shared.beginBurst(
                seconds: duration + 0.2)
        }
#endif
        // Measure from the window start: a main thread that blocks inside the
        // tap handler must show up as the first gap, not be skipped.
        lastTick = startedAt
        frames = 0
        hitches = 0
        worstMs = 0
        worstAtMs = 0
        hitchSamples.removeAll(keepingCapacity: true)
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(
            minimum: 60, maximum: 120, preferred: 120
        )
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        let ms = (now - lastTick) * 1000
        frames += 1
        if ms > Self.hitchMs {
            hitches += 1
            // Keep the gap's start: the sampler scans its samples inside
            // [start, start + gap] to name the owning stack.
            if hitchSamples.count < 8 {
                hitchSamples.append((at: lastTick, ms: ms))
            }
        }
        if ms > worstMs {
            worstMs = ms
            worstAtMs = (lastTick - startedAt) * 1000
        }
        lastTick = now
#if AA_TIMELINE_PROBE
        // Keep the sampler recording for the whole window: it pauses 0.25 s
        // after the last activity, and the stall can start late.
        if !isIdleWindow {
            MainThreadStackSampler.shared.noteActivity(scrolling: true)
        }
#endif
        if now - startedAt >= windowLength { finish() }
    }

    private func finish(partial: Bool = false) {
        guard link != nil else { return }
        link?.invalidate()
        link = nil
        let seconds = max(0.001, CACurrentMediaTime() - startedAt)
        var detail = [
            "tab": isIdleWindow ? "idle" : tab,
            "frames": String(frames),
            "hitches": String(hitches),
            "worstMs": String(format: "%.0f", worstMs),
            "worstAt": String(format: "%.0f", worstAtMs),
            "ms": String(format: "%.0f", seconds * 1000),
        ]
        // The switch was followed by another tap before the window closed:
        // the numbers describe a shorter window, not a full one.
        if partial { detail["partial"] = "1" }
        ClientDiagnosticsLog.shared.record(kind: kind, detail: detail, dedupe: false)
#if AA_TIMELINE_PROBE
        // A tab switch has to own a 200–500 ms freeze before its stack is
        // worth the export. A Devices scroll is a different budget: the
        // reader feels 40–60 ms hitches, and those never cross the switch's
        // 80 ms line, so that window would export no stack at all.
        let stackThreshold: Double = kind == "scroll.frame" ? 35 : 80
        // A scroll window is cut short by the next phase change
        // (interacting → decelerating re-arms it). The partial window still
        // covers the stretch that hitched, so keep its stack too.
        let keepsPartial = kind == "scroll.frame"
        if !isIdleWindow, worstMs >= stackThreshold, !partial || keepsPartial {
            // `reportLines` closes the session and waits briefly for the
            // sampling thread; the decoded report names the stacks that
            // owned the stall (our frames keep their symbols because a
            // probe build disables stripping). The hitch timestamps let its
            // MH lines name the app/leaf inside each gap.
            let hitches: [(at: TimeInterval, ms: Int)] = hitchSamples.map {
                (at: $0.at, ms: Int($0.ms))
            }
            let report = MainThreadStackSampler.shared
                .reportLines(hitches: hitches)
                .joined(separator: "\n")
            ClientDiagnosticsLog.shared.record(
                kind: "tab.stack",
                detail: ["tab": tab,
                         "kind": kind,
                         "worstMs": String(format: "%.0f", worstMs),
                         "report": report],
                dedupe: false)
        } else if !isIdleWindow, !partial {
            MainThreadStackSampler.shared.clear()
        }
#endif
        if !isIdleWindow, !partial, kind == "shell.tabs.frame" { scheduleIdleWindow() }
    }

    /// The control sample: a switch window just closed and the reader has not
    /// tapped another tab. If the same stall shows up here, it belongs to the
    /// app's steady-state work, not to the tab transition.
    private func scheduleIdleWindow() {
        idleWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.link == nil else { return }
            self.startWindow(tab: "idle", idle: true)
        }
        idleWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.idleDelay, execute: item)
    }
}

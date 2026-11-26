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
        idleWorkItem?.cancel()
        idleWorkItem = nil
        startWindow(tab: tab, kind: kind, idle: false)
    }

    private func startWindow(tab: String, kind: String = "shell.tabs.frame", idle: Bool) {
        link?.invalidate()
        self.tab = tab
        self.kind = kind
        isIdleWindow = idle
        startedAt = CACurrentMediaTime()
#if AA_TIMELINE_PROBE
        // Probe builds sample the main thread's stack through the same
        // window. b1663 proved the stall starts at the tap (worstAt ≈ 0)
        // while every piece we timed stayed under its threshold, so only a
        // stack can name the code that owns the 200–500 ms.
        if !idle {
            MainThreadStackSampler.shared.clear()
            MainThreadStackSampler.shared.noteActivity(scrolling: true)
        }
#endif
        // Measure from the window start: a main thread that blocks inside the
        // tap handler must show up as the first gap, not be skipped.
        lastTick = startedAt
        frames = 0
        hitches = 0
        worstMs = 0
        worstAtMs = 0
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
        if ms > Self.hitchMs { hitches += 1 }
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
        if now - startedAt >= Self.window { finish() }
    }

    private func finish() {
        guard link != nil else { return }
        link?.invalidate()
        link = nil
        let seconds = max(0.001, CACurrentMediaTime() - startedAt)
        ClientDiagnosticsLog.shared.record(
            kind: kind,
            detail: [
                "tab": isIdleWindow ? "idle" : tab,
                "frames": String(frames),
                "hitches": String(hitches),
                "worstMs": String(format: "%.0f", worstMs),
                "worstAt": String(format: "%.0f", worstAtMs),
                "ms": String(format: "%.0f", seconds * 1000),
            ],
            dedupe: false)
#if AA_TIMELINE_PROBE
        if !isIdleWindow {
            if worstMs > 80 {
                // `reportLines` closes the session and waits briefly for the
                // sampling thread; the decoded report names the stacks that
                // owned the stall (our frames keep their symbols because a
                // probe build disables stripping).
                let report = MainThreadStackSampler.shared
                    .reportLines(hitches: [])
                    .joined(separator: "\n")
                ClientDiagnosticsLog.shared.record(
                    kind: "tab.stack",
                    detail: ["tab": tab,
                             "worstMs": String(format: "%.0f", worstMs),
                             "report": report],
                    dedupe: false)
            } else {
                MainThreadStackSampler.shared.clear()
            }
        }
#endif
        if !isIdleWindow, kind == "shell.tabs.frame" { scheduleIdleWindow() }
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

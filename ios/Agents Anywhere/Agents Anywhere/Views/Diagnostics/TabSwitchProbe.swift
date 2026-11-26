import Foundation
import QuartzCore
import UIKit

/// Frame cadence around one bottom-tab switch.
///
/// "切 tab 卡" has to be a number before it can be fixed. The switch already
/// logs when the bar wrote the selection and when the pages committed it, but
/// neither line can show whether the transition itself dropped frames: a
/// display link samples the main thread across the whole window and reports
/// the longest gap at the end. A clean cadence with a late `shell.tabs.active`
/// points at the activation policy; a long `worstMs` points at main-thread
/// work inside the transition.
///
/// One line per switch (`shell.tabs.frame`), written after the window closes.
@MainActor
final class TabSwitchProbe: NSObject {
    static let shared = TabSwitchProbe()

    /// Long enough to cover the bar's transition plus the page commit that
    /// used to land at ~0.5 s (b1660). Shorter windows hid the tail.
    private static let window: CFTimeInterval = 0.7
    /// Two 60 Hz frames: one dropped frame at 120 Hz reads as ~16.7 ms and
    /// ordinary scheduling noise must not count.
    private static let hitchMs: Double = 33.4

    private var link: CADisplayLink?
    private var startedAt: CFTimeInterval = 0
    private var lastTick: CFTimeInterval = 0
    private var frames = 0
    private var hitches = 0
    private var worstMs: Double = 0
    private var tab = ""

    // The display link targets this object through ObjC; `private` keeps
    // callers on `shared`.
    private override init() { super.init() }

    /// A selection write the bar made. Called from the binding's setter, so
    /// the window starts at the tap, not at the first SwiftUI update.
    func begin(tab: String) {
        guard ClientDiagnosticsLog.shared.isEnabled else { return }
        link?.invalidate()
        self.tab = tab
        startedAt = CACurrentMediaTime()
        // Measure from the tap itself: a main thread that blocks inside the
        // tap handler must show up as the first gap, not be skipped.
        lastTick = startedAt
        frames = 0
        hitches = 0
        worstMs = 0
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(
            minimum: 60, maximum: 120, preferred: 120
        )
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        if lastTick > 0 {
            let ms = (now - lastTick) * 1000
            frames += 1
            if ms > Self.hitchMs { hitches += 1 }
            if ms > worstMs { worstMs = ms }
        }
        lastTick = now
        if now - startedAt >= Self.window { finish() }
    }

    private func finish() {
        guard link != nil else { return }
        link?.invalidate()
        link = nil
        let seconds = max(0.001, CACurrentMediaTime() - startedAt)
        ClientDiagnosticsLog.shared.record(
            kind: "shell.tabs.frame",
            detail: [
                "tab": tab,
                "frames": String(frames),
                "hitches": String(hitches),
                "worstMs": String(format: "%.0f", worstMs),
                "ms": String(format: "%.0f", seconds * 1000),
            ],
            dedupe: false)
    }
}

import SwiftUI
import OSLog

/// Throwaway diagnostic instrument (2026-10-02, "follow" bug round 5).
/// The four fix rounds were all verifiable locally and all failed on the
/// device, so the dead link lives in a layer this machine cannot observe:
/// the keyboard notification's parse, the follow policy's guards, the
/// per-frame sample stream, or whether the scroll command actually applies.
/// This probe records that chain on screen so one device screenshot names
/// the dead link. It changes no behavior and ships only in the probe build;
/// remove it (and its hook lines in `ChatTimelineView`) after the diagnosis.
@MainActor @Observable
final class TimelineFollowProbe {
    /// Rolling event log, oldest first; the HUD shows the last few lines.
    private(set) var lines: [String] = []
    /// Per-sample line, refreshed every geometry sample during windows.
    private(set) var live = "live: –"

    private var samples = 0
    private let log = Logger(subsystem: "agents.anywhere", category: "follow-probe")

    private func append(_ line: String) {
        lines.append(line)
        if lines.count > 8 { lines.removeFirst(lines.count - 8) }
        log.notice("probe \(line, privacy: .public)")
    }

    /// The raw keyboard notification, before any of our parsing: the frames
    /// make an inverted or unchanged direction visible at a glance.
    func recordKeyboardNotification(_ name: String, userInfo: [AnyHashable: Any]) {
        let begin = (userInfo[UIResponder.keyboardFrameBeginUserInfoKey] as? NSValue)?.cgRectValue
        let end = (userInfo[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
        func y(_ r: CGRect?) -> String { r.map { String(format: "%.0f", $0.origin.y) } ?? "nil" }
        let duration = (userInfo["UIKeyboardAnimationDurationUserInfoKey"] as? NSNumber)?.doubleValue ?? -1
        append("\(name): y \(y(begin))→\(y(end)) dur=\(String(format: "%.2f", duration))")
    }

    /// The follow translation issued for this transition: which way, the
    /// keyboard height it moved by, and the offsets it moved between.
    func recordTranslation(direction: TimelineKeyboardEvent.Direction, height: CGFloat, from: CGFloat, to: CGFloat) {
        append("translate \(String(describing: direction)) h=\(String(format: "%.0f", height)) offset \(String(format: "%.0f", from))→\(String(format: "%.0f", to))")
    }

    func recordWindowOpen(duration: TimeInterval) {
        samples = 0
        append("window open dur=\(String(format: "%.2f", duration))")
    }

    func recordWindowEnd(settled: Bool, recheck: String, gap: CGFloat, geoBottom: Bool, tailFlag: Bool) {
        append("window end: settle=\(settled) recheck=\(recheck) geoB=\(geoBottom) tailF=\(tailFlag) gap=\(String(format: "%.1f", gap)) samples=\(samples)")
    }

    private var lastGap: CGFloat = 0

    func recordSample(gap: CGFloat) {
        samples += 1
        lastGap = gap
        refreshLive()
    }

    private func refreshLive() {
        live = "live: gap=\(String(format: "%.1f", lastGap))pt samples=\(samples)"
    }
}

/// The probe's on-screen readout: a leaf view, so its per-sample refresh
/// re-rasterizes only these few text lines, never the timeline. Touches pass
/// straight through.
struct TimelineFollowProbeHUD: View {
    let probe: TimelineFollowProbe

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("FOLLOW PROBE · r1.3+probe")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
            Text(probe.live)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
            ForEach(probe.lines.indices, id: \.self) { index in
                Text(probe.lines[index]).font(.system(size: 9, design: .monospaced))
            }
        }
        .padding(6)
        .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 8))
        .foregroundStyle(.green)
        .frame(maxWidth: 330, alignment: .leading)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

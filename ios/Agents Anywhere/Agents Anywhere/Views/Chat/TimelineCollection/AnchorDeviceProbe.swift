#if AA_TIMELINE_PROBE
import SwiftUI
import UIKit

/// Device log for the C3 inset path. Every `applySafeAreaInsets` call records
/// the proxy value, the inherited animation duration, the scroll state and the
/// offset before/after; keyboard notifications are markers that group the
/// lines. The report is copied from the probe pill, so the empty-vs-text
/// composer difference can be read without a screen recording or a network
/// path.
///
/// Probe builds only (`-DAA_TIMELINE_PROBE`); the shipping app never compiles
/// this file.
@MainActor
final class AnchorDeviceProbe: NSObject {
    static let shared = AnchorDeviceProbe()

    private var lines: [String] = []
    private var observers: [NSObjectProtocol] = []
    private var started = CACurrentMediaTime()
    private var stateProvider: (() -> (resting: Bool, pinning: Bool, phase: String))?

    func attach(state: @escaping () -> (resting: Bool, pinning: Bool, phase: String)) {
        stateProvider = state
        guard observers.isEmpty else { return }
        for (name, label) in [(UIResponder.keyboardWillShowNotification, "willShow"),
                              (UIResponder.keyboardWillChangeFrameNotification, "willChangeFrame"),
                              (UIResponder.keyboardWillHideNotification, "willHide")] {
            let token = NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.append("-- \(label)") }
            }
            observers.append(token)
        }
    }

    func recordApply(proxyBottom: CGFloat, inherited: Double,
                     insetBefore: UIEdgeInsets, insetAfter: UIEdgeInsets,
                     offsetBefore: CGPoint, offsetAfter: CGPoint) {
        let state = stateProvider?() ?? (resting: false, pinning: false, phase: "?")
        let line = String(
            format: "px %.0f inh %.3f rest %d pin %d %@ in %.0f→%.0f off %.0f→%.0f",
            Double(proxyBottom), inherited, state.resting ? 1 : 0,
            state.pinning ? 1 : 0, state.phase,
            Double(insetBefore.bottom), Double(insetAfter.bottom),
            Double(offsetBefore.y), Double(offsetAfter.y))
        append(line)
    }

    /// Follow-motion events interleaved with the inset applies: a tail after
    /// the keyboard is gone is either one more inset animation or a Mover
    /// that started late, and the order tells them apart.
    func recordMover(_ event: String, spring: String, target: CGFloat,
                     position: CGFloat, motion: String) {
        let line = String(format: "mover %@ %@ tgt %.0f pos %.0f %@",
                          event, spring, Double(target), Double(position), motion)
        append(line)
    }

    /// Layout-side answers: whether the update callbacks run at all and what
    /// the follow answer was allowed to return.
    func recordLayout(_ line: String) {
        append("layout \(line)")
    }

    var report: String {
        let anchor = lines.isEmpty
            ? "（还没有记录：先在 Code 会话里点几次输入框）"
            : lines.joined(separator: "\n")
        // The product-side pill is the one users find first. Append the
        // structured timeline report here as well, so a copy from either
        // probe includes the history request/apply sequence.
        return anchor + "\n\n=== TIMELINE PROBE ===\n" + TimelineProbeStore.shared.report()
    }

    func clear() {
        lines.removeAll()
        started = CACurrentMediaTime()
        TimelineProbeStore.shared.reset()
    }

    private func append(_ line: String) {
        let stamp = String(format: "%6.2f", CACurrentMediaTime() - started)
        lines.append("\(stamp) \(line)")
        if lines.count > 60 { lines.removeFirst(lines.count - 60) }
    }
}

#endif

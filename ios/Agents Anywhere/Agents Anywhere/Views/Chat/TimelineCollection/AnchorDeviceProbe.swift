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

    var report: String {
        lines.isEmpty ? "（还没有记录：先在 Code 会话里点几次输入框）" : lines.joined(separator: "\n")
    }

    func clear() {
        lines.removeAll()
        started = CACurrentMediaTime()
    }

    private func append(_ line: String) {
        let stamp = String(format: "%6.2f", CACurrentMediaTime() - started)
        lines.append("\(stamp) \(line)")
        if lines.count > 60 { lines.removeFirst(lines.count - 60) }
    }
}

/// Probe-only pill: tap, read the anchor log, copy it.
struct AnchorProbeLogOverlay: View {
    @State private var showing = false
    @State private var text = ""

    var body: some View {
        Button("锚点日志") {
            text = AnchorDeviceProbe.shared.report
            showing = true
        }
        .font(.caption2.weight(.semibold))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.thinMaterial, in: Capsule())
        .sheet(isPresented: $showing) {
            NavigationStack {
                ScrollView {
                    Text(text)
                        .font(.caption2.monospaced())
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .textSelection(.enabled)
                }
                .navigationTitle("锚点日志")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("清空") {
                            AnchorDeviceProbe.shared.clear()
                            text = AnchorDeviceProbe.shared.report
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("复制") { UIPasteboard.general.string = text }
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
    }
}
#endif

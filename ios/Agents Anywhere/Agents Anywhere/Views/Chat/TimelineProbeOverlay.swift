#if AA_TIMELINE_PROBE
import SwiftUI
import UIKit

/// The probe's device half: a display link that feeds frame intervals to
/// `TimelineProbe` (ClientCore) and the floating readout that copies the
/// report. Compiled only into probe builds (`-DAA_TIMELINE_PROBE`).
struct TimelineProbeOverlay: View {
    @State private var expanded = false
    @State private var copied = false
    @State private var driver = ProbeDisplayLink()

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            Button {
                expanded.toggle()
            } label: {
                Text(expanded ? String(format: "%.0f FPS", TimelineProbe.shared.liveFPS) : "探针")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    Text(TimelineProbe.shared.report())
                        .font(.system(size: 10, design: .monospaced))
                        .textSelection(.enabled)
                    HStack(spacing: 12) {
                        Button(copied ? "已复制" : "复制报告") {
                            copyReport()
                            copied = true
                        }
                        Button("重置") { TimelineProbe.shared.reset() }
                    }
                    .font(.caption.weight(.medium))
                }
                .padding(10)
                .frame(maxWidth: 340, alignment: .leading)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .padding(.trailing, 8)
        .onAppear {
            TimelineProbe.shared.nominalInterval = 1.0 / Double(max(1, UIScreen.main.maximumFramesPerSecond))
            TimelineProbe.shared.isEnabled = true
            driver.start { interval, timestamp in
                TimelineProbe.shared.recordFrame(interval: interval, at: timestamp)
            }
        }
    }

    private func copyReport() {
        let text = TimelineProbe.shared.report()
        UIPasteboard.general.string = text
        if let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("timeline-probe.txt") {
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

/// CADisplayLink needs an ObjC selector target; this keeps the probe free of
/// NSObject inheritance at the call site.
private final class ProbeDisplayLink {
    private var link: CADisplayLink?
    private var onFrame: ((Double, CFTimeInterval) -> Void)?
    private var last: CFTimeInterval = 0

    @MainActor
    func start(_ onFrame: @escaping (Double, CFTimeInterval) -> Void) {
        guard link == nil else { return }
        self.onFrame = onFrame
        let link = CADisplayLink(target: ProbeDisplayLinkTarget(self), selector: #selector(ProbeDisplayLinkTarget.step(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    fileprivate func handle(_ timestamp: CFTimeInterval) {
        defer { last = timestamp }
        guard last > 0 else { return }
        onFrame?(timestamp - last, timestamp)
    }
}

private final class ProbeDisplayLinkTarget: NSObject {
    weak var owner: ProbeDisplayLink?

    init(_ owner: ProbeDisplayLink) {
        self.owner = owner
    }

    @objc func step(_ link: CADisplayLink) {
        MainActor.assumeIsolated {
            owner?.handle(link.timestamp)
        }
    }
}
#endif

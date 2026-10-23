#if AA_TIMELINE_PROBE
import SwiftUI
import UIKit

/// The probe's device half, compiled only into `-DAA_TIMELINE_PROBE` builds.
///
/// Nothing runs until the reader taps 探针. The first probe version started a
/// CADisplayLink on appear and published per-frame values through an
/// `@Observable` that this overlay read, so SwiftUI rebuilt the card — and
/// rebuilt `report()` — on every frame; on device that froze the session view.
/// Here a tap opens a fixed 30 s window (tap again to stop early), the window
/// stops itself, and the display link is invalidated the moment it ends or the
/// view disappears. While idle the overlay only draws a capsule.
struct TimelineProbeOverlay: View {
    @State private var phase: Phase = .idle
    @State private var reportText = ""
    @State private var copied = false
    @State private var driver = ProbeDisplayLink()
    @State private var windowTask: Task<Void, Never>?

    private enum Phase { case idle, measuring, done }

    private static let windowSeconds = 30

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            Button(action: tap) {
                Text(label)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            if phase != .idle {
                VStack(alignment: .leading, spacing: 8) {
                    Text(reportText)
                        .font(.system(size: 10, design: .monospaced))
                        .textSelection(.enabled)
                    HStack(spacing: 12) {
                        if phase == .done {
                            Button(copied ? "已复制" : "复制报告") {
                                copyReport()
                                copied = true
                            }
                        }
                        Button("重置") {
                            TimelineProbe.shared.reset()
                            if phase == .done { reportText = TimelineProbe.shared.report() }
                        }
                    }
                    .font(.caption.weight(.medium))
                }
                .padding(10)
                .frame(maxWidth: 340, alignment: .leading)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .padding(.trailing, 8)
        .onDisappear {
            windowTask?.cancel()
            windowTask = nil
            driver.stop()
            TimelineProbe.shared.stopSampling()
        }
    }

    private var label: String {
        switch phase {
        case .idle: return "探针"
        case .measuring: return "测量中…点此停止"
        case .done: return "再测一次"
        }
    }

    private func tap() {
        switch phase {
        case .idle, .done: start()
        case .measuring: stop()
        }
    }

    private func start() {
        copied = false
        TimelineProbe.shared.startSampling(fps: UIScreen.main.maximumFramesPerSecond)
        reportText = "测量中…上下滑 \(Self.windowSeconds) 秒，或再点一次提前结束"
        driver.start { interval, timestamp in
            TimelineProbe.shared.recordFrame(interval: interval, at: timestamp)
        }
        phase = .measuring
        windowTask?.cancel()
        windowTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(Self.windowSeconds))
            guard !Task.isCancelled else { return }
            stop()
        }
    }

    private func stop() {
        windowTask?.cancel()
        windowTask = nil
        driver.stop()
        TimelineProbe.shared.stopSampling()
        reportText = TimelineProbe.shared.report()
        phase = .done
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

/// Owns the CADisplayLink for one measurement window. Stops idempotently, so
/// the window end and `onDisappear` can both call it.
@MainActor
private final class ProbeDisplayLink {
    private var link: CADisplayLink?
    private var onFrame: ((Double, CFTimeInterval) -> Void)?
    private var last: CFTimeInterval = 0

    func start(_ onFrame: @escaping (Double, CFTimeInterval) -> Void) {
        guard link == nil else { return }
        self.onFrame = onFrame
        last = 0
        let link = CADisplayLink(target: ProbeDisplayLinkTarget(self), selector: #selector(ProbeDisplayLinkTarget.step(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
        onFrame = nil
        last = 0
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

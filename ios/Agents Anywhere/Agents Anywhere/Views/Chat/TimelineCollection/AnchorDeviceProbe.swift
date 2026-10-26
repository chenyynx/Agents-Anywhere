#if AA_TIMELINE_PROBE
import SwiftUI
import UIKit

/// Device probe for the C3 inset path: records every `applySafeAreaInsets`
/// call (proxy value, inherited animation duration, scroll state, offset
/// before/after) plus a per-frame trace across a keyboard transition, and
/// uploads the batch once things go quiet. Probe builds only
/// (`-DAA_TIMELINE_PROBE`); the shipping app never compiles this file.
@MainActor
final class AnchorDeviceProbe: NSObject {
    static let shared = AnchorDeviceProbe()
    private static let endpoint = URL(string: "https://00ff19edec77f7.lhr.life/p/f5c4f75a1ae9c35cae0a7c25/anchor")!

    private struct Apply: Codable {
        var t: Double
        var proxyBottom: Double
        var inherited: Double
        var resting: Bool
        var pinning: Bool
        var phase: String
        var insetBefore: Double
        var insetAfter: Double
        var offsetBefore: Double
        var offsetAfter: Double
    }

    private struct Frame: Codable {
        var t: Double
        var offset: Double
        var insetBottom: Double
        var adjustedBottom: Double
        var resting: Bool
        var phase: String
    }

    private enum Event: Codable {
        case apply(Apply)
        case frame(Frame)
        case marker(name: String, t: Double)

        private enum CodingKeys: String, CodingKey { case kind, apply, frame, name, t }
        private enum Kind: String, Codable { case apply, frame, marker }

        func encode(to encoder: Encoder) throws {
            var box = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .apply(let value):
                try box.encode(Kind.apply, forKey: .kind)
                try box.encode(value, forKey: .apply)
            case .frame(let value):
                try box.encode(Kind.frame, forKey: .kind)
                try box.encode(value, forKey: .frame)
            case .marker(let name, let t):
                try box.encode(Kind.marker, forKey: .kind)
                try box.encode(name, forKey: .name)
                try box.encode(t, forKey: .t)
            }
        }

        init(from decoder: Decoder) throws {
            let box = try decoder.container(keyedBy: CodingKeys.self)
            switch try box.decode(Kind.self, forKey: .kind) {
            case .apply: self = .apply(try box.decode(Apply.self, forKey: .apply))
            case .frame: self = .frame(try box.decode(Frame.self, forKey: .frame))
            case .marker:
                self = .marker(name: try box.decode(String.self, forKey: .name),
                               t: try box.decode(Double.self, forKey: .t))
            }
        }
    }

    private struct Payload: Codable {
        var startedAt: Double
        var events: [Event]
    }

    private weak var scrollView: UICollectionView?
    private var stateProvider: (() -> (resting: Bool, pinning: Bool, phase: String))?
    private var events: [Event] = []
    private var link: CADisplayLink?
    private var linkDeadline: CFTimeInterval = 0
    private var flushWork: DispatchWorkItem?
    private var started = CACurrentMediaTime()
    private var uploadInFlight = false

    func attach(_ view: UICollectionView,
                state: @escaping () -> (resting: Bool, pinning: Bool, phase: String)) {
        scrollView = view
        stateProvider = state
        guard observers.isEmpty else { return }
        for (name, label) in [(UIResponder.keyboardWillShowNotification, "willShow"),
                              (UIResponder.keyboardWillChangeFrameNotification, "willChangeFrame"),
                              (UIResponder.keyboardWillHideNotification, "willHide")] {
            let token = NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.keyboard(label) }
            }
            observers.append(token)
        }
    }

    private var observers: [NSObjectProtocol] = []

    func recordApply(proxyBottom: CGFloat, inherited: Double,
                     insetBefore: UIEdgeInsets, insetAfter: UIEdgeInsets,
                     offsetBefore: CGPoint, offsetAfter: CGPoint) {
        let state = stateProvider?() ?? (resting: false, pinning: false, phase: "?")
        events.append(.apply(Apply(t: now, proxyBottom: Double(proxyBottom),
                                   inherited: inherited, resting: state.resting,
                                   pinning: state.pinning, phase: state.phase,
                                   insetBefore: Double(insetBefore.bottom),
                                   insetAfter: Double(insetAfter.bottom),
                                   offsetBefore: Double(offsetBefore.y),
                                   offsetAfter: Double(offsetAfter.y))))
        scheduleFlush()
    }

    private func keyboard(_ name: String) {
        events.append(.marker(name: name, t: now))
        linkDeadline = CACurrentMediaTime() + 1.5
        if link == nil {
            let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
            link.add(to: .main, forMode: .common)
            self.link = link
        }
        scheduleFlush()
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard let view = scrollView else {
            link.invalidate()
            self.link = nil
            return
        }
        let state = stateProvider?() ?? (resting: false, pinning: false, phase: "?")
        events.append(.frame(Frame(t: now, offset: Double(view.contentOffset.y),
                                   insetBottom: Double(view.contentInset.bottom),
                                   adjustedBottom: Double(view.adjustedContentInset.bottom),
                                   resting: state.resting, phase: state.phase)))
        if CACurrentMediaTime() >= linkDeadline {
            link.invalidate()
            self.link = nil
        }
    }

    private var now: Double { CACurrentMediaTime() - started }

    private func scheduleFlush() {
        flushWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in await self?.upload() }
        }
        flushWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
    }

    private func upload() async {
        guard !uploadInFlight, !events.isEmpty else { return }
        uploadInFlight = true
        defer { uploadInFlight = false }
        let payload = Payload(startedAt: started, events: events)
        events.removeAll()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(payload) else { return }
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.httpBody = data
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10
        _ = try? await URLSession.shared.data(for: request)
    }
}
#endif

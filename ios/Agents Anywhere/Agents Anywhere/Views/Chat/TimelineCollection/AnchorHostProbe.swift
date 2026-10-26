#if DEBUG
import SwiftUI
import UIKit

/// Headless probe for the transcript's safe-area delivery.
///
/// It answers the one question the static evidence cannot: in the page's
/// `safeAreaBar` host, does `GeometryProxy.safeAreaInsets` include the bar, and
/// does it arrive per frame while a UIKit safe-area change animates? The
/// anchor model reads the proxy exactly this way, so a jump-only delivery
/// would invalidate that read point.
///
/// Launched with `aa-anchor-probe` in a simulator; writes
/// `Documents/anchor-probe.json` for the workflow to print. The probe first
/// tries a real software keyboard (a hidden field becomes first responder) and
/// falls back to an animated `additionalSafeAreaInsets` change when the
/// simulator keeps the hardware keyboard attached.
@MainActor
final class AnchorHostProbeModel: NSObject, ObservableObject {
    static let launchArgument = "aa-anchor-probe"
    static let resultFileName = "anchor-probe.json"
    static let barHeight: CGFloat = 80

    struct Delivery: Codable {
        var phase: String
        var t: Double
        var bottom: Double
        var inherited: Double
    }

    struct Frame: Codable {
        var phase: String
        var t: Double
        var hostBottom: Double
        var proxyBottom: Double
    }

    struct Marker: Codable {
        var t: Double
        var name: String
    }

    struct Report: Codable {
        var completed = false
        var barHeight: Double = Double(AnchorHostProbeModel.barHeight)
        var outerProxyBottom: Double = -1
        var innerProxyBottom: Double = -1
        var hostSafeBottom: Double = -1
        var hostSafeBottomLate: Double = -1
        var keyboardAppeared = false
        var deliveries: [Delivery] = []
        var frames: [Frame] = []
        var markers: [Marker] = []
        var notes: [String] = []
    }

    private(set) var report = Report()
    var textField: UITextField?

    private var host: UIViewController?
    private var link: CADisplayLink?
    private var phase = "idle"
    private var innerBottom: CGFloat = -1
    private var startedAt = CACurrentMediaTime()
    private var didStart = false
    private var observers: [NSObjectProtocol] = []

    /// The C3 read point: the proxy of the GeometryReader inside the bar's
    /// content. Records every delivery, so the JSON shows whether the value
    /// stepped once or travelled with the animation.
    func inner(_ insets: EdgeInsets) {
        innerBottom = insets.bottom
        report.innerProxyBottom = Double(insets.bottom)
        guard report.deliveries.count < 900 else { return }
        report.deliveries.append(Delivery(phase: phase,
                                          t: CACurrentMediaTime() - startedAt,
                                          bottom: Double(insets.bottom),
                                          inherited: UIView.inheritedAnimationDuration))
    }

    /// The product's current read point (the page GeometryReader outside the
    /// bar). The difference `inner - outer` is the bar's contribution.
    func outer(_ insets: EdgeInsets) {
        report.outerProxyBottom = Double(insets.bottom)
    }

    func start() {
        guard !didStart else { return }
        didStart = true
        startedAt = CACurrentMediaTime()
        startLink()
        observeKeyboard()
        // The window/root view controller does not exist until the first
        // layout; resolve after it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            self.resolveHost()
            self.report.hostSafeBottom = Double(self.host?.view.safeAreaInsets.bottom ?? -1)
            self.note("host=\(self.host.map { String(describing: type(of: $0)) } ?? "nil")"
                + " outer=\(self.report.outerProxyBottom)"
                + " inner=\(self.report.innerProxyBottom)")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.tryRealKeyboard()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak self] in
            guard let self, !self.report.keyboardAppeared else { return }
            self.animateAdditional(up: true)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.6) { [weak self] in
            guard let self else { return }
            if self.report.keyboardAppeared {
                self.textField?.resignFirstResponder()
            } else {
                self.animateAdditional(up: false)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            self?.finish()
        }
    }

    private func resolveHost() {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        host = scenes.flatMap(\.windows).first(where: { $0.isKeyWindow })?.rootViewController
            ?? scenes.flatMap(\.windows).first?.rootViewController
    }

    private func startLink() {
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        let maxFPS = max(60, UIScreen.main.maximumFramesPerSecond)
        link.preferredFrameRateRange = CAFrameRateRange(
            minimum: Float(maxFPS) / 2, maximum: Float(maxFPS), preferred: 0)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    private func observeKeyboard() {
        let names: [(Notification.Name, String)] = [
            (UIResponder.keyboardWillShowNotification, "willShow"),
            (UIResponder.keyboardWillChangeFrameNotification, "willChangeFrame"),
            (UIResponder.keyboardWillHideNotification, "willHide"),
        ]
        for (name, label) in names {
            let token = NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    if label == "willShow" { self.report.keyboardAppeared = true }
                    self.report.markers.append(Marker(
                        t: CACurrentMediaTime() - self.startedAt, name: label))
                }
            }
            observers.append(token)
        }
    }

    private func tryRealKeyboard() {
        guard let field = textField else {
            note("no text field")
            return
        }
        phase = "keyboard"
        let became = field.becomeFirstResponder()
        note("becomeFirstResponder=\(became) isFirstResponder=\(field.isFirstResponder)")
    }

    /// Stand-in for the system keyboard's animated safe area: UIKit animates
    /// `additionalSafeAreaInsets` the same way it animates the keyboard safe
    /// area, and the proxy either follows per frame or steps once.
    private func animateAdditional(up: Bool) {
        guard let host else {
            note("no hosting controller for additional inset")
            return
        }
        phase = up ? "rise" : "fall"
        note("additional \(phase) from host=\(host.view.safeAreaInsets.bottom)")
        UIView.animate(withDuration: 0.25, delay: 0,
                       options: [.beginFromCurrentState, .curveEaseInOut]) {
            host.additionalSafeAreaInsets.bottom = up ? 300 : 0
        } completion: { [weak self] _ in
            guard let self else { return }
            self.report.hostSafeBottomLate = Double(host.view.safeAreaInsets.bottom)
            self.note("additional \(self.phase) done host=\(host.view.safeAreaInsets.bottom)")
        }
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard report.frames.count < 900 else { return }
        report.frames.append(Frame(phase: phase,
                                   t: CACurrentMediaTime() - startedAt,
                                   hostBottom: Double(host?.view.safeAreaInsets.bottom ?? -1),
                                   proxyBottom: Double(innerBottom)))
    }

    private func note(_ text: String) {
        report.notes.append(text)
    }

    private func finish() {
        link?.invalidate()
        link = nil
        report.completed = true
        report.hostSafeBottomLate = Double(host?.view.safeAreaInsets.bottom ?? -1)
        note("deliveries=\(report.deliveries.count) frames=\(report.frames.count)")
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Self.resultFileName)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(report).write(to: url)
        } catch {
            NSLog("anchor-probe write failed: \(error)")
        }
        for token in observers { NotificationCenter.default.removeObserver(token) }
        observers.removeAll()
    }
}

struct AnchorHostProbeRootView: View {
    @StateObject private var model = AnchorHostProbeModel()

    var body: some View {
        // Outer proxy: the product's current read point, outside the bar.
        GeometryReader { outer in
            Group {
                // Inner proxy: the anchor model's read point, inside the bar's
                // content and outside the child's ignore.
                GeometryReader { inner in
                    ZStack {
                        Color.clear
                        ProbeTextField { model.textField = $0 }
                    }
                    .ignoresSafeArea([.container, .keyboard], edges: [.top, .bottom])
                    .onAppear { model.inner(inner.safeAreaInsets) }
                    .onChange(of: inner.safeAreaInsets) { _, value in
                        model.inner(value)
                    }
                }
            }
            .safeAreaBar(edge: .bottom, spacing: 0) {
                Color.clear.frame(height: AnchorHostProbeModel.barHeight)
            }
            .onAppear { model.outer(outer.safeAreaInsets) }
            .onChange(of: outer.safeAreaInsets) { _, value in
                model.outer(value)
            }
        }
        .onAppear { model.start() }
    }
}

private struct ProbeTextField: UIViewRepresentable {
    let onMake: (UITextField) -> Void

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        field.alpha = 0.01
        field.autocorrectionType = .no
        field.text = "probe"
        onMake(field)
        return field
    }

    func updateUIView(_ uiView: UITextField, context: Context) {}
}
#endif

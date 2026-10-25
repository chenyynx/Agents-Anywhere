import Observation
import SwiftUI
import UIKit

/// Feeds the official keyboard geometry into the Code composer.
///
/// The official Code page does not let the system safe area move the bar:
/// it reserves `max(keyboardHeight − restingInset, 0)` with
/// `.safeAreaPadding(.bottom:)` and animates that value with a fixed spring
/// (`ComposerKeyboardLayout`, EVIDENCE build 1.261005.20 `0x100d96370`).
@MainActor @Observable
final class ComposerKeyboardObserver {
    private(set) var padding: CGFloat = 0
    private(set) var animates = false

    private var keyboardHeight: CGFloat = 0
    private var restingInset: CGFloat = 0
    private var screenHeight: CGFloat = 0
    /// The hosting window, used to convert the screen-space keyboard frame
    /// into the window's own coordinates (iPad split view / Stage Manager).
    @ObservationIgnored weak var window: UIWindow?

    var animation: Animation? {
        guard animates else { return nil }
        return .interpolatingSpring(
            mass: ComposerKeyboardLayout.springMass,
            stiffness: ComposerKeyboardLayout.springStiffness,
            damping: ComposerKeyboardLayout.springDamping,
            initialVelocity: ComposerKeyboardLayout.springInitialVelocity
        )
    }

    /// `UIWindow.safeAreaInsets` is the hardware inset (home indicator); the
    /// keyboard is a separate layout guide, so it can be read at any time.
    func updateWindowMetrics(window: UIWindow) {
        self.window = window
        let height = window.bounds.height
        if screenHeight != height { screenHeight = height }
        let inset = max(0, window.safeAreaInsets.bottom)
        if restingInset != inset {
            restingInset = inset
            recompute()
        }
    }

    func handle(_ notification: Notification, isShow: Bool) {
        let userInfo = notification.userInfo ?? [:]
        let duration = (userInfo[UIKeyboardAnimationDurationUserInfoKey] as? NSNumber)?.doubleValue ?? 0
        if isShow {
            if let screenFrame = (userInfo[UIKeyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue {
                let frame: CGRect
                if let window {
                    frame = window.convert(screenFrame, from: window.screen.coordinateSpace)
                } else {
                    frame = screenFrame
                }
                let height = window?.bounds.height
                    ?? (screenHeight > 0 ? screenHeight : Self.hostingScreenHeight())
                let next = ComposerKeyboardLayout.keyboardHeight(
                    screenHeight: height, keyboardTop: frame.minY)
                if keyboardHeight != next { keyboardHeight = next }
            }
        } else if keyboardHeight != 0 {
            keyboardHeight = 0
        }
        let nextAnimates = ComposerKeyboardLayout.usesAnimation(duration: duration)
        if animates != nextAnimates { animates = nextAnimates }
        recompute()
    }

    private func recompute() {
        let next = ComposerKeyboardLayout.bottomPadding(
            keyboardHeight: keyboardHeight, restingInset: restingInset)
        if padding != next { padding = next }
    }

    /// Fallback for the first notification before the probe has attached the
    /// window. `UIWindowScene.screen` is the non-deprecated screen accessor.
    private static func hostingScreenHeight() -> CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.screen.bounds.height ?? 0
    }
}

/// The official Code page never moves with the system keyboard; the composer
/// bar reserves the height itself. Chat keeps the system behavior.
struct ComposerPageKeyboardIgnores: ViewModifier {
    let enabled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content.ignoresSafeArea(.keyboard, edges: .bottom)
        } else {
            content
        }
    }
}

/// Applies the Code composer's keyboard padding. Chat passes `enabled: false`
/// and keeps the system behavior untouched.
struct ComposerKeyboardPadding: ViewModifier {
    let enabled: Bool
    @State private var observer = ComposerKeyboardObserver()

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content
                .safeAreaPadding(.bottom, observer.padding)
                .animation(observer.animation, value: observer.padding)
                .onReceive(NotificationCenter.default.publisher(
                    for: UIResponder.keyboardWillShowNotification)) { note in
                    observer.handle(note, isShow: true)
                }
                .onReceive(NotificationCenter.default.publisher(
                    for: UIResponder.keyboardWillHideNotification)) { note in
                    observer.handle(note, isShow: false)
                }
                .background {
                    WindowMetricsReader { window in
                        observer.updateWindowMetrics(window: window)
                    }
                    .frame(width: 0, height: 0)
                }
                .ignoresSafeArea(.keyboard, edges: .bottom)
        } else {
            content
        }
    }
}

/// Reports the hosting window's height and bottom safe area without reading
/// the keyboard into the resting inset.
private struct WindowMetricsReader: UIViewRepresentable {
    let onMetrics: (UIWindow) -> Void

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.isUserInteractionEnabled = false
        view.onMetrics = onMetrics
        return view
    }

    func updateUIView(_ uiView: ProbeView, context: Context) {
        uiView.onMetrics = onMetrics
        uiView.report()
    }

    final class ProbeView: UIView {
        var onMetrics: ((UIWindow) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            report()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            report()
        }

        func report() {
            guard let window else { return }
            DispatchQueue.main.async { [onMetrics] in
                onMetrics?(window)
            }
        }
    }
}

import SwiftUI

#if canImport(UIKit)
import UIKit

/// K2: trigger-style keyboard gestures on the composer's glass bar. A drag
/// that claims the touch is judged once on release — down resigns while the
/// keyboard is visible, up focuses while it is hidden. Nothing is tracked and
/// no touch is swallowed, so taps, caret placement, IME candidates and
/// long-press selection keep working while this recognizer is armed.
struct ComposerKeyboardPanGesture: UIGestureRecognizerRepresentable {
    let draft: ComposerDraft
    let editor: ComposerEditorController

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator()
    }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let recognizer = UIPanGestureRecognizer()
        // The editor owns taps, carets, IME candidates and selection drags;
        // this recognizer only observes the finger and decides on release.
        recognizer.cancelsTouchesInView = false
        recognizer.maximumNumberOfTouches = 1
        recognizer.delegate = context.coordinator
        return recognizer
    }

    func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer, context: Context) {
        context.coordinator.textView = editor.textView
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        // One-shot decision on release. `.cancelled` is handed to the policy
        // and answers `.none`: a system takeover is not a user decision.
        switch recognizer.state {
        case .ended, .cancelled:
            let translation = context.converter.localTranslation ?? .zero
            let velocity = context.converter.localVelocity ?? .zero
            let policy = ComposerKeyboardGesturePolicy.Context(
                translationY: translation.y,
                velocityY: velocity.y,
                keyboardIsVisible: draft.isFocused,
                isComposing: draft.isComposing,
                isSelecting: context.coordinator.isTextSelectionActive,
                outcome: recognizer.state == .cancelled ? .cancelled : .ended
            )
            switch ComposerKeyboardGesturePolicy.action(for: policy) {
            case .focus:
                draft.isFocused = true
            case .resign:
                // Same path as the composer's own dismissal: resign the text
                // view, then mirror the resulting focus into the draft.
                editor.finishEditing()
                draft.isFocused = false
            case .none:
                break
            }
        case .possible, .began, .changed, .failed:
            break
        @unknown default:
            break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        /// The editor's text view, kept weak: it is only inspected for text
        /// selection arbitration, never owned or driven from here.
        weak var textView: UIView?
        /// The hit view of the accepted touch, captured before delivery so the
        /// begin decision needs no second hit test (which could land on this
        /// gesture's own host view).
        private weak var receivedView: UIView?

        /// A text interaction owns this touch: a long-press selection drag, its
        /// extension, or the magnifier is actively recognizing — or the touch
        /// began on the text and a selection exists now (a long press can fire
        /// after this gesture already claimed the touch and finish before the
        /// release is judged, leaving only the selection behind).
        var isTextSelectionActive: Bool {
            guard let textView else { return false }
            for recognizer in textView.gestureRecognizers ?? [] {
                if recognizer.state == .began || recognizer.state == .changed { return true }
            }
            if touchStartedInTextView, let textView = textView as? UITextView, textView.selectedRange.length > 0 {
                return true
            }
            return false
        }

        private var touchStartedInTextView: Bool {
            guard let textView, let receivedView else { return false }
            var current: UIView? = receivedView
            while let candidate = current {
                if candidate === textView { return true }
                current = candidate.superview
            }
            return false
        }

        func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            // UIKit-backed controls own their touches (+ / send / stop /
            // commands), and the attachment tray belongs to its own horizontal
            // scrolling. SwiftUI-drawn controls stay untouched anyway: the pan
            // only claims after the vertical slop, and taps are never
            // cancelled.
            guard !Self.isInsideControl(touch.view, upTo: recognizer.view),
                  !Self.isInsideForeignScrollView(touch.view, upTo: recognizer.view) else { return false }
            receivedView = touch.view
            return true
        }

        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer, let host = pan.view else { return false }
            // Claim gate: vertical dominance at 1:1 and the claim distance.
            // The pan's own slop is the platform's equivalent of DragGesture's
            // minimumDistance, so a real drag reports the distance here.
            let translation = pan.translation(in: host)
            guard ComposerKeyboardGesturePolicy.claims(dx: translation.x, dy: translation.y) else { return false }
            // The editor's own text scrolling owns a vertical drag while its
            // content exceeds the maximum height.
            if let receivedView, Self.isInsideVerticallyScrollableSurface(receivedView, upTo: host) { return false }
            // A selection drag in progress is never taken over.
            if isTextSelectionActive { return false }
            return true
        }

        func gestureRecognizer(
            _ recognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            // This recognizer is passive; it must never make the editor's or a
            // scroll view's own recognizers fail.
            true
        }

        private static func isInsideControl(_ view: UIView?, upTo host: UIView?) -> Bool {
            var current = view
            while let candidate = current {
                if candidate is UIControl { return true }
                if candidate === host { return false }
                current = candidate.superview
            }
            return false
        }

        /// The attachment tray is a horizontal scroll view inside the bar: the
        /// keyboard gesture is not mounted there. The editor is a `UITextView`
        /// — itself a scroll view — and stays eligible; its internal scrolling
        /// is handled later, only while it can actually scroll.
        private static func isInsideForeignScrollView(_ view: UIView?, upTo host: UIView?) -> Bool {
            var current = view
            while let candidate = current, !(candidate is UITextView) {
                if candidate is UIScrollView { return true }
                if candidate === host { return false }
                current = candidate.superview
            }
            return false
        }

        /// True when the touch lands inside a vertically scrollable scroll
        /// view: the editor switches to internal scrolling once its text
        /// exceeds the maximum height, and that drag belongs to the text view.
        private static func isInsideVerticallyScrollableSurface(_ view: UIView, upTo host: UIView) -> Bool {
            var current: UIView? = view
            while let candidate = current, candidate !== host {
                if let scrollView = candidate as? UIScrollView, isVerticallyScrollable(scrollView) {
                    return true
                }
                current = candidate.superview
            }
            return false
        }

        private static func isVerticallyScrollable(_ scrollView: UIScrollView) -> Bool {
            scrollView.isScrollEnabled && scrollView.contentSize.height > scrollView.bounds.height + 1
        }
    }
}

/// K3 companion: a tap on empty space. Mounted on the message area, armed only
/// while the keyboard is visible. The recognizer never swallows touches;
/// taps that land on a text surface (Textual's selection/link overlay) or a
/// UIKit control are not received, so selection, links and buttons keep both
/// their touches and their menus.
struct TimelineKeyboardDismissGesture: UIGestureRecognizerRepresentable {
    let isEnabled: Bool
    let onDismiss: () -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator()
    }

    func makeUIGestureRecognizer(context: Context) -> UITapGestureRecognizer {
        let recognizer = UITapGestureRecognizer()
        // Buttons, links and rows underneath must keep receiving their taps
        // even when this one also recognizes.
        recognizer.cancelsTouchesInView = false
        recognizer.delegate = context.coordinator
        recognizer.isEnabled = isEnabled
        return recognizer
    }

    func updateUIGestureRecognizer(_ recognizer: UITapGestureRecognizer, context: Context) {
        recognizer.isEnabled = isEnabled
    }

    func handleUIGestureRecognizerAction(_ recognizer: UITapGestureRecognizer, context: Context) {
        guard recognizer.state == .ended, isEnabled else { return }
        onDismiss()
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            // Only a tap that misses every text surface counts as blank space.
            // Textual's selection overlay answers `point(inside:)` with true
            // across its whole frame (minus embedded scrollable regions), so a
            // touch inside a text block belongs to text interaction; page
            // background, row spacing and the tail land on the scroll view
            // instead.
            var current = touch.view
            while let candidate = current {
                if candidate is UITextInput || candidate is UIControl { return false }
                if candidate === recognizer.view { break }
                current = candidate.superview
            }
            return true
        }
    }
}

extension View {
    /// K2: swipe up on the glass bar to focus the editor, down to resign it.
    /// Applies to every `ChatComposerDock` host (session and new session).
    func composerKeyboardGesture(draft: ComposerDraft, editor: ComposerEditorController) -> some View {
        gesture(ComposerKeyboardPanGesture(draft: draft, editor: editor))
    }

    /// K3: while the keyboard is visible, a tap on empty message space resigns
    /// the first responder. The return pill is hidden during that state, so
    /// its region cannot overlap this gesture.
    func keyboardDismissTapGesture(isEnabled: Bool) -> some View {
        gesture(TimelineKeyboardDismissGesture(isEnabled: isEnabled) {
            UIApplication.shared.sendAction(
                #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        })
    }
}

#else

extension View {
    func composerKeyboardGesture(draft: ComposerDraft, editor: ComposerEditorController) -> some View {
        self
    }

    func keyboardDismissTapGesture(isEnabled: Bool) -> some View {
        self
    }
}

#endif

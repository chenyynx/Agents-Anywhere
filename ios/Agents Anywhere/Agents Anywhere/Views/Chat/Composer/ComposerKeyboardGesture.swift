import SwiftUI

#if canImport(UIKit)
import UIKit

/// K2: trigger-style keyboard gestures on the composer's glass bar. Every
/// drag is accepted at begin — the recognizer is passive, cancelling no touch
/// and failing no other recognizer — and judged once on release over the whole
/// net travel: down resigns while the keyboard is visible, up focuses while it
/// is hidden. The converter can report no release velocity, so the release
/// falls back to a velocity estimated from this gesture's own in-flight
/// samples. Taps, caret placement, IME candidates and long-press selection
/// keep working while this recognizer is armed.
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
        case .began, .changed:
            // In-flight samples for the release-velocity estimate. The
            // converter localises the live touch exactly; the raw translation
            // is the documented fallback.
            let inFlight = context.converter.localTranslation ?? recognizer.translation(in: recognizer.view)
            context.coordinator.record(translationY: inFlight.y, time: ProcessInfo.processInfo.systemUptime)
        case .ended, .cancelled:
            let translation = context.converter.localTranslation ?? recognizer.translation(in: recognizer.view)
            // The converter's release velocity can be missing (a fast flick
            // barely reaches it): a non-zero converter value always wins,
            // otherwise the in-flight estimate stands in, and zero is the
            // last resort.
            let release = ComposerGestureKinematics.Sample(
                time: ProcessInfo.processInfo.systemUptime, translationY: translation.y)
            let estimated = context.coordinator.samples.last.flatMap {
                ComposerGestureKinematics.velocityY(previous: $0, current: release)
            }
            let converterVelocity = context.converter.localVelocity?.y
            let velocityY: CGFloat
            if let converterVelocity, converterVelocity != 0 {
                velocityY = converterVelocity
            } else {
                velocityY = estimated ?? converterVelocity ?? 0
            }
            let policy = ComposerKeyboardGesturePolicy.Context(
                translationX: translation.x,
                translationY: translation.y,
                velocityY: velocityY,
                keyboardIsVisible: draft.isFocused,
                isComposing: draft.isComposing,
                isSelecting: context.coordinator.isTextSelectionActive,
                outcome: recognizer.state == .cancelled ? .cancelled : .ended
            )
            switch ComposerKeyboardGesturePolicy.action(for: policy) {
            case .focus:
                // Drive the responder straight from the gesture, the mirror of
                // `.resign` below: the pop must not wait on a SwiftUI
                // observation hop back into `updateUIView`; `synchronize`
                // mirrors the real focus into the draft.
                editor.beginEditing()
            case .resign:
                // Same path as the composer's own dismissal: resign the text
                // view, then mirror the resulting focus into the draft.
                editor.finishEditing()
                draft.isFocused = false
            case .none:
                break
            }
        case .possible, .failed:
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

        /// In-flight translation samples for the release-velocity estimate,
        /// most recent last; only the last pair is ever read.
        private(set) var samples: [ComposerGestureKinematics.Sample] = []

        /// Record one in-flight translation for the release estimate: the
        /// converter can hand the release a missing velocity, and a fast
        /// flick travels less than the displacement threshold, so the release
        /// needs a velocity of this gesture's own making.
        func record(translationY: CGFloat, time: TimeInterval) {
            samples.append(ComposerGestureKinematics.Sample(time: time, translationY: translationY))
            if samples.count > 2 { samples.removeFirst(samples.count - 2) }
        }

        /// A text interaction owns this touch: a long-press selection drag, its
        /// extension, or the magnifier is actively recognizing — or the touch
        /// began on the text and a selection exists now (a long press can fire
        /// after this gesture already claimed the touch and finish before the
        /// release is judged, leaving only the selection behind). The marked
        /// text range must be checked explicitly: while the IME composes, the
        /// editor's selected range covers the marked text, and the spec lets a
        /// swipe close the keyboard mid-composition — only a selection outside
        /// composition vetoes. An actual drag during composition is still
        /// caught by the active-recognizer check above.
        var isTextSelectionActive: Bool {
            guard let textView else { return false }
            for recognizer in textView.gestureRecognizers ?? [] {
                if recognizer.state == .began || recognizer.state == .changed { return true }
            }
            if touchStartedInTextView, let textView = textView as? UITextView,
               textView.markedTextRange == nil, textView.selectedRange.length > 0 {
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
            // scrolling. SwiftUI-drawn controls stay untouched anyway: this
            // recognizer only observes, and taps are never cancelled.
            guard !Self.isInsideControl(touch.view, upTo: recognizer.view),
                  !Self.isInsideForeignScrollView(touch.view, upTo: recognizer.view) else { return false }
            receivedView = touch.view
            return true
        }

        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer, let host = pan.view else { return false }
            // Direction and distance are judged on release, over the whole net
            // travel; the begin no longer samples them, because a one-shot
            // sample could kill a real swipe whose first frames were sideways.
            // Releasing the begin is safe: this recognizer is passive — it
            // swallows no touches and fails no other recognizer — so only two
            // owners can stop it from arming: the editor's own vertical
            // scrolling, and a selection drag in progress.
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
/// while the keyboard is visible. The recognizer never swallows touches; only
/// taps that land on a control or an editable text view are not received.
/// Message body text is read-only (Textual's selection/link overlay) and
/// counts as empty space per the 2026-10-02 acceptance revision, so a body tap
/// dismisses the keyboard; links still open and long-press selection still
/// wins, because no touch is ever cancelled and the tap fails once a drag
/// begins. Simultaneous recognition is granted explicitly (round 1.1b): the
/// body's own recognizers otherwise arbitrate exclusively against this tap,
/// cancelling one side and making the dismissal unreliable.
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
            // The veto is reserved for views that genuinely own the touch: a
            // UIControl (buttons, a single-line field) or an editable text
            // view. Read-only body text (Textual's selection overlay) counts
            // as empty space per the 2026-10-02 acceptance revision: a tap
            // there dismisses the keyboard. Links still open and long-press
            // selection still wins, because no touch is ever cancelled and
            // this tap fails as soon as a drag begins.
            var current = touch.view
            while let candidate = current {
                if candidate is UIControl { return false }
                if (candidate as? UITextView)?.isEditable == true { return false }
                if candidate === recognizer.view { break }
                current = candidate.superview
            }
            return true
        }

        func gestureRecognizer(
            _ recognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            // Text surfaces run their own tap recognizers (selection, links).
            // The default arbitration cancels one side, which made the
            // dismissal flaky; this recognizer cancels no touches, so both may
            // recognize.
            true
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

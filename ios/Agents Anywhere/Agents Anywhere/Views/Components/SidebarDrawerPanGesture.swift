#if canImport(UIKit)
import SwiftUI
import UIKit

// Establishes horizontal intent before recognition so drawer pans cancel row taps without stealing vertical scrolling.
struct SidebarDrawerPanGesture: UIGestureRecognizerRepresentable {
    let progress: CGFloat
    let onBegan: () -> Void
    let onChanged: (CGFloat) -> Void
    let onEnded: (CGFloat, CGFloat, Bool) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator()
    }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let recognizer = UIPanGestureRecognizer()
        recognizer.cancelsTouchesInView = true
        recognizer.maximumNumberOfTouches = 1
        recognizer.delegate = context.coordinator
        return recognizer
    }

    func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer, context: Context) {
        context.coordinator.progress = progress
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        let translationX = context.converter.localTranslation?.x ?? 0
        let velocityX = context.converter.localVelocity?.x ?? 0

        switch recognizer.state {
        case .began:
            onBegan()
        case .changed:
            onChanged(translationX)
        case .ended:
            onEnded(translationX, velocityX, false)
        case .cancelled:
            onEnded(translationX, velocityX, true)
        case .possible, .failed:
            break
        @unknown default:
            break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var progress: CGFloat = 0

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard
                let pan = gestureRecognizer as? UIPanGestureRecognizer,
                let view = pan.view
            else {
                return false
            }

            let velocity = pan.velocity(in: view)
            // Vertical pans must never begin: the gesture is attached to the
            // whole page, so beginning here would cancel the scroll view's
            // touches. The official drawer can fail late because it owns the
            // recognizer; with UIPanGestureRecognizer this upfront gate is the
            // public-API equivalent.
            guard abs(velocity.x) > abs(velocity.y) else { return false }

            // Closed: a rightward horizontal swipe opens from anywhere on the
            // page. Open: keep only the leftward close direction so rightward
            // swipes inside the sidebar stay with the sidebar.
            if progress <= 0.001 { return velocity.x > 0 }
            if progress >= 0.999 { return velocity.x < 0 }
            return true
        }

        /// Matches the official drawer: the system edge-back gesture and
        /// custom pans attached to scroll views must fail first. Without this
        /// the full-page pan competes with the interactive pop gesture at the
        /// left edge.
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRequireFailureOf otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            if otherGestureRecognizer is UIScreenEdgePanGestureRecognizer {
                return true
            }
            if let pan = otherGestureRecognizer as? UIPanGestureRecognizer,
               let scrollView = pan.view as? UIScrollView {
                return pan !== scrollView.panGestureRecognizer
            }
            return false
        }
    }
}
#endif

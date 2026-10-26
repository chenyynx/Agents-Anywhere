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
        let translationX = localTranslationX(recognizer, context: context)

        switch recognizer.state {
        case .began:
            context.coordinator.recordSample(translationX: translationX)
            onBegan()
        case .changed:
            context.coordinator.recordSample(translationX: translationX)
            onChanged(translationX)
        case .ended, .cancelled:
            // A fast flick can outrun the converter's velocity. Estimate it
            // from the in-flight samples rather than silently treating the
            // release as stationary; a non-zero converter value still wins.
            let estimatedVelocity = context.coordinator.estimatedReleaseVelocity(
                translationX: translationX
            )
            let converterVelocity = context.converter.localVelocity?.x
            let velocityX: CGFloat
            if let converterVelocity, converterVelocity != 0 {
                velocityX = converterVelocity
            } else {
                velocityX = estimatedVelocity ?? converterVelocity ?? 0
            }
            context.coordinator.resetSamples()
            onEnded(translationX, velocityX, recognizer.state == .cancelled)
        case .possible, .failed:
            context.coordinator.resetSamples()
        @unknown default:
            break
        }
    }

    private func localTranslationX(
        _ recognizer: UIPanGestureRecognizer,
        context: Context
    ) -> CGFloat {
        if let translation = context.converter.localTranslation { return translation.x }
        guard let view = recognizer.view else { return 0 }
        return recognizer.translation(in: view).x
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var progress: CGFloat = 0
        private var lastSample: (time: TimeInterval, translationX: CGFloat)?

        func recordSample(translationX: CGFloat) {
            lastSample = (ProcessInfo.processInfo.systemUptime, translationX)
        }

        func resetSamples() {
            lastSample = nil
        }

        func estimatedReleaseVelocity(translationX: CGFloat) -> CGFloat? {
            guard let lastSample else { return nil }
            return SidebarDrawerGestureRules.estimatedVelocityX(
                previousTranslationX: lastSample.translationX,
                previousTime: lastSample.time,
                currentTranslationX: translationX,
                currentTime: ProcessInfo.processInfo.systemUptime
            )
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard
                let pan = gestureRecognizer as? UIPanGestureRecognizer,
                let view = pan.view
            else {
                return false
            }

            // Vertical pans must never begin: the gesture is attached to the
            // whole page, so beginning here would cancel the scroll view's
            // touches. The official drawer can fail late because it owns the
            // recognizer; with UIPanGestureRecognizer this upfront gate is the
            // public-API equivalent. The accumulated translation is steadier
            // than the single start-velocity sample.
            let translation = pan.translation(in: view)
            let velocity = pan.velocity(in: view)
            return SidebarDrawerGestureRules.shouldBegin(
                progress: progress,
                translationX: translation.x,
                translationY: translation.y,
                velocityX: velocity.x,
                velocityY: velocity.y
            )
        }

        /// A horizontal scroller under the finger owns the drag. The drawer is
        /// attached to the whole page, so without this a rightward drag inside
        /// a code block or the attachment tray would open the drawer and
        /// cancel the scroll view's touches. Only opening is guarded; closing
        /// still works from anywhere.
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldReceive touch: UITouch
        ) -> Bool {
            guard progress <= 0.001 else { return true }
            return !Self.isInsideHorizontallyScrollableSurface(
                touch.view,
                upTo: gestureRecognizer.view
            )
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

        private static func isInsideHorizontallyScrollableSurface(
            _ view: UIView?,
            upTo host: UIView?
        ) -> Bool {
            var current = view
            while let candidate = current, candidate !== host {
                if let scrollView = candidate as? UIScrollView,
                   scrollView.contentSize.width > scrollView.bounds.width + 1,
                   // A full-width vertical scroller can report horizontal
                   // overflow from a child; that is the page itself, not a
                   // horizontal surface. Only inset scrollers (code blocks,
                   // trays) take the drag away from the drawer.
                   host.map({ scrollView.bounds.width < $0.bounds.width - 1 }) ?? true {
                    return true
                }
                current = candidate.superview
            }
            return false
        }
    }
}
#endif

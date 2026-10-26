import SwiftUI
import UIKit

/// The official keyboard motion for the composer page.
///
/// The official page does not ride UIKit's keyboard safe-area animation. It
/// removes the keyboard region from the safe area (`IgnoresEarlyKeyboard`,
/// `ClaudeCoreUI` — body at `0x100c9d5cc` calls `ignoresSafeArea(.keyboard,
/// edges: .bottom)`) and lifts the page itself with
/// `.safeAreaPadding(.bottom, overlap)`, animated by one spring:
/// `interpolatingSpring(mass: 3, stiffness: 1000, damping: 500)`.
/// The spring is built once at `0x100d9633c` from the constants at
/// `0x10422ea00` (1000) and `0x1042ccdb0` (500); `EarlyKeyboardPadding`
/// (`0x100d96370`) reads `UIKeyboardAnimationDurationUserInfoKey` and only
/// animates when the notification carries a non-zero duration
/// (`0x100d96c44`), so a keyboard that reports no duration jumps instantly.
private let officialKeyboardSpring = Animation.interpolatingSpring(
    mass: 3, stiffness: 1000, damping: 500)

/// Lifts the page with the official spring instead of the system keyboard
/// safe area. Attach it next to the composer so the transcript and the card
/// move as one layout, exactly like the official `VStack` page.
struct EarlyKeyboardPadding: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var overlap: CGFloat = 0
    @State private var containerBottom: CGFloat = 0
    @State private var restingInset: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .safeAreaPadding(.bottom, overlap)
            // Official `IgnoresEarlyKeyboard`: the keyboard region is removed
            // from the safe area, so UIKit no longer moves this subtree.
            .ignoresSafeArea(.keyboard, edges: .bottom)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.frame(in: .global).maxY
            } action: { bottom in
                containerBottom = bottom
            }
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.safeAreaInsets.bottom
            } action: { inset in
                restingInset = inset
            }
            .onReceive(NotificationCenter.default.publisher(
                for: UIResponder.keyboardWillShowNotification)) { note in
                animate(to: target(for: note), note: note)
            }
            .onReceive(NotificationCenter.default.publisher(
                for: UIResponder.keyboardWillHideNotification)) { note in
                animate(to: 0, note: note)
            }
            .onReceive(NotificationCenter.default.publisher(
                for: UIResponder.keyboardWillChangeFrameNotification)) { note in
                // Interactive dismissal animates the frame every run loop.
                // Follow it directly so the card stays under the finger
                // instead of chasing it with a settling spring.
                guard overlap > 0 else { return }
                let next = screenOverlap(for: note)
                if next < overlap { overlap = next }
            }
    }

    private func target(for note: Notification) -> CGFloat {
        screenOverlap(for: note)
    }

    private func screenOverlap(for note: Notification) -> CGFloat {
        guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey]
            as? CGRect else { return overlap }
        return EarlyKeyboardMotion.overlap(
            keyboardTop: frame.minY,
            containerBottom: containerBottom,
            restingInset: restingInset)
    }

    private func animate(to value: CGFloat, note: Notification) {
        let duration = note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey]
            as? Double ?? 0
        let animation = EarlyKeyboardMotion.shouldAnimate(
            keyboardDuration: duration, reduceMotion: reduceMotion)
            ? officialKeyboardSpring : nil
        withAnimation(animation) { overlap = value }
    }
}

extension View {
    /// Official composer-page keyboard motion (see `EarlyKeyboardMotion`).
    func earlyKeyboardPadding() -> some View {
        modifier(EarlyKeyboardPadding())
    }
}

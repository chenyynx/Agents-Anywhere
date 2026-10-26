import Foundation

/// The official composer page lifts itself instead of riding UIKit's keyboard
/// safe-area animation: `IgnoresEarlyKeyboard` removes the keyboard region
/// (body at `0x100c9d5cc` calls `ignoresSafeArea(.keyboard, edges: .bottom)`)
/// and `EarlyKeyboardPadding` (`0x100d96370`) adds
/// `.safeAreaPadding(.bottom, overlap)` driven by one spring.
///
/// Pure geometry + the official animation rule, so `ClientCoreTests` can pin
/// both without a simulator. The spring itself lives with the view.
nonisolated enum EarlyKeyboardMotion {
    /// Bottom padding for a keyboard whose top edge sits at `keyboardTop`.
    ///
    /// `containerBottom` is the page's bottom edge in screen coordinates and
    /// `restingInset` its home-indicator inset: the page already keeps its
    /// content above `restingInset`, so only the part of the keyboard that
    /// reaches above it has to be padded.
    static func overlap(keyboardTop: CGFloat,
                        containerBottom: CGFloat,
                        restingInset: CGFloat) -> CGFloat {
        max(0, containerBottom - keyboardTop - restingInset)
    }

    /// Official rule from `EarlyKeyboardPadding`'s notification handler
    /// (`0x100d96a94` → `0x100d96c44`): animate only when the keyboard
    /// notification carries a non-zero `UIKeyboardAnimationDurationUserInfoKey`.
    static func shouldAnimate(keyboardDuration: Double, reduceMotion: Bool) -> Bool {
        !reduceMotion && keyboardDuration > 0
    }
}

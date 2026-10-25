import Foundation

/// Pure keyboard-following math for the Code composer.
///
/// The official Code page reserves the keyboard height itself instead of
/// letting the system safe area move the bar: `EarlyKeyboardPadding` applies
/// `.safeAreaPadding(.bottom, max(keyboardHeight − restingInset, 0))` and
/// animates it with `Animation.interpolatingSpring(mass: 3, stiffness: 1000,
/// damping: 500)` when the keyboard notification carries a positive duration
/// (official build 1.261005.20, `0x100d96370` / `0x100d9633c` / `0x100d96a94`).
nonisolated enum ComposerKeyboardLayout {
    static let springMass: Double = 3
    static let springStiffness: Double = 1000
    static let springDamping: Double = 500
    static let springInitialVelocity: Double = 0

    /// The composer already rests above the window's bottom safe area; only
    /// the keyboard height beyond that inset needs to be reserved.
    static func bottomPadding(keyboardHeight: CGFloat, restingInset: CGFloat) -> CGFloat {
        max(keyboardHeight - restingInset, 0)
    }

    /// Official reads `UIKeyboardAnimationDurationUserInfoKey` only as a gate:
    /// a positive duration selects the fixed spring, zero/missing means no
    /// animation.
    static func usesAnimation(duration: TimeInterval) -> Bool {
        duration > 0
    }

    /// The notification frame is in screen coordinates; the keyboard's top
    /// edge is what the composer must clear.
    static func keyboardHeight(screenHeight: CGFloat, keyboardTop: CGFloat) -> CGFloat {
        max(screenHeight - keyboardTop, 0)
    }
}

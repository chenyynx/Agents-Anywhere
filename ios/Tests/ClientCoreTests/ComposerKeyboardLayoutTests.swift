import Foundation
import Testing
@testable import ClientCore

/// Pins the official EarlyKeyboardPadding math (build 1.261005.20): the
/// composer reserves the keyboard height beyond the window's resting inset and
/// only animates when the keyboard notification carries a positive duration.
@Suite struct ComposerKeyboardLayoutTests {
    @Test func paddingSubtractsTheRestingInsetAndNeverGoesNegative() {
        #expect(ComposerKeyboardLayout.bottomPadding(keyboardHeight: 336, restingInset: 34) == 302)
        #expect(ComposerKeyboardLayout.bottomPadding(keyboardHeight: 20, restingInset: 34) == 0)
        #expect(ComposerKeyboardLayout.bottomPadding(keyboardHeight: 0, restingInset: 34) == 0)
    }

    @Test func positiveDurationSelectsTheSpringAndZeroOrMissingDoesNot() {
        #expect(ComposerKeyboardLayout.usesAnimation(duration: 0.25))
        #expect(!ComposerKeyboardLayout.usesAnimation(duration: 0))
        #expect(!ComposerKeyboardLayout.usesAnimation(duration: -1))
    }

    @Test func keyboardHeightIsMeasuredFromTheScreenBottomToTheFrameTop() {
        // 852 pt screen, keyboard top at 507 pt: the overlay is 345 pt tall.
        #expect(ComposerKeyboardLayout.keyboardHeight(screenHeight: 852, keyboardTop: 507) == 345)
        #expect(ComposerKeyboardLayout.keyboardHeight(screenHeight: 852, keyboardTop: 900) == 0)
    }

    @Test func springParametersMatchTheOfficialBinary() {
        #expect(ComposerKeyboardLayout.springMass == 3)
        #expect(ComposerKeyboardLayout.springStiffness == 1000)
        #expect(ComposerKeyboardLayout.springDamping == 500)
        #expect(ComposerKeyboardLayout.springInitialVelocity == 0)
    }
}

import Foundation
import Testing
@testable import ClientCore

/// Pins the official keyboard-motion geometry used by the composer page
/// (`EarlyKeyboardPadding` / `IgnoresEarlyKeyboard`).
@Suite struct EarlyKeyboardMotionTests {
    @Test func overlapCountsOnlyWhatReachesAboveTheHomeIndicator() {
        // 852 pt screen, 336 pt keyboard, 34 pt home indicator: the page
        // already clears the indicator, so it lifts by 302.
        let overlap = EarlyKeyboardMotion.overlap(
            keyboardTop: 516, containerBottom: 852, restingInset: 34)
        #expect(overlap == 302)
    }

    @Test func hiddenKeyboardAddsNoPadding() {
        // The keyboard's end frame sits at the screen bottom.
        #expect(EarlyKeyboardMotion.overlap(
            keyboardTop: 852, containerBottom: 852, restingInset: 34) == 0)
        // And a frame below the container never yields a negative padding.
        #expect(EarlyKeyboardMotion.overlap(
            keyboardTop: 900, containerBottom: 852, restingInset: 34) == 0)
    }

    @Test func interactiveDismissalTracksTheFrame() {
        // Half-way down: the padding follows the finger instead of settling.
        let half = EarlyKeyboardMotion.overlap(
            keyboardTop: 684, containerBottom: 852, restingInset: 34)
        #expect(half == 134)
    }

    @Test func onlyANonZeroDurationNotifiesAnAnimation() {
        #expect(EarlyKeyboardMotion.shouldAnimate(keyboardDuration: 0.25, reduceMotion: false))
        #expect(!EarlyKeyboardMotion.shouldAnimate(keyboardDuration: 0, reduceMotion: false))
        #expect(!EarlyKeyboardMotion.shouldAnimate(keyboardDuration: 0.25, reduceMotion: true))
    }
}

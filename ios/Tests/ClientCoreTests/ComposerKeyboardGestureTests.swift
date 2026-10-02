import Foundation
import Testing
@testable import ClientCore

/// Pins the trigger-style composer keyboard gesture rules (K2): claim at 10pt
/// with 1:1 vertical dominance; dismiss at ≥400pt/s or ≥60pt; present at
/// ≥300pt/s or ≥24pt; cancelled gestures and drag-selects are never judged.
/// The thresholds are deliberately spelled as literals here so any change to
/// `ComposerKeyboardGestureThresholds` or to a branch turns these red.
@Suite struct ComposerKeyboardGestureTests {
    private func context(
        translationY: CGFloat = 0,
        velocityY: CGFloat = 0,
        keyboardIsVisible: Bool = true,
        isComposing: Bool = false,
        isSelecting: Bool = false,
        outcome: ComposerKeyboardGesturePolicy.Outcome = .ended
    ) -> ComposerKeyboardGesturePolicy.Context {
        ComposerKeyboardGesturePolicy.Context(
            translationY: translationY, velocityY: velocityY,
            keyboardIsVisible: keyboardIsVisible, isComposing: isComposing,
            isSelecting: isSelecting, outcome: outcome)
    }

    private func action(_ context: ComposerKeyboardGesturePolicy.Context) -> ComposerKeyboardGesturePolicy.Action {
        ComposerKeyboardGesturePolicy.action(for: context)
    }

    // MARK: - Claim gate

    @Test func claimNeedsVerticalDominanceAtTenPoints() {
        // Exactly 10pt of pure vertical travel claims: 10 > 0 and 10 >= 10.
        #expect(ComposerKeyboardGesturePolicy.claims(dx: 0, dy: 10))
        // 9.9pt is below the claim distance even when perfectly vertical.
        #expect(!ComposerKeyboardGesturePolicy.claims(dx: 0, dy: 9.9))
        // A 1:1 tie is not dominance; (10, 10) is exactly on the diagonal.
        #expect(!ComposerKeyboardGesturePolicy.claims(dx: 10, dy: 10))
        // Vertical wins only while it strictly dominates: 10 > 9 and 10 >= 10.
        #expect(ComposerKeyboardGesturePolicy.claims(dx: 9, dy: 10))
        // Horizontal dominance never claims, however long the travel (40 > 60 is false).
        #expect(!ComposerKeyboardGesturePolicy.claims(dx: 60, dy: 40))
        // The gate is symmetric: an upward drag claims on magnitudes alone.
        #expect(ComposerKeyboardGesturePolicy.claims(dx: -4, dy: -10))
        // And the tie is rejected upward too.
        #expect(!ComposerKeyboardGesturePolicy.claims(dx: -10, dy: -10))
    }

    // MARK: - Keyboard visible: a downward release resigns

    @Test func visibleKeyboardDismissesOnAFastFlick() {
        // 400pt/s meets the dismiss speed exactly; the 1pt of net travel is
        // far below the 60pt distance, so only the speed rule can fire.
        #expect(action(context(translationY: 1, velocityY: 400)) == .resign)
        // 399pt/s misses the speed and 30pt misses the distance: both rules fail.
        #expect(action(context(translationY: 30, velocityY: 399)) == .none)
    }

    @Test func visibleKeyboardDismissesOnALongSlowDrag() {
        // 60pt of net travel meets the distance exactly at any speed.
        #expect(action(context(translationY: 60, velocityY: 0)) == .resign)
        // 59pt with a slow release slide misses both thresholds.
        #expect(action(context(translationY: 59, velocityY: 100)) == .none)
    }

    @Test func visibleKeyboardNeverDismissesUpward() {
        // A strong upward drag passes both magnitudes in the wrong direction:
        // -700 is not ≥ 400 and -100 is not ≥ 60.
        #expect(action(context(translationY: -100, velocityY: -700)) == .none)
        // A rest release with the keyboard up is not a request either.
        #expect(action(context()) == .none)
    }

    // MARK: - Keyboard hidden: an upward release focuses

    @Test func hiddenKeyboardPresentsOnAFastFlick() {
        // -300pt/s meets the present speed exactly; -1pt of travel is below
        // the 24pt distance, so only the speed rule can fire.
        #expect(action(context(translationY: -1, velocityY: -300, keyboardIsVisible: false)) == .focus)
        // -299pt/s misses the speed and 15pt misses the distance.
        #expect(action(context(translationY: -15, velocityY: -299, keyboardIsVisible: false)) == .none)
    }

    @Test func hiddenKeyboardPresentsOnALongSlowDrag() {
        // 24pt of net upward travel meets the distance exactly at any speed.
        #expect(action(context(translationY: -24, velocityY: 0, keyboardIsVisible: false)) == .focus)
        // 23pt with a slow release slide misses both thresholds.
        #expect(action(context(translationY: -23, velocityY: -100, keyboardIsVisible: false)) == .none)
    }

    @Test func hiddenKeyboardNeverPresentsDownward() {
        // A strong downward drag passes both magnitudes in the wrong direction:
        // 700 is not ≤ -300 and 100 is not ≤ -24.
        #expect(action(context(translationY: 100, velocityY: 700, keyboardIsVisible: false)) == .none)
        #expect(action(context(translationY: 0, velocityY: 0, keyboardIsVisible: false)) == .none)
    }

    // MARK: - State arbitration

    @Test func markedTextIsAllowedToDismiss() {
        // IME composition is deliberately not a veto: the spec keeps the
        // system-like behavior of closing the keyboard while composing.
        #expect(action(context(translationY: 80, velocityY: 500, isComposing: true)) == .resign)
        // It does not veto the present path either (keyboard hidden means no
        // active composition in practice, but the rule is unconditional).
        #expect(action(context(translationY: -50, velocityY: -500,
            keyboardIsVisible: false, isComposing: true)) == .focus)
    }

    @Test func selectionDragsAreNeverTakenOver() {
        // A running long-press drag-select owns the touch: samples that would
        // otherwise dismiss must do nothing...
        #expect(action(context(translationY: 80, velocityY: 500, isSelecting: true)) == .none)
        // ...and the same holds for the present path.
        #expect(action(context(translationY: -60, velocityY: -600,
            keyboardIsVisible: false, isSelecting: true)) == .none)
    }

    @Test func cancelledGesturesAreNeverJudged() {
        // A system takeover is not a user decision, even when the captured
        // samples alone would pass either rule.
        #expect(action(context(translationY: 80, velocityY: 800, outcome: .cancelled)) == .none)
        #expect(action(context(translationY: -80, velocityY: -800,
            keyboardIsVisible: false, outcome: .cancelled)) == .none)
    }
}

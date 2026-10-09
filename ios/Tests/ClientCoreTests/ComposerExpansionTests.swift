import Foundation
import Testing
@testable import ClientCore

/// Pins the composer's derived expansion and the focus-intent token that keeps
/// a resigned focus from latching back on. Expectations are literals so any
/// change to the rule turns these red.
@Suite struct ComposerExpansionTests {
    // MARK: ComposerExpansion (pure)

    @Test func whitespaceOnlyDraftsHaveNoContent() {
        // A lone newline an interrupted focus left behind is not content: it
        // must not force the expanded bar open, hide the placeholder, or leave
        // the send key grey while the bar reads as blank.
        for blank in ["", " ", "   ", "\n", "\n\n", " \n ", "\t", "\r\n"] {
            #expect(!ComposerExpansion.hasContent(blank), "\(blank.debugDescription) should be empty")
        }
        for filled in ["a", " a ", "a\n", "\na", "a\nb"] {
            #expect(ComposerExpansion.hasContent(filled), "\(filled.debugDescription) should have content")
        }
    }

    @Test func multilineIgnoresSurroundingWhitespace() {
        #expect(!ComposerExpansion.isMultiline(""))
        #expect(!ComposerExpansion.isMultiline("single line"))
        // A trailing/leading newline around one line is still one line.
        #expect(!ComposerExpansion.isMultiline("one\n"))
        #expect(!ComposerExpansion.isMultiline("\none"))
        #expect(ComposerExpansion.isMultiline("one\ntwo"))
        #expect(ComposerExpansion.isMultiline("one\ntwo\nthree"))
        #expect(ComposerExpansion.isMultiline("one\n\nthree"))
    }

    @Test func expansionDerivesFromFocusAttachmentsAndLineCount() {
        // Focus and attachments always expand.
        #expect(ComposerExpansion.isExpanded(isFocused: true, attachmentCount: 0, text: ""))
        #expect(ComposerExpansion.isExpanded(isFocused: false, attachmentCount: 1, text: ""))
        // A blank or single-line unfocused draft collapses — the fix for the
        // stuck-expanded bug.
        #expect(!ComposerExpansion.isExpanded(isFocused: false, attachmentCount: 0, text: ""))
        #expect(!ComposerExpansion.isExpanded(isFocused: false, attachmentCount: 0, text: "\n"))
        #expect(!ComposerExpansion.isExpanded(isFocused: false, attachmentCount: 0, text: "one line"))
        // Only a genuinely multi-line unfocused draft expands.
        #expect(ComposerExpansion.isExpanded(isFocused: false, attachmentCount: 0, text: "one\ntwo"))
    }

    // MARK: ComposerDraft (derived state + token)

    @Test func blankDraftDoesNotExpandAndShowsPlaceholder() {
        let draft = ComposerDraft()
        draft.text = "\n"
        #expect(!draft.isExpanded)
        #expect(!draft.hasContent)
        #expect(!draft.canAttemptSend)
    }

    @Test func singleLineUnfocusedDraftCollapses() {
        let draft = ComposerDraft()
        draft.text = "one line"
        #expect(!draft.isExpanded)
        #expect(draft.hasContent)
        #expect(draft.canAttemptSend)
    }

    @Test func multilineUnfocusedDraftExpands() {
        let draft = ComposerDraft()
        draft.text = "one\ntwo"
        #expect(draft.isExpanded)
    }

    @Test func focusReportsDriveExpansion() {
        let draft = ComposerDraft()
        let token = draft.setFocusIntent(true)
        #expect(draft.focusIntent)
        #expect(!draft.isExpanded) // not yet confirmed by the editor
        draft.reportFocus(true, token: token)
        #expect(draft.isFocused)
        #expect(draft.isExpanded)
        let end = draft.setFocusIntent(false)
        draft.reportFocus(false, token: end)
        #expect(!draft.isFocused)
        #expect(!draft.isExpanded)
    }

    @Test func aStaleFocusCallbackCannotReviveAResign() {
        // The bug's shape: blur, then a late "became first responder" from an
        // earlier focus arrives. Its token is superseded, so it is dropped and
        // the field stays collapsed.
        let draft = ComposerDraft()
        let focusToken = draft.setFocusIntent(true)
        let blurToken = draft.setFocusIntent(false)
        #expect(blurToken != focusToken)
        draft.reportFocus(true, token: focusToken) // stale
        #expect(!draft.isFocused)
        #expect(!draft.isExpanded)
        // The current token's report still lands.
        draft.reportFocus(false, token: blurToken)
        #expect(!draft.isFocused)
    }

    @Test func repeatedFocusBlurEndsCollapsed() {
        // Fast toggling must never leave a stuck expansion.
        let draft = ComposerDraft()
        for _ in 0..<30 {
            let focus = draft.setFocusIntent(true)
            draft.reportFocus(true, token: focus)
            #expect(draft.isExpanded)
            let blur = draft.setFocusIntent(false)
            draft.reportFocus(false, token: blur)
            #expect(!draft.isExpanded)
        }
        #expect(!draft.isExpanded)
        #expect(!draft.isFocused)
        #expect(!draft.focusIntent)
    }

    @Test func invalidateClearsFocusAndExpansion() {
        let draft = ComposerDraft()
        let token = draft.setFocusIntent(true)
        draft.reportFocus(true, token: token)
        #expect(draft.isExpanded)
        draft.invalidate()
        #expect(!draft.isExpanded)
        #expect(!draft.focusIntent)
        #expect(!draft.isFocused)
    }
}

/// The keyboard hold gates only the focus term, and every path — a tap, a
/// missed notification, an out-of-order pair, rapid toggling — must resolve.
@Suite struct ComposerKeyboardHoldTests {
    /// Mirrors what the view does on focus: intent + a hold.
    private func tap(_ draft: ComposerDraft) {
        let token = draft.setFocusIntent(true)
        draft.awaitingKeyboard = true
        draft.reportFocus(true, token: token)
    }
    /// Mirrors a blur: end focus and drop the hold unconditionally.
    private func blur(_ draft: ComposerDraft) {
        draft.setFocusIntent(false)
        draft.reportFocus(false, token: draft.focusToken)
        draft.awaitingKeyboard = false
    }
    /// Mirrors the keyboard-will-show release.
    private func willShow(_ draft: ComposerDraft) { draft.awaitingKeyboard = false }

    @Test func focusedTapWaitsForTheKeyboardBeforeExpanding() {
        let draft = ComposerDraft()
        tap(draft)
        #expect(draft.isFocused)
        #expect(draft.awaitingKeyboard)
        #expect(!draft.isExpanded) // held: bar stays put until the keyboard moves
        willShow(draft)
        #expect(draft.isExpanded) // released with the keyboard
    }

    @Test func blurAlwaysCollapsesImmediately() {
        let draft = ComposerDraft()
        tap(draft)
        blur(draft)
        #expect(!draft.awaitingKeyboard)
        #expect(!draft.isExpanded)
    }

    @Test func focusBlurRefocusResolves() {
        let draft = ComposerDraft()
        tap(draft); willShow(draft); #expect(draft.isExpanded)
        blur(draft); #expect(!draft.isExpanded)
        tap(draft); #expect(!draft.isExpanded) // held again
        willShow(draft); #expect(draft.isExpanded)
    }

    @Test func timeoutReleaseExpandsWhenStillFocused() {
        let draft = ComposerDraft()
        tap(draft)
        willShow(draft) // also covers the timer fire path — same release
        #expect(draft.isExpanded)
        // A release after blur must not expand.
        blur(draft)
        willShow(draft)
        #expect(!draft.isExpanded)
    }

    @Test func outOfOrderKeyboardNotificationsStaySafe() {
        let draft = ComposerDraft()
        // A stray willShow before any tap is a no-op (hold is already false).
        willShow(draft)
        #expect(!draft.awaitingKeyboard)
        tap(draft); willShow(draft)
        #expect(draft.isExpanded)
        // willHide without a blur leaves focus in place; the bar stays expanded.
        draft.awaitingKeyboard = false
        #expect(draft.isExpanded)
        blur(draft)
        #expect(!draft.isExpanded)
    }

    @Test func rapidTogglingEndsCollapsed() {
        let draft = ComposerDraft()
        for _ in 0..<30 {
            tap(draft)
            blur(draft)
        }
        #expect(!draft.isExpanded)
        #expect(!draft.isFocused)
        #expect(!draft.awaitingKeyboard)
    }

    @Test func contentExpansionIsNeverHeldBack() {
        let draft = ComposerDraft()
        // A multi-line draft expands even with no keyboard at all.
        draft.text = "one\ntwo"
        #expect(draft.isExpanded)
        // Focus with a pending hold does not disturb that.
        tap(draft)
        #expect(draft.isExpanded)
    }
}

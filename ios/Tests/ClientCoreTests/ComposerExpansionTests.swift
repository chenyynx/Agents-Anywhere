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

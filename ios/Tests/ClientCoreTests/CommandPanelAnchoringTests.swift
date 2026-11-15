import Foundation
import Testing
@testable import ClientCore

/// The slash-command card opens from the composer. With the keyboard up, the
/// page's geometry proxy reported the keyboard in `safeAreaInsets` while the
/// page also shrank around it; the old `height - insetTop - insetBottom`
/// subtraction left the card a few points tall and tapping the command key
/// drew nothing (pp 2026-11-15). The anchor now follows the measured composer
/// dock, and these tests pin the arithmetic on both keyboard states.
@Suite struct CommandPanelAnchoringTests {
    /// iPhone 15 Pro-ish portrait numbers; the keyboard is 336 pt and the
    /// composer dock (glass + margins) is measured at 60 pt above it.
    private let screenHeight: CGFloat = 852
    private let safeTop: CGFloat = 59

    @Test func keyboardUpKeepsAFullCardEvenWhenTheProxyDoubleCountsTheKeyboard() {
        // The proxy reported a shrunken height (852 - 336) AND the keyboard in
        // the bottom inset on the failing build.
        let anchor = CommandPanelAnchoring.resolve(
            baseTop: 0, baseBottom: screenHeight, dockTop: 456,
            insetTop: safeTop, insetBottom: 430, height: 516)
        #expect(anchor.availableHeight == 389)
        #expect(anchor.availableHeight >= 296) // five rows: 5 × 56 + 16
        #expect(anchor.bottomPadding == 430)
    }

    @Test func keyboardDownMatchesTheInsetPlacement() {
        let anchor = CommandPanelAnchoring.resolve(
            baseTop: 0, baseBottom: screenHeight, dockTop: 758,
            insetTop: safeTop, insetBottom: 94, height: screenHeight)
        #expect(anchor.bottomPadding == 94)
        #expect(anchor.availableHeight == 691)
    }

    @Test func anExpandedComposerShrinksTheCardInsteadOfPushingItUnderTheBar() {
        let collapsed = CommandPanelAnchoring.resolve(
            baseTop: 0, baseBottom: screenHeight, dockTop: 456,
            insetTop: safeTop, insetBottom: 430, height: 516)
        let expanded = CommandPanelAnchoring.resolve(
            baseTop: 0, baseBottom: screenHeight, dockTop: 356,
            insetTop: safeTop, insetBottom: 430, height: 516)
        #expect(expanded.availableHeight < collapsed.availableHeight)
        #expect(expanded.availableHeight == 289)
        #expect(expanded.bottomPadding == 496)
    }

    @Test func beforeTheDockIsMeasuredTheInsetFormulaIsTheFallback() {
        let anchor = CommandPanelAnchoring.resolve(
            baseTop: nil, baseBottom: nil, dockTop: nil,
            insetTop: safeTop, insetBottom: 94, height: screenHeight)
        #expect(anchor.bottomPadding == 94)
        #expect(anchor.availableHeight == 691)
    }

    @Test func availableHeightNeverGoesNegative() {
        let anchor = CommandPanelAnchoring.resolve(
            baseTop: 0, baseBottom: screenHeight, dockTop: 50,
            insetTop: safeTop, insetBottom: 0, height: screenHeight)
        #expect(anchor.availableHeight == 0)
        #expect(anchor.bottomPadding == screenHeight - 50)
    }
}

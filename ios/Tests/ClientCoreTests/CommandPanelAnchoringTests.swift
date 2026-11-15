import Foundation
import Testing
@testable import ClientCore

/// The slash-command card opens from the composer. Device diagnostics
/// (`composer.panel.geometry`, b1253, session `sess_TZOh5OCVj3KD8w`,
/// 2026-11-15 19:22–19:53) measured the timeline frame as the transcript
/// area between the navigation bar and the composer bar, and the bottom safe
/// area as the card's whole lift. These tests pin the arithmetic to those
/// numbers.
@Suite struct CommandPanelAnchoringTests {
    private let navBottom: CGFloat = 113
    private let keyboardUpBottom: CGFloat = 414
    private let keyboardDownBottom: CGFloat = 758

    @Test func keyboardUpUsesTheWholeTranscriptArea() {
        let anchor = CommandPanelAnchoring.resolve(
            baseTop: navBottom, baseBottom: keyboardUpBottom,
            insetBottom: 438, height: keyboardUpBottom - navBottom)
        #expect(anchor.availableHeight == 293)
        #expect(anchor.bottomPadding == 438)
        // The card top lands on the navigation bar's bottom edge.
        #expect(keyboardUpBottom - anchor.availableHeight == navBottom + 8)
    }

    @Test func keyboardDownShowsMoreRowsThanKeyboardUp() {
        let up = CommandPanelAnchoring.resolve(
            baseTop: navBottom, baseBottom: keyboardUpBottom,
            insetBottom: 438, height: keyboardUpBottom - navBottom)
        let down = CommandPanelAnchoring.resolve(
            baseTop: navBottom, baseBottom: keyboardDownBottom,
            insetBottom: 94, height: keyboardDownBottom - navBottom)
        #expect(down.availableHeight == 637)
        #expect(down.availableHeight > up.availableHeight)
        #expect(down.bottomPadding == 94)
        #expect(keyboardDownBottom - down.availableHeight == navBottom + 8)
    }

    @Test func aTallerComposerShrinksTheCardFromTheSameTopEdge() {
        // The composer expanded by 4 pt in the 19:27 diagnostic.
        let anchor = CommandPanelAnchoring.resolve(
            baseTop: navBottom, baseBottom: 410,
            insetBottom: 442, height: 297)
        #expect(anchor.availableHeight == 289)
        #expect(410 - anchor.availableHeight == navBottom + 8)
    }

    @Test func beforeTheTimelineIsMeasuredTheProxyHeightIsTheFallback() {
        let anchor = CommandPanelAnchoring.resolve(
            baseTop: nil, baseBottom: nil, insetBottom: 438, height: 301)
        #expect(anchor.availableHeight == 293)
        #expect(anchor.bottomPadding == 438)
    }

    @Test func anInvertedFrameFallsBackInsteadOfGoingNegative() {
        let anchor = CommandPanelAnchoring.resolve(
            baseTop: 700, baseBottom: 690, insetBottom: 162, height: 100)
        #expect(anchor.availableHeight == 92)
        #expect(anchor.bottomPadding == 162)
    }
}

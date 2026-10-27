import Foundation
import Testing
@testable import ClientCore

/// Pins the placement → offset formulas against the official tri-state
/// (`CANONICAL/05-layout-scroll.md` §6.2): rows resolve from their start, the
/// reading anchor compensates a prepend by construction, and `.end` uses the
/// shared bottom formula. Expectations are literals so a sign or inset change
/// turns these red.

@Suite struct TimelineAnchorPlacementTests {
    private func geometry(rows: [String: CGFloat],
                          contentHeight: CGFloat = 2000,
                          containerHeight: CGFloat = 800,
                          topInset: CGFloat = 60,
                          bottomInset: CGFloat = 100) -> TimelineAnchorGeometry {
        TimelineAnchorGeometry(
            contentHeight: contentHeight,
            containerHeight: containerHeight,
            topInset: topInset,
            bottomInset: bottomInset,
            rowStart: { rows[$0] },
            readingAnchor: { offset in
                let sorted = rows.sorted { $0.value < $1.value }
                guard let row = sorted.last(where: { $0.value <= offset + topInset })
                else { return nil }
                return (row.key, offset + topInset - row.value)
            })
    }

    @Test func rowPlacementPutsTheRowTopAtTheViewportTop() {
        let placement = TimelineAnchorPlacement.row(id: "u2")
        #expect(placement.target(in: geometry(rows: ["u2": 640])) == 580)
    }

    @Test func rowPlacementNeedsTheRowInTheWindow() {
        let placement = TimelineAnchorPlacement.row(id: "gone")
        #expect(placement.target(in: geometry(rows: [:])) == nil)
    }

    @Test func readingPlacementAddsTheOffsetIntoTheRow() {
        let placement = TimelineAnchorPlacement.reading(id: "a1", offsetIntoRow: 40)
        #expect(placement.target(in: geometry(rows: ["a1": 1200])) == 1180)
    }

    @Test func aPrependMovesTheTargetByExactlyThePrependHeight() {
        // The reader is 40 pt into a row that starts at 1200; 500 pt of older
        // content arrives above it. The resolved offset must grow by 500, so
        // the same text stays under the viewport top.
        let before = TimelineAnchorPlacement.reading(id: "a1", offsetIntoRow: 40)
            .target(in: geometry(rows: ["a1": 1200]))
        let after = TimelineAnchorPlacement.reading(id: "a1", offsetIntoRow: 40)
            .target(in: geometry(rows: ["a1": 1700]))
        #expect(before == 1180)
        #expect(after == 1680)
    }

    @Test func endPlacementUsesTheSharedBottomFormula() {
        // 2000 + 100 − 800 = 1300.
        #expect(TimelineAnchorPlacement.end
            .target(in: geometry(rows: [:])) == 1300)
    }

    @Test func subViewportContentRestsAtTheTopInset() {
        // Shorter than the visible height: the bottom target is −topInset.
        let short = geometry(rows: [:], contentHeight: 400)
        #expect(TimelineAnchorPlacement.end.target(in: short) == -60)
    }

    @Test func theBottomTestAllowsOnePhysicalPixel() {
        let geometry = geometry(rows: [:], contentHeight: 2000)
        let end = geometry.endOffset
        #expect(end == 1300)
        #expect(geometry.isAtEnd(offset: end, displayScale: 3))
        // One pixel at 3× is 0.333…; a third of a point short is still inside
        // the dead band, half a point is not.
        #expect(geometry.isAtEnd(offset: end - 0.2, displayScale: 3))
        #expect(!geometry.isAtEnd(offset: end - 0.5, displayScale: 3))
    }
}

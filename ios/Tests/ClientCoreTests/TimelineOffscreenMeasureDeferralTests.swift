import CoreGraphics
import Testing
@testable import ClientCore

/// First measurements of never-displayed rows must not re-lay the visible band
/// while the reader is dragging or coasting.
@Suite struct TimelineOffscreenMeasureDeferralTests {
    @Test func firstMeasureAboveTheViewportParksDuringBrowsing() {
        #expect(TimelineOffscreenMeasureDeferral.shouldPark(
            isBrowsing: true, isInsideUpdate: false, hasEverBeenDisplayed: false,
            cellMaxY: 99, viewportTop: 100))
    }

    @Test func firstMeasureAtOrBelowTheViewportAppliesNow() {
        #expect(!TimelineOffscreenMeasureDeferral.shouldPark(
            isBrowsing: true, isInsideUpdate: false, hasEverBeenDisplayed: false,
            cellMaxY: 100, viewportTop: 100))
        #expect(!TimelineOffscreenMeasureDeferral.shouldPark(
            isBrowsing: true, isInsideUpdate: false, hasEverBeenDisplayed: false,
            cellMaxY: 300, viewportTop: 100))
    }

    @Test func displayedRowsKeepTheirLiveCorrections() {
        #expect(!TimelineOffscreenMeasureDeferral.shouldPark(
            isBrowsing: true, isInsideUpdate: false, hasEverBeenDisplayed: true,
            cellMaxY: 20, viewportTop: 100))
    }

    @Test func idleRemainsImmediate() {
        #expect(!TimelineOffscreenMeasureDeferral.shouldPark(
            isBrowsing: false, isInsideUpdate: false, hasEverBeenDisplayed: false,
            cellMaxY: 20, viewportTop: 100))
    }

    @Test func updateTransactionsKeepTheirOwnGeometry() {
        #expect(!TimelineOffscreenMeasureDeferral.shouldPark(
            isBrowsing: true, isInsideUpdate: true, hasEverBeenDisplayed: false,
            cellMaxY: 20, viewportTop: 100))
    }
}

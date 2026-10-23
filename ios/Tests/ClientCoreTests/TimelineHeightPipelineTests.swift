import Foundation
import Testing
@testable import ClientCore

/// Phase 1 of the official height pipeline: the pure decisions the layout
/// applies for hosted-cell height reports and for outside-transaction offset
/// compensation. The layout itself is UIKit and lives in the app target, so
/// only the decision rules are exercised here.
@Suite struct TimelineHeightPipelineTests {
    @Test func hostedHeightChangeParksVisibleRowsUnderTheFinger() {
        #expect(TimelinePreferredAttributesDecision.hostedHeightChange(
            isVisible: true, isUserScrolling: true) == .deferUntilSettled)
        #expect(TimelinePreferredAttributesDecision.hostedHeightChange(
            isVisible: false, isUserScrolling: true) == .accept)
        #expect(TimelinePreferredAttributesDecision.hostedHeightChange(
            isVisible: true, isUserScrolling: false) == .accept)
        #expect(TimelinePreferredAttributesDecision.hostedHeightChange(
            isVisible: false, isUserScrolling: false) == .accept)
    }

    @Test func heightChangeCorrectionOnlyCompensatesRowsAboveTheViewport() {
        // Partially visible (top above the viewport): the reader's text below
        // moves, so the offset takes the whole delta.
        #expect(TimelinePreferredAttributesDecision.heightChangeCorrection(
            delta: 12, cellMinY: 100, viewportTop: 300) == 12)
        // Top exactly at the viewport top is not above it.
        #expect(TimelinePreferredAttributesDecision.heightChangeCorrection(
            delta: 12, cellMinY: 300, viewportTop: 300) == nil)
        // Below the viewport: nothing displayed moves.
        #expect(TimelinePreferredAttributesDecision.heightChangeCorrection(
            delta: -12, cellMinY: 900, viewportTop: 300) == nil)
        // A zero change has no compensation.
        #expect(TimelinePreferredAttributesDecision.heightChangeCorrection(
            delta: 0, cellMinY: 0, viewportTop: 300) == nil)
    }

    @Test func heightChangeAffectsVisibleRows() {
        // Intersecting the viewport: the row itself is visible.
        #expect(TimelinePreferredAttributesDecision.heightChangeAffectsVisibleRows(
            cellMinY: 250, cellMaxY: 350, contentHeight: 2000,
            viewportTop: 300, viewportBottom: 900))
        // Entirely above: the rows below it are visible and move.
        #expect(TimelinePreferredAttributesDecision.heightChangeAffectsVisibleRows(
            cellMinY: 100, cellMaxY: 200, contentHeight: 2000,
            viewportTop: 300, viewportBottom: 900))
        // Entirely above but no content reaches the viewport: nothing moves.
        #expect(!TimelinePreferredAttributesDecision.heightChangeAffectsVisibleRows(
            cellMinY: 100, cellMaxY: 200, contentHeight: 250,
            viewportTop: 300, viewportBottom: 900))
        // Entirely below: no displayed row moves.
        #expect(!TimelinePreferredAttributesDecision.heightChangeAffectsVisibleRows(
            cellMinY: 950, cellMaxY: 1050, contentHeight: 2000,
            viewportTop: 300, viewportBottom: 900))
    }
}

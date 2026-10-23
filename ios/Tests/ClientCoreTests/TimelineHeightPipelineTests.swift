import Foundation
import Testing
@testable import ClientCore

/// Phase 1 of the official height pipeline: the pure decisions the layout
/// applies for hosted-cell height reports and for outside-transaction offset
/// compensation. The layout itself is UIKit and lives in the app target, so
/// only the decision rules are exercised here.
@Suite struct TimelineHeightPipelineTests {

    @Test func heightChangeCorrectionFollowsThePlacementAnchor() {
        // Entirely above the anchor (the row containing the viewport top):
        // everything visible moves, so the offset takes the whole delta.
        #expect(TimelinePreferredAttributesDecision.heightChangeCorrection(
            delta: 12, cellMaxY: 100, viewportTop: 300) == 12)
        // The anchor row itself: it grows downward, the offset stays. The
        // device gate caught the old rule throwing the row off the top.
        #expect(TimelinePreferredAttributesDecision.heightChangeCorrection(
            delta: 12, cellMaxY: 350, viewportTop: 300) == nil)
        // Entirely below the viewport: nothing displayed moves.
        #expect(TimelinePreferredAttributesDecision.heightChangeCorrection(
            delta: -12, cellMaxY: 900, viewportTop: 300) == nil)
        // A zero change has no compensation.
        #expect(TimelinePreferredAttributesDecision.heightChangeCorrection(
            delta: 0, cellMaxY: 100, viewportTop: 300) == nil)
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

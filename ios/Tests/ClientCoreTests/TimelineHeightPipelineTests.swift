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

    @Test func officialEstimateMatchesTheReverseEngineeredFormula() {
        // Official `SessionRowHeightEstimator` (0x10253deec): lines ×
        // lineHeight × 0.9, floored at 44 pt.
        #expect(TimelineHeightEstimate.officialEstimate(lines: 10, lineHeight: 20) == 180)
        #expect(TimelineHeightEstimate.officialEstimate(lines: 1, lineHeight: 20) == 44)
        #expect(TimelineHeightEstimate.officialEstimate(lines: 0, lineHeight: 20) == 44)
        // The constants the caller applies to the line count.
        #expect(TimelineHeightEstimate.officialWidthCap == 580)
        #expect(TimelineHeightEstimate.officialLineCap == 15)
        #expect(TimelineHeightEstimate.officialFactor == 0.9)
        #expect(TimelineHeightEstimate.officialMinimum == 44)
    }

    @Test func codeFirstFrameEstimateChargesLeadingOnlyBetweenLines() {
        // The Code page's measured layout gives the first line the body
        // font's natural line box (Anthropic Sans 17 pt: 21.25) and adds the
        // 5.95 pt leading *between* lines; the row plan owns the gap between
        // blocks. The historical arithmetic billed a full `body + lineSpacing`
        // line plus a 0.6 × paragraph gap, so a one-line message seeded 34 pt
        // against a 21–22 pt line. The follower sprang forward on that seed
        // and the cell's report pulled it back: `timeline.mover` start 44 →
        // arrived 15 pt under target on every new assistant message
        // (pp 2026-11-16, b1262/b1266 logs).
        let historical = TimelineHeightEstimate.height(
            rows: [.init(text: "看完了")], width: 361,
            bodySize: 17, lineSpacing: 5.95, paragraphSpacing: 17,
            minimum: 0, cushion: 1)
        #expect(historical == 34)

        let code = TimelineHeightEstimate.height(
            rows: [.init(text: "看完了")], width: 361,
            bodySize: 17, lineSpacing: 5.95, paragraphSpacing: 17,
            minimum: 0, cushion: 1,
            firstLineHeight: 21.25, countsParagraphSpacing: false)
        #expect(code == 22)

        // Wrapped lines add the full pitch, not just the body size: the
        // leading sits between lines.
        let wrappedText = TimelineHeightEstimate.height(
            rows: [.init(text: String(repeating: "字", count: 60))], width: 240,
            bodySize: 17, lineSpacing: 5.95, paragraphSpacing: 17,
            minimum: 0, cushion: 1,
            firstLineHeight: 21.25, countsParagraphSpacing: false)
        // 240 / (17 × 0.55) = 25 CJK units per line → 60 wide scalars = 120
        // units → 5 lines → 21.25 + 4 × 22.95 = 113.05 → 114.
        #expect(wrappedText == 114)
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

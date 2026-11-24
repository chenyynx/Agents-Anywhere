import CoreGraphics
import Testing
@testable import ClientCore

/// The apply's synchronous measurement pass. Opening a long window used to
/// measure every unmeasured row before the first frame; only the tail the
/// reader lands on belongs in that pass.
@Suite struct TimelineSynchronousMeasurementSelectionTests {
    private func selected(count: Int,
                          tailLimit: Int = TimelineSynchronousMeasurementSelection.openingTailLimit,
                          needs: (Int) -> Bool = { _ in true },
                          maxY: (Int) -> CGFloat? = { _ in nil },
                          skipAbove: CGFloat = 0) -> [Int] {
        (0..<count).filter { index in
            TimelineSynchronousMeasurementSelection.shouldMeasure(
                index: index,
                itemCount: count,
                needsMeasurement: needs(index),
                attributesMaxY: maxY(index),
                skipAbove: skipAbove,
                tailLimit: tailLimit)
        }
    }

    @Test func attributeLessOpeningMeasuresOnlyTheTail() {
        #expect(selected(count: 100, tailLimit: 24) == Array(76..<100))
    }

    @Test func attributeLessTailIsEmptyWhenTheLimitIsZero() {
        #expect(selected(count: 100, tailLimit: 0).isEmpty)
    }

    @Test func attributeLessWindowSmallerThanTheLimitMeasuresEveryRow() {
        #expect(selected(count: 10, tailLimit: 24) == Array(0..<10))
    }

    @Test func rowsThatNeedNoMeasurementAreNeverSelected() {
        #expect(selected(count: 100, needs: { _ in false }).isEmpty)
    }

    /// Attributes exist: the viewport rule decides, not the tail index. A
    /// changed tall row above the skip line keeps its estimate.
    @Test func attributesAboveTheSkipLineKeepTheirEstimate() {
        let result = selected(count: 100,
                              maxY: { $0 < 50 ? 99 : 100 },
                              skipAbove: 100)
        #expect(result == Array(50..<100))
    }

    /// A row exactly at the skip line is still measured; the rule is "above".
    @Test func rowAtTheSkipLineIsMeasured() {
        #expect(selected(count: 1, maxY: { _ in 100 }, skipAbove: 100) == [0])
    }

    /// Rows with attributes never fall back to the tail rule: the tail is a
    /// first-layout fallback, not an extra allowance after one exists.
    @Test func attributeRowsOutsideTheTailStillUseTheViewportRule() {
        let result = selected(count: 100,
                              tailLimit: 24,
                              maxY: { index in index == 0 ? 500 : 10 },
                              skipAbove: 100)
        #expect(result == [0])
    }
}

import CoreGraphics
import Testing
@testable import ClientCore

@Suite struct TimelineInsertionOwedTests {
    private func layout(firstRowID: String, y: CGFloat) -> TimelineHistoryLayout {
        TimelineHistoryLayout(firstRowID: firstRowID,
                              anchorRowID: "row-anchor", edge: .top, y: y)
    }

    private func owed() -> TimelineInsertionOwed {
        TimelineInsertionOwed(generation: 1,
                              origin: layout(firstRowID: "row-1", y: 100),
                              offsetY: 40, topInset: 0)
    }

    @Test func aPrependRecordsThePageItBelongsTo() {
        var owed = owed()
        let target = owed.update(layout: layout(firstRowID: "older-1", y: 500))
        #expect(target == CGFloat(440))
        #expect(owed.expectedFirstRowID == "older-1")
    }

    @Test func anUpdateWithoutAPrependLeavesTheTargetUnrecorded() {
        var owed = owed()
        #expect(owed.update(layout: layout(firstRowID: "row-1", y: 120)) == nil)
        #expect(owed.expectedFirstRowID == nil)
    }

    @Test func theTargetStaysOfferedForTheSameTransaction() {
        var owed = owed()
        _ = owed.update(layout: layout(firstRowID: "older-1", y: 500))
        #expect(owed.targetOffset(proposed: 10) == CGFloat(440))
        #expect(owed.targetOffset(proposed: 10) == CGFloat(440))
        #expect(owed.finalizeFallback() == nil)
    }

    @Test func anUnqueriedTargetBecomesTheFinalizeFallback() {
        var owed = owed()
        _ = owed.update(layout: layout(firstRowID: "older-1", y: 500))
        #expect(owed.finalizeFallback() == CGFloat(440))
        #expect(owed.finalizeFallback() == nil)
    }
}

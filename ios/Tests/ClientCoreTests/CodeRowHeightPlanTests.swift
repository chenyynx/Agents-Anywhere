import Foundation
import Testing
@testable import ClientCore

// The Code row's vertical arithmetic. Device probe 2026-10-23 measured a
// tool-only row at 52 pt while the old estimate reserved 54: the estimate used
// the unscaled 24 pt line box while `@ScaledMetric(relativeTo: .footnote)`
// scaled it to 22 pt at the device's text size. Every such row then shrank by
// 2 pt on first display, shifting everything below it while the reader
// scrolled. These tests pin the plan to the row view's real structure:
//
//   no block padding, block spacing 8, row spacing 10, margins 10,
//   collapsed tool row = line box + 2 x 6 pt button padding.
//
// The turn's working status is no longer part of a message row: it is its own
// transcript row (`CodeWorkingStatusRow`), so this plan has no status branch.

@Suite struct CodeRowHeightPlanTests {
    private let metrics = CodeRowHeightPlan.Metrics(
        blockSpacing: 8,
        rowSpacing: 10,
        toolLineHeight: 24,
        toolButtonPadding: 6,
        otherLineHeight: 24,
        rowMargins: 10)

    @Test func singleToolRowMatchesTheRenderedHeight() {
        let row = CodeRowHeightPlan.Row(blocks: [.tools(segments: 1)])
        // (24 + 12) button row + 10 margins; no block padding.
        #expect(CodeRowHeightPlan.height(rows: [row], metrics: metrics) == 46)
    }

    @Test func scaledLineBoxIsTheOnlyDeviceDifference() {
        var scaled = metrics
        scaled.toolLineHeight = 22 // @ScaledMetric at the probe's text size
        let row = CodeRowHeightPlan.Row(blocks: [.tools(segments: 1)])
        #expect(CodeRowHeightPlan.height(rows: [row], metrics: scaled) == 44)
    }

    @Test func parallelToolCallsPayOneButtonRowEach() {
        let row = CodeRowHeightPlan.Row(blocks: [.tools(segments: 3)])
        // One line box per segment, no per-block padding.
        #expect(CodeRowHeightPlan.height(rows: [row], metrics: metrics) == CGFloat(3 * 36 + 10))
    }

    @Test func textBlocksMeasureTheirOwnHeight() {
        let row = CodeRowHeightPlan.Row(blocks: [
            .text(height: 100),
            .tools(segments: 1),
        ])
        // 100, 8 between blocks, 36, 10 margins.
        #expect(CodeRowHeightPlan.height(rows: [row], metrics: metrics) == 154)
    }

    @Test func multipleRenderedRowsAddRowSpacing() {
        let first = CodeRowHeightPlan.Row(blocks: [.text(height: 50)])
        let second = CodeRowHeightPlan.Row(blocks: [.text(height: 70)])
        // 50 + 10 + 70 + 10.
        #expect(CodeRowHeightPlan.height(rows: [first, second], metrics: metrics) == 140)
    }

    @Test func emptyRowsContributeNothing() {
        let empty = CodeRowHeightPlan.Row(blocks: [])
        #expect(CodeRowHeightPlan.height(rows: [empty], metrics: metrics) == 10)
    }

    @Test func genericRowUsesTheUnscaledLineBox() {
        let row = CodeRowHeightPlan.Row(blocks: [.other])
        #expect(CodeRowHeightPlan.height(rows: [row], metrics: metrics) == CGFloat(24 + 10))
    }
}

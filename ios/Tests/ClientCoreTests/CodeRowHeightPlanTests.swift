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
//   block padding 8, block spacing 4, row spacing 16, margins 10,
//   collapsed tool row = line box + 2 x 6 pt button padding.

@Suite struct CodeRowHeightPlanTests {
    private let metrics = CodeRowHeightPlan.Metrics(
        blockPadding: 8,
        blockSpacing: 4,
        rowSpacing: 16,
        toolLineHeight: 24,
        toolButtonPadding: 6,
        otherLineHeight: 24,
        statusLineHeight: 28,
        rowMargins: 10)

    @Test func singleToolRowMatchesTheRenderedHeight() {
        let row = CodeRowHeightPlan.Row(blocks: [.tools(segments: 1)])
        // 8 block padding + (24 + 12) button row + 10 margins.
        #expect(CodeRowHeightPlan.height(rows: [row], showsWorkingStatus: false,
                                         metrics: metrics) == 54)
    }

    @Test func scaledLineBoxIsTheOnlyDeviceDifference() {
        var scaled = metrics
        scaled.toolLineHeight = 22 // @ScaledMetric at the probe's text size
        let row = CodeRowHeightPlan.Row(blocks: [.tools(segments: 1)])
        #expect(CodeRowHeightPlan.height(rows: [row], showsWorkingStatus: false,
                                         metrics: scaled) == 52)
    }

    @Test func parallelToolCallsPayOneButtonRowEach() {
        let row = CodeRowHeightPlan.Row(blocks: [.tools(segments: 3)])
        // The block's padding is paid once, not per segment.
        #expect(CodeRowHeightPlan.height(rows: [row], showsWorkingStatus: false,
                                         metrics: metrics) == 8 + 3 * 36 + 10)
    }

    @Test func textBlocksMeasureTheirOwnHeight() {
        let row = CodeRowHeightPlan.Row(blocks: [
            .text(height: 100),
            .tools(segments: 1),
        ])
        // 100 + 8, 4 between blocks, 36 + 8, 10 margins.
        #expect(CodeRowHeightPlan.height(rows: [row], showsWorkingStatus: false,
                                         metrics: metrics) == 166)
    }

    @Test func multipleRenderedRowsAddBlockSpacing() {
        let first = CodeRowHeightPlan.Row(blocks: [.text(height: 50)])
        let second = CodeRowHeightPlan.Row(blocks: [.text(height: 70)])
        // 58 + 16 + 78 + 10.
        #expect(CodeRowHeightPlan.height(rows: [first, second], showsWorkingStatus: false,
                                         metrics: metrics) == 162)
    }

    @Test func statusLineAddsItsOwnRowAndSpacing() {
        let row = CodeRowHeightPlan.Row(blocks: [.tools(segments: 1)])
        let withStatus = CodeRowHeightPlan.height(rows: [row], showsWorkingStatus: true,
                                                  metrics: metrics)
        #expect(withStatus == 54 + 16 + 28)

        // A reasoning-only owner row renders just the status line.
        let statusOnly = CodeRowHeightPlan.height(rows: [], showsWorkingStatus: true,
                                                  metrics: metrics)
        #expect(statusOnly == 38)
    }

    @Test func emptyRowsContributeNothing() {
        let empty = CodeRowHeightPlan.Row(blocks: [])
        #expect(CodeRowHeightPlan.height(rows: [empty], showsWorkingStatus: false,
                                         metrics: metrics) == 10)
    }

    @Test func genericRowUsesTheUnscaledLineBox() {
        let row = CodeRowHeightPlan.Row(blocks: [.other])
        #expect(CodeRowHeightPlan.height(rows: [row], showsWorkingStatus: false,
                                         metrics: metrics) == 24 + 8 + 10)
    }
}

import Testing
@testable import ClientCore

/// The footer height is installed as a constraint on the TextKit cell and
/// added to the document measurement. These are the legacy group's numbers,
/// so a drift here would change the row height without any visual change in
/// the footer itself.
@Suite struct AssistantFooterMetricsTests {
    private let actionRow: CGFloat = 43.5

    @Test func actionsOnlyMatchesTheLegacyFooter() {
        // 4pt group spacing + the action row, the shape M3.1 shipped.
        #expect(AssistantFooterMetrics.contentHeight(
            hasReview: false, hasReplies: true,
            actionRowHeight: actionRow) == actionRow)
        #expect(AssistantFooterMetrics.totalHeight(
            hasReview: false, hasReplies: true,
            actionRowHeight: actionRow) == 4 + actionRow)
    }

    @Test func reviewOnlyIsTheFixedSummaryRow() {
        #expect(AssistantFooterMetrics.contentHeight(
            hasReview: true, hasReplies: false,
            actionRowHeight: actionRow) == 44)
        #expect(AssistantFooterMetrics.totalHeight(
            hasReview: true, hasReplies: false,
            actionRowHeight: actionRow) == 4 + 44)
    }

    @Test func reviewAndActionsKeepTheGroupSpacingBetweenThem() {
        #expect(AssistantFooterMetrics.contentHeight(
            hasReview: true, hasReplies: true,
            actionRowHeight: actionRow) == 44 + 4 + actionRow)
        #expect(AssistantFooterMetrics.totalHeight(
            hasReview: true, hasReplies: true,
            actionRowHeight: actionRow) == 4 + 44 + 4 + actionRow)
    }

    @Test func anEmptyFooterAddsNothing() {
        #expect(AssistantFooterMetrics.contentHeight(
            hasReview: false, hasReplies: false,
            actionRowHeight: actionRow) == 0)
        #expect(AssistantFooterMetrics.totalHeight(
            hasReview: false, hasReplies: false,
            actionRowHeight: actionRow) == 0)
    }
}

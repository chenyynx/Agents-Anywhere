import CoreGraphics
import Testing
@testable import ClientCore

/// The footer height is installed as a constraint on the TextKit cell and
/// added to the document measurement. These are the legacy group's numbers,
/// so a drift here would change the row height without any visual change in
/// the footer itself.
@Suite struct AssistantFooterMetricsTests {
    // CGFloat-typed expectations: `#expect` compares the two sides as Any when
    // their static types differ, and a CGFloat 48.0 never equals an Int 48.
    private let actionRow: CGFloat = 43.5
    private let groupSpacing: CGFloat = 4
    private let reviewRow: CGFloat = 44
    private let zero: CGFloat = 0

    @Test func actionsOnlyMatchesTheLegacyFooter() {
        // 4pt group spacing + the action row, the shape M3.1 shipped.
        #expect(AssistantFooterMetrics.contentHeight(
            hasReview: false, hasReplies: true,
            actionRowHeight: actionRow) == actionRow)
        #expect(AssistantFooterMetrics.totalHeight(
            hasReview: false, hasReplies: true,
            actionRowHeight: actionRow) == groupSpacing + actionRow)
    }

    @Test func reviewOnlyIsTheFixedSummaryRow() {
        #expect(AssistantFooterMetrics.contentHeight(
            hasReview: true, hasReplies: false,
            actionRowHeight: actionRow) == reviewRow)
        #expect(AssistantFooterMetrics.totalHeight(
            hasReview: true, hasReplies: false,
            actionRowHeight: actionRow) == groupSpacing + reviewRow)
    }

    @Test func reviewAndActionsKeepTheGroupSpacingBetweenThem() {
        #expect(AssistantFooterMetrics.contentHeight(
            hasReview: true, hasReplies: true,
            actionRowHeight: actionRow) == reviewRow + groupSpacing + actionRow)
        #expect(AssistantFooterMetrics.totalHeight(
            hasReview: true, hasReplies: true,
            actionRowHeight: actionRow) == groupSpacing + reviewRow + groupSpacing + actionRow)
    }

    @Test func anEmptyFooterAddsNothing() {
        #expect(AssistantFooterMetrics.contentHeight(
            hasReview: false, hasReplies: false,
            actionRowHeight: actionRow) == zero)
        #expect(AssistantFooterMetrics.totalHeight(
            hasReview: false, hasReplies: false,
            actionRowHeight: actionRow) == zero)
    }
}

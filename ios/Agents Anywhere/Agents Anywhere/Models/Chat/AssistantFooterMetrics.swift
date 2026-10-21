import Foundation

/// Height constants for the TextKit cell's footer.
///
/// The legacy group stacks its footer in a `VStack(spacing: 4)` after the
/// reply: the file-change summary (44pt minimum) and then the action row.
/// The TextKit path installs those same numbers as constraints; it never
/// fits the hosted view, so a late layout pass cannot change the row height.
nonisolated enum AssistantFooterMetrics {
    /// `SessionTimelineGroupView`'s VStack spacing between the reply, the
    /// review summary and the action row.
    static let groupSpacing: CGFloat = 4

    /// `SessionTurnReviewFooter`'s summary row is a button with
    /// `.frame(minHeight: 44)` and one line of footnote text.
    static let reviewRowHeight: CGFloat = 44

    /// The footer view's own height, excluding the spacing the cell installs
    /// between the reply and this view.
    static func contentHeight(hasReview: Bool,
                              hasReplies: Bool,
                              actionRowHeight: CGFloat) -> CGFloat {
        var height: CGFloat = 0
        if hasReview { height += reviewRowHeight }
        if hasReplies {
            if hasReview { height += groupSpacing }
            height += actionRowHeight
        }
        return height
    }

    /// What the controller adds to the document measurement.
    static func totalHeight(hasReview: Bool,
                            hasReplies: Bool,
                            actionRowHeight: CGFloat) -> CGFloat {
        guard hasReview || hasReplies else { return 0 }
        return groupSpacing
            + contentHeight(hasReview: hasReview, hasReplies: hasReplies,
                            actionRowHeight: actionRowHeight)
    }
}

import Foundation

/// Pure translation between a timeline's measured geometry and the content
/// offset that rests at its bottom.
///
/// `UIScrollView` reports the resting bottom as
/// `contentHeight - containerHeight + bottomInset`; when the content is shorter
/// than the visible area that value falls above the reader's resting top
/// (`-topInset`), so it is clamped there instead of producing a negative
/// overscroll. `TimelineHistoryPosition` uses the same clamp for its origin
/// (`max(-topInset, offsetY)`), and the two must agree or a prepended page
/// would land with a residual jump.
nonisolated enum TimelineOffsetTarget {
    static func restingTopOffset(topInset: CGFloat) -> CGFloat { -topInset }

    static func visibleHeight(containerHeight: CGFloat, topInset: CGFloat, bottomInset: CGFloat) -> CGFloat {
        max(0, containerHeight - topInset - bottomInset)
    }

    static func isSubViewport(contentHeight: CGFloat, containerHeight: CGFloat,
                              topInset: CGFloat, bottomInset: CGFloat) -> Bool {
        contentHeight <= visibleHeight(containerHeight: containerHeight, topInset: topInset, bottomInset: bottomInset)
    }

    static func bottomOffset(contentHeight: CGFloat, containerHeight: CGFloat,
                             topInset: CGFloat, bottomInset: CGFloat) -> CGFloat {
        let restingTop = restingTopOffset(topInset: topInset)
        guard !isSubViewport(contentHeight: contentHeight, containerHeight: containerHeight,
                              topInset: topInset, bottomInset: bottomInset) else { return restingTop }
        return max(restingTop, contentHeight - containerHeight + bottomInset)
    }

    static func clamped(_ proposed: CGFloat, contentHeight: CGFloat, containerHeight: CGFloat,
                        topInset: CGFloat, bottomInset: CGFloat) -> CGFloat {
        let bottom = bottomOffset(contentHeight: contentHeight, containerHeight: containerHeight,
                                  topInset: topInset, bottomInset: bottomInset)
        return min(max(proposed, restingTopOffset(topInset: topInset)), bottom)
    }
}

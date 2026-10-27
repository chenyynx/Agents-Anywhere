import CoreGraphics

/// The official transcript's placement tri-state
/// (`CANONICAL/05-layout-scroll.md` §6.2): a named row pinned to the top, a
/// reading anchor inside a row, or the content bottom.
///
/// Placement is the only source of the scroll target in the anchor model. The
/// official reducer never stores an offset: it re-resolves the target from the
/// current placement every time, which is what makes a prepend (or a height
/// correction above the viewport) compensate itself.
nonisolated enum TimelineAnchorPlacement: Equatable {
    /// The row's top edge sits at the viewport top (official `.row(id, .top)`),
    /// e.g. the reader's own message after sending.
    case row(id: String)

    /// The row's top edge sits `offsetIntoRow` points above the viewport top
    /// (official `.reading(row, offsetIntoRow)`). A reader gesture records
    /// this; a prepend moves the row's start and the resolved target moves
    /// with it, so the visible text stays put.
    case reading(id: String, offsetIntoRow: CGFloat)

    /// Follow the content bottom (official `.end`).
    case end

    /// The scroll offset that satisfies this placement, or nil when the row
    /// it names is no longer in the window (the driver then repairs the
    /// placement from the live viewport).
    func target(in geometry: TimelineAnchorGeometry) -> CGFloat? {
        switch self {
        case .row(let id):
            guard let start = geometry.rowStart(id) else { return nil }
            return start - geometry.topInset
        case .reading(let id, let offsetIntoRow):
            guard let start = geometry.rowStart(id) else { return nil }
            return start + offsetIntoRow - geometry.topInset
        case .end:
            return geometry.endOffset
        }
    }
}

/// One row's content-space top edge. Rows are kept sorted by `start` so the
/// viewport-top lookup is a binary search.
nonisolated struct TimelineAnchorRow: Equatable {
    var id: String
    var start: CGFloat
}

/// A snapshot of everything a placement resolves against. Scalars and lookups
/// only; the driver builds it from the layout without copying row geometry.
nonisolated struct TimelineAnchorGeometry {
    var contentHeight: CGFloat
    var containerHeight: CGFloat
    var topInset: CGFloat
    var bottomInset: CGFloat
    /// Content-space top of a row, or nil when the row is not in the window.
    var rowStart: (String) -> CGFloat?
    /// The row under the viewport top and how far into it the top sits
    /// (official `readerBeganDragging` derives the same anchor).
    var readingAnchor: (CGFloat) -> (id: String, offsetIntoRow: CGFloat)?

    /// The `.end` target. Delegates to the same bottom formula the rest of
    /// the timeline uses, so sub-viewport content rests at `-topInset`.
    var endOffset: CGFloat {
        TimelineOffsetTarget.bottomOffset(
            contentHeight: contentHeight,
            containerHeight: containerHeight,
            topInset: topInset,
            bottomInset: bottomInset)
    }

    /// The official bottom test (`viewport[4] <= maxOffset − offset`,
    /// `0x1019e27bc`), reduced to the one-pixel dead band the official Mover
    /// uses elsewhere: a reader within one physical pixel of the end is at
    /// the end.
    func isAtEnd(offset: CGFloat, displayScale: CGFloat) -> Bool {
        let pixel = 1 / max(1, displayScale)
        return offset >= endOffset - pixel
    }
}

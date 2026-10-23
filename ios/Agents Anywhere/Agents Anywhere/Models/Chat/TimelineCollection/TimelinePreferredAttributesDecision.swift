import Foundation

/// The controlled exceptions whose height the controller keeps polling after
/// a fold/notice/tail reconfigure. Independent of the cell's one-time
/// self-measure: that is gated by the row's measured state, not this policy.
nonisolated enum TimelineRowHeightPolicy: Equatable {
    case measured
    /// Fold expansion, inline notice card, and other interactive row content.
    case interactive
    /// Queue/status block whose 12↔32 animation must not be clipped.
    case tail

    var acceptsPreferredHeight: Bool { self != .measured }
}

/// The two correction categories of the collection layout, kept apart because
/// they answer different questions and have different guards.
///
/// **A — pending measurement.** The row was applied before its measurement
/// finished. Measured height is the truth; the only question is whether the
/// content offset must move by the delta so the reader's visible text stays
/// put. A row whose top is above the viewport top — including a partially
/// visible one — moves the content below it, so it must be compensated. The
/// spike measured a 105pt jump when partially visible rows were excluded.
///
/// **B — cell self-sizing (controlled exceptions).** Fold, inline notice and
/// tail rows may grow from inside the cell. These follow OpenMinis's three
/// branches: fully above the viewport, visible and non-streaming, or streaming
/// while the bottom is pinned. Everything else updates height without moving
/// the offset and is corrected on the next settled frame.
///
/// Browsing defer: while the reader drags or decelerates, a cached row's
/// shrink or stable correction is parked until deceleration ends; growth is
/// allowed so the row never clips or overlaps; an uncached row may take its
/// first measurement.
nonisolated struct TimelinePreferredAttributesDecision: Equatable {
    enum Height: Equatable {
        case accept
        case deferUntilSettled
    }

    let height: Height
    /// Offset delta to apply in the same layout pass. `nil` means the height
    /// update is applied without moving the content.
    let correction: CGFloat?

    static let accept = TimelinePreferredAttributesDecision(height: .accept, correction: nil)
    static let deferred = TimelinePreferredAttributesDecision(height: .deferUntilSettled, correction: nil)

    static func accept(correction: CGFloat?) -> Self {
        guard let correction, correction != 0 else { return .accept }
        return TimelinePreferredAttributesDecision(height: .accept, correction: correction)
    }

    /// OpenMinis's `scrollMode == .autoScrolling` analogue. A presented
    /// approval card or a reader in `.reading` mode is not pinning.
    static func isAutoScrollPinning(hasArmedBottomTarget: Bool,
                                    interactionPresented: Bool,
                                    userIsScrolling: Bool,
                                    mode: TimelineScrollState.Mode) -> Bool {
        hasArmedBottomTarget && !interactionPresented && !userIsScrolling && mode != .reading
    }

    /// Category A. `delta` is measured height minus the height the layout
    /// currently displays.
    static func pendingMeasurement(delta: CGFloat,
                                   cellMaxY: CGFloat,
                                   viewportTop: CGFloat,
                                   isStreaming: Bool,
                                   isAutoScrollPinning: Bool,
                                   isTracking: Bool,
                                   isDecelerating: Bool,
                                   keyboardTransition: Bool,
                                   suppressContentOffsetAdjustment: Bool,
                                   hasCachedHeight: Bool) -> Self {
        let isBrowsing = isTracking || isDecelerating
        if isBrowsing, hasCachedHeight, delta < 0 { return .deferred }
        if isBrowsing || keyboardTransition || suppressContentOffsetAdjustment { return .accept }
        // The placement anchor is the row that contains the viewport top: a
        // change there grows downward without moving the offset. Only a row
        // entirely above the anchor pushes everything the reader sees.
        if cellMaxY <= viewportTop { return .accept(correction: delta) }
        if isStreaming, isAutoScrollPinning, delta > 0 { return .accept(correction: delta) }
        return .accept
    }

    /// Offset compensation for a height change applied outside an update
    /// transaction, following the official placement anchor: the anchor is the
    /// row that contains the viewport top. Only a row entirely above it
    /// (`cellMaxY <= viewportTop`) pushes the visible content, so only that
    /// change adjusts the offset. A change on the anchor or below grows inside
    /// the layout and leaves the reader's offset alone.
    static func heightChangeCorrection(delta: CGFloat,
                                       cellMaxY: CGFloat,
                                       viewportTop: CGFloat) -> CGFloat? {
        guard delta != 0, cellMaxY <= viewportTop else { return nil }
        return delta
    }

    /// Whether a height change on this row moves anything the reader can see.
    /// The row itself, or any row below it; a row entirely below the viewport
    /// moves nothing visible, and a row entirely above it only matters while
    /// content still reaches into the viewport below.
    static func heightChangeAffectsVisibleRows(cellMinY: CGFloat,
                                               cellMaxY: CGFloat,
                                               contentHeight: CGFloat,
                                               viewportTop: CGFloat,
                                               viewportBottom: CGFloat) -> Bool {
        if cellMaxY <= viewportTop {
            return contentHeight > viewportTop && viewportBottom > viewportTop
        }
        if cellMinY >= viewportBottom {
            return false
        }
        return true
    }

    /// Category B. `delta` is the cell's preferred height minus the layout's
    /// current height.
    static func selfSizing(delta: CGFloat,
                           cellMinY: CGFloat,
                           cellMaxY: CGFloat,
                           viewportTop: CGFloat,
                           viewportBottom: CGFloat,
                           isStreaming: Bool,
                           isAutoScrollPinning: Bool,
                           isTracking: Bool,
                           isDecelerating: Bool,
                           keyboardTransition: Bool,
                           hasCachedHeight: Bool) -> Self {
        let isBrowsing = isTracking || isDecelerating
        if isBrowsing, hasCachedHeight, delta <= 0 { return .deferred }
        if isBrowsing || keyboardTransition { return .accept }
        // 1. Fully above the placement anchor (the row containing the
        //    viewport top): its growth pushes everything the reader sees.
        if cellMaxY <= viewportTop { return .accept(correction: delta) }
        // 2. The anchor row itself and anything below it grow inside the
        //    layout: the reader's offset does not move. The old rule
        //    compensated every visible row, which threw a growing row off the
        //    top of the screen (the device gate measured 388 pt).
        // 3. Streaming while pinned to the bottom: grow and re-pin in the same
        //    frame instead of letting the bottom fall behind.
        if isStreaming, isAutoScrollPinning, delta > 0 { return .accept(correction: delta) }
        // 4. Everything else, including a partially visible non-streaming row:
        //    height applies, offset waits for the next settled correction.
        return .accept
    }
}

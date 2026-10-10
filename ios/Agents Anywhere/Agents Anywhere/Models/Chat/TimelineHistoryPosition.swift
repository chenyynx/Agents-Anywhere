import Foundation

/// One measured, already-rendered group in content coordinates. Measuring the
/// anchor (instead of total content height) excludes simultaneous tail appends.
nonisolated struct TimelineHistoryLayout: Equatable {
    enum Edge { case top, bottom }
    /// The data window's first row — the signal a history page prepend shows.
    let firstRowID: String
    /// The render window's first unit id — the signal a windowed-timeline
    /// expand/shrink shows. Empty when no render window is active.
    let renderFirstRowID: String
    let anchorRowID: String
    let edge: Edge
    let y: CGFloat

    init(firstRowID: String, renderFirstRowID: String = "", anchorRowID: String, edge: Edge, y: CGFloat) {
        self.firstRowID = firstRowID
        self.renderFirstRowID = renderFirstRowID
        self.anchorRowID = anchorRowID
        self.edge = edge
        self.y = y
    }
}

/// A history request stays busy until its page has passed through the 5 Hz
/// presentation buffer and layout. Restoring a point retains the reader's
/// offset inside a long message, unlike aligning a group ID to the viewport top.
///
/// The same math serves the windowed timeline's boundary moves: an expand or
/// shrink moves the render window's first unit, and the anchor is a unit that
/// stays rendered across the move — its measured y delta is the displacement
/// the correction removes. `signal` selects which "the window moved" marker a
/// report must show: the data window's first row (history pages) or the render
/// window's first unit (window moves). One machine, two signals.
nonisolated struct TimelineHistoryPosition: Equatable {
    /// Which window change this position corrects for.
    enum Signal: Equatable {
        case dataWindow
        case renderWindow
    }

    let id: Int
    let signal: Signal
    let origin: TimelineHistoryLayout?
    private let originOffset: CGFloat
    private var latestLayout: TimelineHistoryLayout?
    private var hasReceivedPage = false
    private var expectedFirstRowID: String?
    private var restorationCancelled = false
    private(set) var restoredOffset: CGFloat?

    init(id: Int, layout: TimelineHistoryLayout?, offsetY: CGFloat, topInset: CGFloat,
         signal: Signal = .dataWindow) {
        self.id = id
        self.signal = signal
        origin = layout
        latestLayout = layout
        // An outward pull can still be bouncing when the request starts.
        originOffset = max(-topInset, offsetY)
    }

    var isReadyToFinish: Bool {
        hasReceivedPage && (expectedFirstRowID == nil || latestLayout?.firstRowID == expectedFirstRowID)
    }

    mutating func receivedPage(firstRowID: String?) {
        hasReceivedPage = true
        expectedFirstRowID = firstRowID
    }

    mutating func cancelRestoration() { restorationCancelled = true }

    mutating func laidOut(_ layout: TimelineHistoryLayout, generation: Int) -> CGFloat? {
        latestLayout = layout
        guard !restorationCancelled, generation == id, let origin,
              layout.anchorRowID == origin.anchorRowID, layout.edge == origin.edge else { return nil }
        let windowMoved: Bool
        switch signal {
        case .dataWindow: windowMoved = layout.firstRowID != origin.firstRowID
        case .renderWindow: windowMoved = layout.renderFirstRowID != origin.renderFirstRowID
        }
        guard windowMoved else { return nil }
        let offset = originOffset + layout.y - origin.y
        guard abs(offset - (restoredOffset ?? originOffset)) > 0.5 else { return nil }
        restoredOffset = offset
        return offset
    }
}

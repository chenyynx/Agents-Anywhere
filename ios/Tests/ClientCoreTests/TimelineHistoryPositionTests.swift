import Foundation
import Testing
@testable import ClientCore

@Suite struct TimelineHistoryPositionTests {
    private func layout(first: String = "old", anchor: String = "old", y: CGFloat = 80,
                        edge: TimelineHistoryLayout.Edge = .top) -> TimelineHistoryLayout {
        TimelineHistoryLayout(firstRowID: first, anchorRowID: anchor, edge: edge, y: y)
    }

    @Test @MainActor func loadingWaitsForPresentationAndLayoutAfterTheHTTPResponse() throws {
        let old: V2TimelineItem = try decode(itemObject(id: "old", text: "Already visible"))
        let earlier: V2TimelineItem = try decode(itemObject(id: "earlier", text: "Earlier page"))
        let timeline = SessionTimelinePresentation()
        timeline.stage([old], animate: false); timeline.flush(now: 0)
        var history = TimelineHistoryPosition(id: 1, layout: layout(), offsetY: 32, topInset: 80)
        // Repository completion and the fixed presentation deadline are separate.
        timeline.stage([earlier, old], animate: false)
        history.receivedPage(firstRowID: earlier.id)
        #expect(timeline.rows.first?.id == "old" && !history.isReadyToFinish)
        timeline.flush(now: 1)
        #expect(!history.isReadyToFinish)
        let correction = history.laidOut(layout(first: try #require(timeline.rows.first?.id), y: 780), generation: 1)
        #expect(correction == 732 && history.isReadyToFinish)
    }

    @Test func prependingPreservesTheOffsetInsideALongMessage() {
        var history = TimelineHistoryPosition(id: 2, layout: layout(y: 80), offsetY: 420, topInset: 80)
        let correction = history.laidOut(layout(first: "earlier", y: 1080), generation: 2)
        #expect(correction == 1420)
        // The old message begins 340 points above the reader before and after.
        let oldScreenY: CGFloat = 80 - 420
        #expect(oldScreenY == 1080 - correction!)
        #expect(!history.isReadyToFinish)
        history.receivedPage(firstRowID: "earlier")
        #expect(history.isReadyToFinish)
    }

    @Test func tailGrowthAndRepeatedLayoutDoNotAddToThePrependCorrection() {
        var history = TimelineHistoryPosition(id: 3, layout: layout(), offsetY: 20, topInset: 80)
        // Appending streamed text below the anchor never moves the anchor itself.
        let append = history.laidOut(layout(), generation: 3)
        #expect(append == nil)
        let prepend = history.laidOut(layout(first: "earlier", y: 580), generation: 3)
        #expect(prepend == 520)
        let repeated = history.laidOut(layout(first: "earlier", y: 580), generation: 3)
        #expect(repeated == nil)
        // A final Markdown measurement corrects against the original point,
        // not by accumulating every observed content-size change.
        let settled = history.laidOut(layout(first: "earlier", y: 612), generation: 3)
        #expect(settled == 552)
    }

    @Test func newDragOrNavigationCancelsRestorationWithoutLosingLoadingCompletion() {
        for explicitlyCancelled in [false, true] {
            var history = TimelineHistoryPosition(id: 4, layout: layout(), offsetY: 0, topInset: 80)
            if explicitlyCancelled { history.cancelRestoration() }
            history.receivedPage(firstRowID: "earlier")
            #expect(!history.isReadyToFinish)
            let correction = history.laidOut(layout(first: "earlier", y: 780), generation: explicitlyCancelled ? 4 : 5)
            #expect(correction == nil && history.isReadyToFinish)
        }
    }

    @Test func unchangedEmptyOrFailedPagesFinishWithoutMovingTheReader() {
        var history = TimelineHistoryPosition(id: 5, layout: layout(), offsetY: 20, topInset: 80)
        history.receivedPage(firstRowID: "old")
        let correction = history.laidOut(layout(), generation: 5)
        #expect(history.isReadyToFinish && correction == nil)
        var empty = TimelineHistoryPosition(id: 6, layout: nil, offsetY: 0, topInset: 80)
        empty.receivedPage(firstRowID: nil)
        #expect(empty.isReadyToFinish)
    }

    @Test func outwardPullRestoresTheRestingInsetInsteadOfKeepingOverscroll() {
        var history = TimelineHistoryPosition(id: 7, layout: layout(), offsetY: -135, topInset: 80)
        let correction = history.laidOut(layout(first: "earlier", y: 1080), generation: 7)
        #expect(correction == 920)
    }

    @Test func prefixedToolGroupsRetainTheirExistingTrailingBoundary() {
        var history = TimelineHistoryPosition(id: 8, layout: layout(first: "old-tool", anchor: "last-tool", y: 500, edge: .bottom),
            offsetY: 100, topInset: 80)
        let correction = history.laidOut(layout(first: "earlier-tool", anchor: "last-tool", y: 800, edge: .bottom), generation: 8)
        #expect(correction == 400)
        let unrelated = history.laidOut(layout(first: "earlier-tool", anchor: "other-tool", y: 900, edge: .bottom), generation: 8)
        #expect(unrelated == nil)
    }

    /// The user's own page is the one prepend path with an anchor: the
    /// presentation bumps `windowRevision` for it like any other prepend, and
    /// the view's consumer then runs — the refusal must leave both the
    /// navigation generation and the armed anchor untouched, or the page
    /// would land unanchored (2026-10-10 batch-2 regression, the "user's own
    /// loadOlder" leak check).
    @Test func theUserPageKeepsItsAnchorWhenTheWindowRevisionFires() throws {
        var state = TimelineScrollState()
        state.geometryChanged(TimelineViewport(contentHeight: 2000, containerHeight: 800, topInset: 80, bottomInset: 120, offsetY: 1320))
        state.tailVisibilityChanged(.near, visible: true)
        state.tailVisibilityChanged(.end, visible: true)
        state.open()
        let opening = try #require(state.pendingBottomRequest)
        let begun = state.begin(opening)
        let command = try #require(begun)
        let completed = state.complete(command)
        #expect(completed)
        // The reader takes over and pulls a page of history at the top: the
        // view arms the anchor against the request's navigation generation.
        state.phaseChanged(.tracking, viewport: TimelineViewport(contentHeight: 2600, containerHeight: 800, topInset: 80, bottomInset: 120, offsetY: 60))
        state.browseHistory(byReader: true)
        let generation = state.navigationGeneration
        var anchor = TimelineHistoryPosition(id: generation, layout: layout(y: 80), offsetY: 420, topInset: 80)
        // The page lands and prepends: `windowRevision` bumps, and the view
        // re-asserts the opening return exactly as its onChange does.
        let reasserted = state.reassertOpeningReturn()
        #expect(!reasserted, "A reader's own page never triggers an opening return")
        #expect(state.pendingBottomRequest == nil, "No follow request is armed behind the reader's back")
        #expect(state.navigationGeneration == generation, "The armed anchor's generation survives the consumer")
        // The anchor still absorbs the prepend under the reader.
        let correction = anchor.laidOut(layout(first: "earlier", y: 1080), generation: generation)
        #expect(correction == 1420)
    }

    // MARK: render-window signal (the windowed timeline's expand/shrink moves)

    private func renderLayout(renderFirst: String, anchor: String = "anchor", y: CGFloat) -> TimelineHistoryLayout {
        TimelineHistoryLayout(firstRowID: "data-first", renderFirstRowID: renderFirst,
            anchorRowID: anchor, edge: .top, y: y)
    }

    /// A window move keeps the reader in place: the data window's first row
    /// never changes, only the render boundary — and the correction is the
    /// measured y delta of the surviving anchor.
    @Test func renderWindowMovesCorrectThroughTheSameMath() {
        var anchor = TimelineHistoryPosition(id: 11, layout: renderLayout(renderFirst: "g10", y: 900),
            offsetY: 4000, topInset: 80, signal: .renderWindow)
        #expect(anchor.laidOut(renderLayout(renderFirst: "g10", y: 900), generation: 11) == nil,
            "An unchanged window never corrects")
        let correction = anchor.laidOut(renderLayout(renderFirst: "g4", y: 1280), generation: 11)
        #expect(correction == 4380)
        // The anchor's on-screen position is invariant — net displacement zero.
        let onScreen = 1280 - (correction ?? 0)
        let before: CGFloat = 900 - 4000
        #expect(onScreen == before)
        // A later markdown settle corrects against the original point again.
        let settled = anchor.laidOut(renderLayout(renderFirst: "g4", y: 1310), generation: 11)
        #expect(settled == 4410)
    }

    /// The two signals are orthogonal: a history prepend (data first row
    /// changes, render boundary does not) never fires the window signal, and
    /// a window move never fires the data signal — the loadOlder anchor's
    /// behavior is untouched by the windowed timeline.
    @Test func theTwoWindowSignalsAreOrthogonal() {
        let dataPrepend = TimelineHistoryLayout(firstRowID: "much-older", renderFirstRowID: "g10",
            anchorRowID: "anchor", edge: .top, y: 1200)
        var windowAnchor = TimelineHistoryPosition(id: 12, layout: renderLayout(renderFirst: "g10", y: 900),
            offsetY: 4000, topInset: 80, signal: .renderWindow)
        #expect(windowAnchor.laidOut(dataPrepend, generation: 12) == nil,
            "A data prepend with a stable render boundary is not a window move")
        var history = TimelineHistoryPosition(id: 13, layout: layout(first: "old", anchor: "anchor", y: 80),
            offsetY: 400, topInset: 80)
        #expect(history.laidOut(dataPrepend, generation: 13) == 1520,
            "The data signal keeps correcting history pans exactly as before")

        let windowMove = TimelineHistoryLayout(firstRowID: "data-first", renderFirstRowID: "g2",
            anchorRowID: "anchor", edge: .top, y: 1500)
        var historyForWindow = TimelineHistoryPosition(id: 14, layout: layout(first: "data-first", anchor: "anchor", y: 80),
            offsetY: 400, topInset: 80)
        #expect(historyForWindow.laidOut(windowMove, generation: 14) == nil,
            "A window move with an unchanged data first row is not a history pan")
    }

    @Test func aCancelledWindowAnchorStopsCorrectingButStillFinishes() {
        var anchor = TimelineHistoryPosition(id: 15, layout: renderLayout(renderFirst: "g10", y: 900),
            offsetY: 4000, topInset: 80, signal: .renderWindow)
        anchor.cancelRestoration()
        #expect(anchor.laidOut(renderLayout(renderFirst: "g1", y: 1400), generation: 15) == nil)
        // The request itself still completes: settlement is not the correction.
        anchor.receivedPage(firstRowID: "data-first")
        #expect(anchor.isReadyToFinish)
    }
}

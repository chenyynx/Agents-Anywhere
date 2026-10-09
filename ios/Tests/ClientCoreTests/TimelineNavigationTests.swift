import Foundation
import Testing
@testable import ClientCore

@Suite struct TimelineNavigationTests {
    private func viewport(offset: CGFloat = 0, height: CGFloat = 2000, container: CGFloat = 800) -> TimelineViewport {
        TimelineViewport(contentHeight: height, containerHeight: container, topInset: 80, bottomInset: 120, offsetY: offset)
    }
    private func nextCommand(_ state: inout TimelineScrollState) throws -> TimelineScrollState.BottomCommand {
        let request = try #require(state.pendingBottomRequest)
        let command = state.begin(request)
        return try #require(command)
    }
    private func visibility(_ state: inout TimelineScrollState, end: Bool, near: Bool? = nil) {
        state.tailVisibilityChanged(.near, visible: near ?? end)
        state.tailVisibilityChanged(.end, visible: end)
    }

    private func openedAtBottom() throws -> TimelineScrollState {
        var state = TimelineScrollState()
        state.geometryChanged(viewport(offset: 1320))
        visibility(&state, end: true)
        state.open()
        let command = try nextCommand(&state)
        let completed = state.complete(command)
        #expect(completed)
        return state
    }

    @Test func actualTailVisibilityWinsOverContentSizeAndInsetEstimates() throws {
        // The UI supplies real marker visibility. Deliberately vary geometry
        // without manufacturing an expected native "bottom offset" in the test.
        for geometry in [viewport(offset: 500), viewport(offset: 900, container: 500),
            viewport(offset: -80, height: 200), viewport(offset: -80, height: 32)] {
            var state = try openedAtBottom()
            state.browseHistory()
            state.geometryChanged(geometry)
            visibility(&state, end: true)
            #expect(!state.showsBottomButton())
            visibility(&state, end: false, near: true)
            #expect(!state.showsBottomButton())
            visibility(&state, end: false)
            #expect(state.showsBottomButton())
        }
    }

    @Test func endMarkerWinsWhenVisibilityCallbacksArriveInDifferentOrders() {
        var tail = TimelineTailVisibility()
        #expect(!tail.isMeasured)
        tail.update(.end, visible: true)
        tail.update(.near, visible: false)
        #expect(tail.isMeasured && tail.isAtBottom && tail.isNearBottom)
        tail.update(.end, visible: false)
        #expect(!tail.isAtBottom && !tail.isNearBottom)
        tail.update(.near, visible: true)
        #expect(!tail.isAtBottom && tail.isNearBottom)
    }

    @Test func openingWaitsForDataAndGeometryThenRequestsOneAnimation() throws {
        var state = TimelineScrollState()
        state.geometryChanged(viewport())
        visibility(&state, end: false)
        #expect(state.pendingBottomRequest == nil && !state.showsBottomButton())
        state.open()
        let command = try nextCommand(&state)
        let generation = state.navigationGeneration
        state.geometryChanged(viewport(offset: 1320))
        visibility(&state, end: true)
        let completed = state.complete(command)
        #expect(completed)
        #expect(state.mode == .following && state.pendingBottomRequest == nil && !state.showsBottomButton())
        state.open()
        #expect(state.navigationGeneration == generation && state.pendingBottomRequest == nil)
        var unmeasured = TimelineScrollState()
        unmeasured.open()
        #expect(unmeasured.pendingBottomRequest == nil)
        // With top initial alignment, a long session's end may never have been
        // onscreen. Opening must scroll without waiting for that callback.
        unmeasured.geometryChanged(viewport())
        #expect(unmeasured.pendingBottomRequest != nil)
        unmeasured.tailVisibilityChanged(.near, visible: false)
        #expect(unmeasured.pendingBottomRequest != nil)
    }

    @Test func offsetCallbacksCannotRestartAnAnimationForUnchangedLayout() throws {
        var state = try openedAtBottom()
        state.geometryChanged(viewport(offset: 1320, height: 2200))
        visibility(&state, end: false)
        let command = try nextCommand(&state)
        state.phaseChanged(.animating, viewport: viewport(offset: 1320, height: 2200))
        for offset in stride(from: 1325.0, through: 1515.0, by: 5) {
            state.geometryChanged(viewport(offset: offset, height: 2200))
            // The coalescer restarts only when the request value changes.
            // While the page is measurably short the value stays pinned to
            // the in-flight command's own request; on arrival it clears.
            // Neither spelling is a new command, and the completion still
            // settles the animation the callbacks never restarted.
            #expect(state.pendingBottomRequest == nil || state.pendingBottomRequest == command.request)
            #expect(state.activeCommand == command && !state.showsBottomButton())
        }
        state.phaseChanged(.idle, viewport: viewport(offset: 1520, height: 2200))
        visibility(&state, end: true)
        let completed = state.complete(command)
        #expect(completed)
        #expect(state.pendingBottomRequest == nil && !state.showsBottomButton())
    }

    @Test func newerStreamingLayoutSupersedesOnlyTheOldAnimation() throws {
        var state = try openedAtBottom()
        state.geometryChanged(viewport(offset: 1320, height: 2200))
        visibility(&state, end: false)
        let first = try nextCommand(&state)
        state.geometryChanged(viewport(offset: 1400, height: 2400))
        let second = try nextCommand(&state)
        let completedFirst = state.complete(first)
        #expect(!completedFirst && state.activeCommand == second)
        state.geometryChanged(viewport(offset: 1720, height: 2400))
        visibility(&state, end: true)
        let completedSecond = state.complete(second)
        #expect(completedSecond && state.pendingBottomRequest == nil)
    }

    @Test func manualReadingSurvivesLateLayoutAndCannotSnapBackOnIdle() throws {
        var state = try openedAtBottom()
        state.phaseChanged(.tracking, viewport: viewport(offset: 1320))
        state.phaseChanged(.interacting, viewport: viewport(offset: 900))
        state.geometryChanged(viewport(offset: 1320)) // Older cached measurement.
        state.phaseChanged(.idle, viewport: viewport(offset: 900))
        // A phase callback alone must not use the old visible end marker.
        #expect(state.mode == .reading && state.needsUserScrollSettlement)
        visibility(&state, end: false)
        state.settleUserScroll()
        #expect(state.mode == .reading && state.showsBottomButton())
        state.geometryChanged(viewport(offset: 900, height: 2300))
        #expect(state.pendingBottomRequest == nil && state.showsBottomButton())
        for phase in [TimelineScrollState.Phase.tracking, .interacting, .decelerating, .animating] {
            state.phaseChanged(phase, viewport: viewport(offset: 900))
            #expect(!state.showsBottomButton())
        }
    }

    @Test func aManualArrivalResumesFollowingButTheWiderPillMarginDoesNot() throws {
        for (arrived, expected) in [(true, TimelineScrollState.Mode.following), (false, .reading)] {
            var state = try openedAtBottom()
            visibility(&state, end: false)
            state.phaseChanged(.interacting, viewport: viewport(offset: 1000))
            state.phaseChanged(.idle, viewport: viewport(offset: 1100))
            // Round 1.3: arrival is measured, not probed — and the marker is
            // staged to contradict the measurement either way (off even when
            // the reader arrived, on while the reader is short), so only the
            // measured geometry can produce the expected mode.
            state.geometryChanged(viewport(offset: arrived ? 1320 : 1100))
            visibility(&state, end: !arrived, near: true)
            state.settleUserScroll()
            #expect(state.mode == expected && !state.showsBottomButton())
            state.geometryChanged(viewport(offset: 1100, height: 2200))
            visibility(&state, end: false)
            #expect((state.pendingBottomRequest != nil) == (expected == .following))
        }
    }

    @Test func explicitReturnSurvivesOldDecelerationButANewDragCancelsIt() throws {
        var state = try openedAtBottom()
        state.phaseChanged(.tracking, viewport: viewport(offset: 1000))
        state.phaseChanged(.decelerating, viewport: viewport(offset: 900))
        visibility(&state, end: false)
        state.requestBottom()
        let command = try nextCommand(&state)
        state.phaseChanged(.idle, viewport: viewport(offset: 850))
        #expect(state.returningToBottom && state.activeCommand == command)
        state.phaseChanged(.animating, viewport: viewport(offset: 1000))
        let began = state.phaseChanged(.interacting, viewport: viewport(offset: 1000))
        let completed = state.complete(command)
        #expect(began && !completed && state.pendingBottomRequest == nil)
        state.phaseChanged(.idle, viewport: viewport(offset: 800))
        #expect(state.mode == .reading && state.showsBottomButton())
    }

    @Test func bottomPillCanReappearAfterEveryCompletedReturn() throws {
        var state = try openedAtBottom()
        for offset in [900.0, 700.0, 1000.0] {
            state.phaseChanged(.tracking, viewport: viewport(offset: 1320))
            state.phaseChanged(.interacting, viewport: viewport(offset: offset))
            visibility(&state, end: false)
            #expect(!state.showsBottomButton())
            state.phaseChanged(.idle, viewport: viewport(offset: offset))
            state.settleUserScroll()
            #expect(state.showsBottomButton() && state.pendingBottomRequest == nil)
            state.requestBottom()
            let command = try nextCommand(&state)
            state.phaseChanged(.animating, viewport: viewport(offset: offset))
            visibility(&state, end: true)
            state.phaseChanged(.idle, viewport: viewport(offset: 1320))
            let completed = state.complete(command)
            #expect(completed && !state.showsBottomButton() && state.pendingBottomRequest == nil)
        }
    }

    @Test func approvalsCancelQueuedFollowingAndReturnAfterTheFooterShrinks() throws {
        var state = try openedAtBottom()
        state.geometryChanged(viewport(offset: 1320, height: 2200))
        visibility(&state, end: false)
        let queued = try #require(state.pendingBottomRequest)
        state.setInteractionPresented(true)
        let obsolete = state.begin(queued)
        #expect(obsolete == nil)
        let card = TimelineViewport(contentHeight: 2200, containerHeight: 800, topInset: 80, bottomInset: 360, offsetY: 1320)
        state.geometryChanged(card)
        #expect(state.mode == .reading && state.pendingBottomRequest == nil && state.showsBottomButton())
        state.requestBottom() // An accepted response with other cards still present.
        let command = try nextCommand(&state)
        state.geometryChanged(.init(contentHeight: 2200, containerHeight: 800, topInset: 80, bottomInset: 360, offsetY: 1760))
        visibility(&state, end: true)
        let completed = state.complete(command)
        #expect(completed && state.mode == .reading)
        state.geometryChanged(.init(contentHeight: 2250, containerHeight: 800, topInset: 80, bottomInset: 360, offsetY: 1760))
        #expect(state.pendingBottomRequest == nil)
        state.setInteractionPresented(false)
        state.geometryChanged(viewport(offset: 1520, height: 2250))
        let resized = try #require(state.pendingBottomRequest)
        #expect(resized.contentHeight == 2250 && state.returningToBottom)
    }

    @Test func anExistingApprovalCannotCancelTheInitialOpeningReturn() throws {
        var state = TimelineScrollState()
        state.geometryChanged(viewport())
        visibility(&state, end: false)
        state.open(interactionPresented: true)
        state.setInteractionPresented(true)
        let command = try nextCommand(&state)
        #expect(state.returningToBottom)
        state.geometryChanged(viewport(offset: 1320))
        visibility(&state, end: true)
        let completed = state.complete(command)
        #expect(completed && state.mode == .reading)
    }

    @Test func drawerMotionAndOcclusionSuspendFollowingWithoutLosingReadingIntent() throws {
        for reading in [false, true] {
            var state = try openedAtBottom()
            if reading { state.browseHistory() }
            let generation = state.navigationGeneration
            state.setNavigationSuspended(true)
            state.geometryChanged(viewport(offset: 1320, height: 2250))
            visibility(&state, end: false)
            state.phaseChanged(.interacting, viewport: viewport(offset: 1320, height: 2250))
            #expect(state.navigationGeneration == generation)
            #expect(state.pendingBottomRequest == nil && !state.showsBottomButton())
            state.setNavigationSuspended(false)
            state.phaseChanged(.idle, viewport: viewport(offset: 1320, height: 2250))
            #expect((state.pendingBottomRequest == nil) == reading)
        }
    }

    @Test func closingDrawerCannotLetAnOldCompletionReleaseTheNewAnimation() throws {
        var state = TimelineScrollState()
        state.geometryChanged(viewport())
        visibility(&state, end: false)
        state.open()
        let first = try nextCommand(&state)
        state.setNavigationSuspended(true)
        state.setNavigationSuspended(false)
        let second = try nextCommand(&state)
        let completedFirst = state.complete(first)
        #expect(first.id != second.id && !completedFirst && state.activeCommand == second)
    }

    @Test func stationaryBottomAndSubpixelLayoutDoNotProduceCorrectionLoops() throws {
        var state = try openedAtBottom()
        for delta in [0.25, -0.25, 0, 1, -1, 0] {
            state.geometryChanged(viewport(offset: 1320, height: 2000 + delta))
            #expect(state.pendingBottomRequest == nil && !state.showsBottomButton())
        }
        state.setNavigationSuspended(true)
        state.setNavigationSuspended(false)
        #expect(state.pendingBottomRequest == nil && !state.showsBottomButton())
    }

    @Test func aFailedNativeTargetIsReconciledOnceWhileShortAndIdleNotLooped() throws {
        var state = TimelineScrollState()
        state.geometryChanged(viewport())
        visibility(&state, end: false)
        state.open()
        let command = try nextCommand(&state)
        let completed = state.complete(command)
        #expect(completed)
        // The return completed without the page moving. Value equality alone
        // used to suppress this layout forever (the pill was the way back);
        // the windowed compromise keeps the correction requestable while the
        // state is short, idle and following — and the coalescer still holds
        // because the request value does not change.
        for offset in [0.0, 0.25, 0, 0.5] {
            state.geometryChanged(viewport(offset: offset))
            let request = try #require(state.pendingBottomRequest)
            #expect(request.contentHeight == 2000)
        }
        // The backstop asks exactly once; a second failed round cannot ask
        // again while the loop keeps publishing the same short layout. (The
        // mutating ask is taken out of the `#expect` macro, which captures
        // its expression immutably.)
        let parkedAsk = state.reconcileToBottom()
        #expect(parkedAsk)
        let retry = try nextCommand(&state)
        let retried = state.complete(retry)
        #expect(retried)
        for offset in [0.0, 0.25, 0] {
            state.geometryChanged(viewport(offset: offset))
            let latchedAsk = state.reconcileToBottom()
            #expect(!latchedAsk)
        }
        // A measurable arrival re-arms it, so a later displacement may be
        // reconciled again...
        state.geometryChanged(viewport(offset: 1320))
        state.geometryChanged(viewport(offset: 1000))
        let rearmedAsk = state.reconcileToBottom()
        #expect(rearmedAsk)
        // ...and an explicit return still works after everything.
        state.requestBottom()
        #expect(state.pendingBottomRequest != nil)
    }

    @Test func aNewGestureInvalidatesHistoryRestorationAndPendingReturns() throws {
        var state = try openedAtBottom()
        state.browseHistory()
        let request = state.navigationGeneration
        state.phaseChanged(.interacting, viewport: viewport(offset: 800))
        #expect(state.navigationGeneration != request)
        let gesture = state.navigationGeneration
        state.phaseChanged(.interacting, viewport: viewport(offset: 700))
        #expect(state.navigationGeneration == gesture)
        state.requestBottom()
        state.phaseChanged(.idle, viewport: viewport(offset: 700))
        #expect(state.returningToBottom && state.pendingBottomRequest != nil)
    }

    @Test func eachHistoryEdgeNeedsOneFreshPullOnAnAlreadyVisiblePrompt() {
        for edge in [TimelineHistoryPull.Edge.older, .latest] {
            var pull = TimelineHistoryPull(edge: edge)
            let direction: CGFloat = edge == .older ? -1 : 1
            pull.begin(at: viewport(), promptVisible: true, canLoad: true)
            pull.update(viewport(offset: direction * 30))
            #expect(pull.isReady)
            let first = pull.end(), second = pull.end()
            #expect(first && !second)
            pull.update(viewport(offset: direction * 60))
            let inertia = pull.end()
            #expect(!inertia)
            pull.begin(at: viewport(), promptVisible: false, canLoad: true)
            pull.update(viewport(offset: direction * 30))
            let firstArrival = pull.end()
            #expect(!firstArrival)
            // A failed page read can be retried by a new deliberate pull.
            pull.begin(at: viewport(), promptVisible: true, canLoad: true)
            pull.update(viewport(offset: direction * 30))
            let retry = pull.end()
            #expect(retry)
        }
    }

    @Test func historyPullCancelsOnResizingReversalOrExistingRequests() {
        for edge in [TimelineHistoryPull.Edge.older, .latest] {
            var pull = TimelineHistoryPull(edge: edge)
            let direction: CGFloat = edge == .older ? -1 : 1
            pull.begin(at: viewport(), promptVisible: true, canLoad: false)
            pull.update(viewport(offset: direction * 50))
            #expect(!pull.isReady)
            pull.begin(at: viewport(), promptVisible: true, canLoad: true)
            pull.update(viewport(offset: direction * 50, height: 2020))
            #expect(!pull.isReady)
            pull.begin(at: viewport(), promptVisible: true, canLoad: true)
            pull.update(viewport(offset: direction * 50, container: 500))
            #expect(!pull.isReady)
            pull.begin(at: viewport(), promptVisible: true, canLoad: true)
            pull.update(viewport(offset: direction * 40))
            pull.update(viewport(offset: direction * 5))
            let reversed = pull.end()
            #expect(!reversed)
        }
    }

    /// The reader's arrival is judged where their gesture stopped, not when the
    /// settlement task wakes: a tap inside those 64 ms grows the composer and
    /// displaces the published viewport, and that displacement must not turn a
    /// reader who stopped at the bottom into one who parked away from it.
    /// Without the latch this reads `.reading` and the keyboard pin refuses.
    @Test func aReaderWhoStopsAtTheBottomKeepsFollowingEvenIfThePageMovesAfter() throws {
        var state = try openedAtBottom()
        _ = state.phaseChanged(.tracking, viewport: viewport(offset: 600))
        _ = state.phaseChanged(.idle, viewport: viewport(offset: 1320))
        // The composer grew (bottom inset 120 -> 172) before the task woke.
        state.geometryChanged(TimelineViewport(contentHeight: 2000, containerHeight: 800,
            topInset: 80, bottomInset: 172, offsetY: 1320))
        state.settleUserScroll()
        #expect(state.mode == .following)
    }

    /// The control: the latch must not grant following to a reader who stopped
    /// away from the bottom.
    @Test func aReaderWhoStopsAwayFromTheBottomStaysInReading() throws {
        var state = try openedAtBottom()
        _ = state.phaseChanged(.tracking, viewport: viewport(offset: 600))
        _ = state.phaseChanged(.idle, viewport: viewport(offset: 600))
        state.geometryChanged(viewport(offset: 600))
        state.settleUserScroll()
        #expect(state.mode == .reading)
    }
}

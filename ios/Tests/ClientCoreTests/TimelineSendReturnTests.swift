import Foundation
import Testing
@testable import ClientCore

/// The send → confirm path (2026-10-06). A confirmed send replaces the
/// pending row, and both known stop shapes park the page short of the
/// bottom with no request surviving: the split-frame round trip returns to
/// the already-claimed request value (the value dedup treated it as
/// processed), or the tail marker's false flip is lost and stays "at
/// bottom" (the marker gate swallowed every request). Every arrival
/// judgement here is the measured gap (`contentHeight − visibleBottom
/// ≤ 8`); the publish-point reconcile is the bounded backstop.
///
/// Mutation guards, per test: reverting the marker gate, the unconditional
/// value dedup or the reconcile latch turns these red — the diagnostic
/// harness archives park exactly there (run-asis.txt S1/S2 vs
/// run-fixed.txt, `~/aa-test/send-return-recon/`).
@Suite struct TimelineSendReturnTests {
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
    /// A send from the bottom: the pending-row insert bumps the return, and
    /// the already-at-bottom first command completes on the spot.
    private func sentFromBottom(_ state: inout TimelineScrollState) throws {
        state.requestBottom()
        let command = try nextCommand(&state)
        let completed = state.complete(command)
        #expect(completed)
    }

    @Test func aSendCorrectsTheBubbleLandingAndKeepsTheReturnAnimated() throws {
        var state = try openedAtBottom()
        try sentFromBottom(&state)
        // The bubble lands (+70pt measured against the real content edge):
        // the correction is a spring, not another instant opening return.
        state.geometryChanged(viewport(offset: 1320, height: 2070))
        visibility(&state, end: false)
        let correction = try nextCommand(&state)
        #expect(!correction.instant)
        #expect(correction.request.contentHeight == 2070)
        // The spring lands at the grown bottom and the state rests there.
        state.geometryChanged(viewport(offset: 1390, height: 2070))
        visibility(&state, end: true)
        let completed = state.complete(correction)
        #expect(completed && state.mode == .following && state.pendingBottomRequest == nil)
    }

    @Test func aSplitConfirmSwapThatRoundTripsToTheClaimedLayoutStillRequestsTheReturn() throws {
        var state = try openedAtBottom()
        try sentFromBottom(&state)
        // The bubble lands; its follow spring completes. The claim
        // (generation, 2070, 600) is established and the page rests there.
        state.geometryChanged(viewport(offset: 1320, height: 2070))
        visibility(&state, end: false)
        let follow = try nextCommand(&state)
        state.geometryChanged(viewport(offset: 1390, height: 2070))
        visibility(&state, end: true)
        let followed = state.complete(follow)
        #expect(followed)
        // Confirm, split into two frames: the pending row is removed first
        // (the native clamp lands the page at the shrunken bottom), the
        // echo row enters second (+70pt, the offset stays).
        state.geometryChanged(viewport(offset: 1320, height: 2000))
        #expect(state.pendingBottomRequest == nil)
        state.geometryChanged(viewport(offset: 1320, height: 2070))
        visibility(&state, end: false)
        // The layout is now *identical* to the already-claimed request —
        // value equality alone treated the round trip as processed and
        // parked the page. The measured gap is a new displacement.
        // Mutation guards: the unconditional dedup or the marker gate turn
        // this red (harness run-asis.txt S2 parks here).
        let correction = try nextCommand(&state)
        #expect(correction.request.contentHeight == 2070 && correction.id != follow.id)
        // The correction lands; the same layout cannot loop afterwards.
        state.geometryChanged(viewport(offset: 1390, height: 2070))
        let completed = state.complete(correction)
        #expect(completed && state.pendingBottomRequest == nil)
    }

    @Test func aStaleTailMarkerCannotParkThePageWhenContentGrows() throws {
        var state = try openedAtBottom()
        try sentFromBottom(&state)
        // The end probe's false flip is lost: the marker keeps reporting
        // "at bottom" while the bubble pushed the content 70pt past the
        // viewport — the device shape round 1.3 measured (gap 213 while the
        // marker read "at bottom"). The measured gap opens the request
        // anyway. Mutation guard: the marker gate swallows it and the page
        // drifts (harness run-asis.txt S1).
        state.geometryChanged(viewport(offset: 1320, height: 2070))
        #expect(state.tail.isAtBottom)
        let follow = try nextCommand(&state)
        state.geometryChanged(viewport(offset: 1390, height: 2070))
        let landed = state.complete(follow)
        #expect(landed)
        // Content keeps growing while the marker still lies: following
        // continues to correct instead of drifting away.
        state.geometryChanged(viewport(offset: 1390, height: 2470))
        #expect(state.tail.isAtBottom)
        let grown = try nextCommand(&state)
        #expect(grown.request.contentHeight == 2470)
    }

    @Test func aScrollingOrReadingPageIsNeverReconciledInvoluntarily() throws {
        var state = try openedAtBottom()
        try sentFromBottom(&state)
        state.geometryChanged(viewport(offset: 1320, height: 2070))
        // The reader grabs the page before the bubble correction can land.
        // (The mutating ask is taken out of the `#expect` macro, which
        // captures its expression immutably.)
        state.phaseChanged(.tracking, viewport: viewport(offset: 1320, height: 2070))
        let trackingAsk = state.reconcileToBottom()
        #expect(!trackingAsk)
        state.phaseChanged(.interacting, viewport: viewport(offset: 1200, height: 2070))
        let interactingAsk = state.reconcileToBottom()
        #expect(!interactingAsk)
        state.phaseChanged(.idle, viewport: viewport(offset: 1200, height: 2070))
        let restingAsk = state.reconcileToBottom()
        #expect(!restingAsk)
        state.settleUserScroll()
        // Short of the bottom: the reader owns the page — reading stays
        // reading, and the backstop may not ask.
        #expect(state.mode == .reading)
        let readingAsk = state.reconcileToBottom()
        #expect(!readingAsk && state.mode == .reading)
        // The reader's own explicit return is the only way back (and the
        // coalescer is free to carry it).
        state.requestBottom()
        #expect(state.pendingBottomRequest != nil)
    }

    @Test func thePublishReconcileAsksOncePerDisplacementEpisode() throws {
        var state = try openedAtBottom()
        try sentFromBottom(&state)
        // The bubble lands; its request is fresh for the coalescer — the
        // backstop must not race the 24 ms task.
        state.geometryChanged(viewport(offset: 1320, height: 2070))
        let freshAsk = state.reconcileToBottom()
        #expect(!freshAsk)
        // The return travels; an in-flight command owns the window.
        let inFlight = try nextCommand(&state)
        let inFlightAsk = state.reconcileToBottom()
        #expect(!inFlightAsk)
        // It completes without moving (an interrupted native target): the
        // request is now inert — equal to the last begun one — and the
        // backstop re-asks exactly once, as a fresh return chain.
        let failed = state.complete(inFlight)
        #expect(failed)
        let generation = state.navigationGeneration
        let parkedAsk = state.reconcileToBottom()
        #expect(parkedAsk)
        #expect(state.returningToBottom && state.navigationGeneration != generation)
        // The re-ask itself completes without arriving: repeated samples of
        // the same short layout cannot ask again (the latch).
        let retry = try nextCommand(&state)
        let wasted = state.complete(retry)
        #expect(wasted)
        for offset in [1320.0, 1320.25, 1320.5] {
            state.geometryChanged(viewport(offset: offset, height: 2070))
            let latchedAsk = state.reconcileToBottom()
            #expect(!latchedAsk)
        }
        // A measurable arrival re-arms the latch...
        state.geometryChanged(viewport(offset: 1390, height: 2070))
        // ...so the next displacement episode may be reconciled again.
        state.geometryChanged(viewport(offset: 1320, height: 2070))
        let rearmedAsk = state.reconcileToBottom()
        #expect(rearmedAsk)
    }
}

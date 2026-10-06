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

    // MARK: 补洞轮 — 最新采样判定（红队 §2 形态 B / §4 缺口）

    @Test func aFilteredBurstStillDrivesTheBackstopByItsFreshestSample() throws {
        var state = try openedAtBottom()
        // The published viewport and the marker both rest "at the bottom"
        // while the page is physically 70pt short: the burst delivered only
        // its last frame, and the intermediate frame's native clamp never
        // published (form B of the sample-loss family, red team trace-1005).
        // Judged by the stored viewport the backstop refuses...
        let storedAsk = state.reconcileToBottom()
        #expect(!storedAsk)
        // ...but with the freshest sample the pure check passes, so the view
        // can take the mutating ask without writing `@State` for the samples
        // that do not need it (S2). Mutation guard: judging by the stored
        // viewport (`let truth = viewport`) parks the page again.
        let fresh = viewport(offset: 1320, height: 2070)
        let generation = state.navigationGeneration
        #expect(state.needsBottomReconcile(using: fresh))
        let freshAsk = state.reconcileToBottom(using: fresh)
        #expect(freshAsk && state.returningToBottom)
        #expect(state.navigationGeneration != generation)
        #expect(state.pendingBottomRequest != nil)
        // The judgement is read-only: the stored viewport still holds the
        // published (stale) geometry and the request is built from it as
        // before — only the decision consumed the sample.
        #expect(state.viewport == viewport(offset: 1320))
    }

    @Test func aFilteredArrivalSampleRearmsTheSpentLatch() throws {
        var state = try openedAtBottom()
        try sentFromBottom(&state)
        // The bubble's return failed (the page never moved): the backstop
        // asked once and the latch was spent on the same short layout.
        state.geometryChanged(viewport(offset: 1320, height: 2070))
        let failedFollow = try nextCommand(&state)
        let followCompleted = state.complete(failedFollow)
        #expect(followCompleted)
        let parkedAsk = state.reconcileToBottom()
        #expect(parkedAsk)
        let retry = try nextCommand(&state)
        let retryCompleted = state.complete(retry)
        #expect(retryCompleted)
        let latchedAsk = state.reconcileToBottom()
        #expect(!latchedAsk)
        // A short sample re-arms nothing — the bound stands.
        #expect(!state.needsBottomReconcileRearm(using: viewport(offset: 1320, height: 2070)))
        // The true arrival arrives as a *filtered* sample: the page rests at
        // the bottom, but the frame changed no rendered dimension, so the
        // publication gate dropped it and no phase echo carried it either
        // (the worst modelled world — coalesced bursts, no echo). The
        // episode still ends. Mutation guards: dropping the sample re-arm
        // keeps the latch spent forever (the burst world parks); re-arming
        // on any measured sample makes the short sample above re-arm.
        let arrival = viewport(offset: 1390, height: 2070)
        #expect(state.needsBottomReconcileRearm(using: arrival))
        state.rearmBottomReconcile(using: arrival)
        #expect(!state.needsBottomReconcileRearm(using: arrival))
        // The next displacement episode may be reconciled again.
        state.geometryChanged(viewport(offset: 1320, height: 2070))
        let rearmedAsk = state.reconcileToBottom()
        #expect(rearmedAsk)
    }

    @Test func theBackstopYieldsToAFreshRequestEvenWithANewSampleInHand() throws {
        var state = try openedAtBottom()
        try sentFromBottom(&state)
        // The bubble lands: its request is fresh (the value differs from the
        // last begun return) and already traveling through the 24 ms
        // coalescer. Even a short fresh sample must not make the backstop
        // preempt it — the arbiter's `pending == lastRequest` arm stays.
        state.geometryChanged(viewport(offset: 1320, height: 2070))
        visibility(&state, end: false)
        let sample = viewport(offset: 1320, height: 2070)
        #expect(state.pendingBottomRequest != nil)
        #expect(!state.needsBottomReconcile(using: sample))
        let freshAsk = state.reconcileToBottom(using: sample)
        #expect(!freshAsk)
    }

    @Test func theBackstopStaysSilentWhileTheDrawerSuspendsNavigation() throws {
        var state = try openedAtBottom()
        state.geometryChanged(viewport(offset: 1320, height: 2070))
        state.setNavigationSuspended(true)
        // Mutation guard: dropping `!navigationIsSuspended` from the shared
        // guard list lets the backstop fire during a drawer transition —
        // the very transition the guard exists for (red team S5).
        let suspendedAsk = state.reconcileToBottom()
        #expect(!suspendedAsk)
        #expect(!state.needsBottomReconcile())
    }

    @Test func theBackstopRequiresAnOpenedSession() throws {
        // The plain fresh state is doubly blocked (no open, no measurement):
        var fresh = TimelineScrollState()
        fresh.geometryChanged(viewport(offset: 0))
        let unopenedAsk = fresh.reconcileToBottom()
        #expect(!unopenedAsk)
        // A page that reached following by measurement alone — before any
        // open — must not be reconciled either: the cold-load mask would
        // otherwise get a return it never asked for. Mutation guard:
        // dropping `hasOpened` fires here (red team S4).
        var measured = TimelineScrollState()
        measured.geometryChanged(viewport(offset: 1320))
        visibility(&measured, end: true)
        measured.phaseChanged(.tracking, viewport: viewport(offset: 1320))
        measured.phaseChanged(.idle, viewport: viewport(offset: 1320))
        measured.settleUserScroll()
        #expect(measured.mode == .following && !measured.hasOpened)
        measured.geometryChanged(viewport(offset: 1320, height: 2070))
        let preOpenAsk = measured.reconcileToBottom()
        #expect(!preOpenAsk)
    }

    @Test func theBackstopRefusesAPageThatIsMeasurablyAtTheBottom() throws {
        var state = try openedAtBottom()
        // The gap, not the latch, ends the episode: a page resting at the
        // measured bottom never reconciles. Mutation guard: dropping
        // `!truth.measuredAtBottom` fires an empty ask on every publish
        // (red team S6).
        let bottomAsk = state.reconcileToBottom()
        #expect(!bottomAsk)
        state.geometryChanged(viewport(offset: 1320))
        #expect(!state.needsBottomReconcile())
    }

    @Test func theBackstopNeverPreemptsAnExplicitReturn() throws {
        var state = try openedAtBottom()
        state.geometryChanged(viewport(offset: 1320, height: 2070))
        state.requestBottom()
        #expect(state.mode == .returning)
        // The reader's own return owns the window.
        let returningAsk = state.reconcileToBottom()
        #expect(!returningAsk)
        // ...even when the judgement runs on a new sample while the stored
        // viewport is transiently unmeasured (the arbitration guard alone
        // would pass there — `pendingBottomRequest` is nil — so the mode
        // guard is what refuses). Mutation guard: weakening the mode guard
        // to `!= .reading` fires here (red team S7).
        state.geometryChanged(TimelineViewport())
        let sample = viewport(offset: 1320, height: 2070)
        let sampledAsk = state.reconcileToBottom(using: sample)
        #expect(!sampledAsk && !state.needsBottomReconcile(using: sample))
    }

    @Test func anUnmeasuredSettleFallsBackToTheTailMarker() {
        var state = TimelineScrollState()
        state.tailVisibilityChanged(.near, visible: true)
        state.tailVisibilityChanged(.end, visible: true)
        state.open()
        _ = state.phaseChanged(.tracking, viewport: TimelineViewport())
        state.phaseChanged(.idle, viewport: TimelineViewport())
        state.settleUserScroll()
        // No geometry sample ever measured the viewport; the marker is the
        // only truth left, and a settle must not silently strand the reader
        // in reading. Mutation guard: returning false in
        // `viewportIsAtBottom`'s unmeasured fallback flips this to reading
        // (red team S2).
        #expect(state.mode == .following)
    }

    @Test func anInflightReturnOwnsTheRemovalFramesTouchdown() throws {
        var state = try openedAtBottom()
        state.geometryChanged(viewport(offset: 1320, height: 2070))
        state.requestBottom()
        let inflight = try nextCommand(&state)
        // The confirm's removal frame clamps the page back onto the bottom
        // while the return is still traveling: the layout now touches down,
        // so no second request may be built — the in-flight one owns it.
        // Mutation guard: dropping `|| lastRequest != nil` from the request
        // gate fires a duplicate here (red team S8; the value-dedup cannot
        // catch it — the request was claimed for the taller layout).
        state.geometryChanged(viewport(offset: 1320, height: 2000))
        #expect(state.mode == .returning)
        #expect(state.activeCommand == inflight)
        #expect(state.pendingBottomRequest == nil)
    }

    @Test func theBackstopRefusesAnUnmeasuredViewport() throws {
        var state = try openedAtBottom()
        state.phaseChanged(.idle, viewport: TimelineViewport())
        // A transient unmeasured sample must not command a return. Mutation
        // guard: dropping `truth.isMeasured` fires on the unmeasured stored
        // viewport (red team S3).
        let unmeasuredAsk = state.reconcileToBottom()
        #expect(!unmeasuredAsk)
        #expect(!state.needsBottomReconcile())
    }

    // MARK: 补洞轮 — 到底部胶囊的两个世界（红队 A8）

    @Test func theReturnPillShowsInTheFailedNativeTargetWorld() throws {
        var state = TimelineScrollState()
        state.geometryChanged(viewport())
        visibility(&state, end: false)
        state.open()
        let command = try nextCommand(&state)
        let completed = state.complete(command)
        #expect(completed)
        // The return completed without the page moving: the request is now
        // inert (equal to the last begun return — nothing will re-begin it
        // through the coalescer) and the page parks 1320pt short. The pill
        // is the way back — it must show. Mutation guard:
        // `pendingBottomRequest == nil` alone hides it permanently here
        // (red team A8, the failed-native-target world).
        #expect(state.pendingBottomRequest != nil)
        #expect(state.showsBottomButton())
    }

    @Test func theReturnPillHidesWhileAFreshRequestTravelsTheCoalescer() throws {
        var state = try openedAtBottom()
        try sentFromBottom(&state)
        // The bubble lands and a fresh request (different from the last
        // begun return) is already traveling: the pill must not flash during
        // the healthy self-heal window. Mutation guard: dropping the pending
        // conjunct shows it here.
        state.geometryChanged(viewport(offset: 1320, height: 2070))
        visibility(&state, end: false)
        #expect(state.pendingBottomRequest != nil)
        #expect(!state.showsBottomButton())
        // Claimed: the flight hides the pill too...
        let command = try nextCommand(&state)
        #expect(!state.showsBottomButton())
        // ...and the arrival leaves it hidden by the bottom itself.
        state.geometryChanged(viewport(offset: 1390, height: 2070))
        visibility(&state, end: true)
        let completed = state.complete(command)
        #expect(completed)
        #expect(state.pendingBottomRequest == nil && !state.showsBottomButton())
    }
}

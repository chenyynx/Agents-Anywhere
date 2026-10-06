import Foundation
import Testing
@testable import ClientCore

/// Test-local mirror of the product's two-tier tail contract (F1, pp
/// 2026-10-07): `Views/Chat/ChatTimelineView.swift` frames the tail spacer at
/// `hasStatusLine ? 32 : Self.idleTailHeight`.
///
/// T-e mutation note. The product mutation point is that frame expression:
/// reverting it to the old single constant 32 removes the ±20pt contentHeight
/// transition modelled below and collapses this mirror to one value — the
/// delta pin at the top of T-a fails first, and T-d's expand convergence has
/// nothing left to model (both verified red in the Linux rig). ClientCoreTests
/// cannot import the view layer (`ios/Package.swift` excludes `Views`), so
/// this mirror is the only executable encoding of the product expression on
/// this side of the seam: keep the two in lockstep. The machine-side bite of
/// the same sequences was also reproduced in the rig: removing the at-bottom
/// suppression in `TimelineScrollState.pendingBottomRequest` turns T-a red (a
/// condense at the bottom would emit the spurious follow this suite exists to
/// block).
private enum TailSpacerHeight {
    static let statusLine: CGFloat = 32
    static let idle: CGFloat = 12
    static var transitionDelta: CGFloat { statusLine - idle }
}

@Suite struct TimelineTailCondenseTests {
    /// Content height with the idle (12pt) tail.
    private let idleContent: CGFloat = 2000
    /// Content height while a status line is present (the 32pt tail, +20pt).
    private var statusLineContent: CGFloat { idleContent + TailSpacerHeight.transitionDelta }

    private func viewport(offset: CGFloat = 0, height: CGFloat = 2000, container: CGFloat = 800) -> TimelineViewport {
        TimelineViewport(contentHeight: height, containerHeight: container, topInset: 80, bottomInset: 120, offsetY: offset)
    }
    private func visibility(_ state: inout TimelineScrollState, end: Bool) {
        state.tailVisibilityChanged(.near, visible: end)
        state.tailVisibilityChanged(.end, visible: end)
    }
    /// Opens the timeline and completes the opening return, parking in
    /// `.following` at the bottom of `height` (bottom offset = height − 680
    /// here). The tail probes sit bottom-anchored in the product, so they stay
    /// measured through every transition below.
    private func openedFollowing(height: CGFloat) throws -> TimelineScrollState {
        var state = TimelineScrollState()
        state.geometryChanged(viewport(offset: height - 680, height: height))
        visibility(&state, end: true)
        state.open()
        let request = try #require(state.pendingBottomRequest)
        let begun = state.begin(request)
        let command = try #require(begun)
        let completed = state.complete(command)
        #expect(completed)
        return state
    }

    /// T-a: following at the bottom, the turn ends and the spacer condenses
    /// 32 → 12. The pinned bottom rides the shrink — no correction command
    /// may fire, no reconcile ask may slip through, and the new bottom is the
    /// state's truth afterwards.
    @Test func tailCondenseWhileFollowingConvergesWithoutACommand() throws {
        // T-e pin: these sequences only exist while the product keeps the
        // two-tier contract (32 / 12) — see the mirror above.
        #expect(TailSpacerHeight.transitionDelta == 20)
        var state = try openedFollowing(height: statusLineContent)
        let generation = state.navigationGeneration
        // The 0.2s transition's samples: the animated intermediate heights,
        // then the settled one, each with the bottom pinned through it.
        for height in [statusLineContent - 6, statusLineContent - 14, idleContent] {
            state.geometryChanged(viewport(offset: height - 680, height: height))
            #expect(state.mode == .following)
            #expect(state.pendingBottomRequest == nil)
            #expect(!state.showsBottomButton())
            let asked = state.reconcileToBottom()
            #expect(!asked)
        }
        // A late native clamp reports the condensed height at the stale
        // offset: still the bottom by measurement (the gap reads past zero).
        state.geometryChanged(viewport(offset: statusLineContent - 680, height: idleContent))
        #expect(state.pendingBottomRequest == nil)
        let asked = state.reconcileToBottom()
        #expect(!asked)
        // Converged on the new bottom: nothing was ever asked through the
        // transition, so no navigation generation moved.
        #expect(state.viewportIsAtBottom)
        #expect(state.viewport.contentHeight == idleContent)
        #expect(state.navigationGeneration == generation)
    }

    /// T-b: a reader parked mid-history sees the same condense (turn end) and
    /// a later expand (the status line comes back). Reading must survive, no
    /// request may issue, and the offset may not move.
    @Test func tailShrinkAndExpandCannotPullAMidHistoryReaderBack() throws {
        var state = try openedFollowing(height: statusLineContent)
        state.browseHistory()
        visibility(&state, end: false)
        state.geometryChanged(viewport(offset: 900, height: statusLineContent))
        #expect(state.mode == .reading && state.showsBottomButton())
        let generation = state.navigationGeneration
        // The spacer condenses through its animation while the reader reads.
        for height in [statusLineContent - 6, statusLineContent - 14, idleContent] {
            state.geometryChanged(viewport(offset: 900, height: height))
            #expect(state.mode == .reading)
            #expect(state.pendingBottomRequest == nil)
            #expect(state.showsBottomButton())
            let asked = state.reconcileToBottom()
            #expect(!asked)
        }
        // A runtime-state flip puts the status line (and the taller tier)
        // back: still no request, still the reader's offset.
        for height in [idleContent + 6, idleContent + 14, statusLineContent] {
            state.geometryChanged(viewport(offset: 900, height: height))
            #expect(state.mode == .reading)
            #expect(state.pendingBottomRequest == nil)
            #expect(state.showsBottomButton())
        }
        #expect(state.viewport.offsetY == 900)
        #expect(state.navigationGeneration == generation)
    }

    /// T-c: one published frame carries both the condense and the content
    /// that settles with it. A net-zero transition may not follow; the growth
    /// spelling converges with exactly one command and no reconcile behind it.
    @Test func sameFrameCondenseAndContentSampleNeverIssuesASpuriousFollow() throws {
        var state = try openedFollowing(height: statusLineContent)
        // Condense (−20) plus same-turn content growth (+20) in one sample:
        // the height is unchanged and the bottom holds — nothing may move.
        state.geometryChanged(viewport(offset: statusLineContent - 680, height: statusLineContent))
        #expect(state.mode == .following)
        #expect(state.pendingBottomRequest == nil)
        #expect(!state.showsBottomButton())
        let quietAsk = state.reconcileToBottom()
        #expect(!quietAsk)
        // The growth spelling of the same frame: net +200 instead. Exactly
        // one follow for the new height...
        let grown = statusLineContent + 200
        state.geometryChanged(viewport(offset: statusLineContent - 680, height: grown))
        let request = try #require(state.pendingBottomRequest)
        #expect(request.contentHeight == grown)
        let begun = state.begin(request)
        let command = try #require(begun)
        // ...no reconcile behind its back while it travels (an in-flight
        // command also keeps the coalescer's lingering value spelled as the
        // command's own request)...
        let inFlightAsk = state.reconcileToBottom()
        #expect(!inFlightAsk)
        #expect(state.pendingBottomRequest == nil || state.pendingBottomRequest == request)
        // ...and it lands at the new bottom with no residue.
        state.geometryChanged(viewport(offset: grown - 680, height: grown))
        let completed = state.complete(command)
        #expect(completed && state.mode == .following)
        #expect(state.pendingBottomRequest == nil && !state.showsBottomButton())
    }

    /// T-d: the status line appears while following — the spacer expands
    /// 12 → 32 (+20pt), the page is measurably short of the new bottom, and
    /// one normal follow for the new height converges.
    @Test func statusLineExpandWhileFollowingConvergesNormally() throws {
        var state = try openedFollowing(height: idleContent)
        // The expand sample lands before native re-pins the bottom: the page
        // is 20pt short of the grown bottom, so one follow must issue.
        state.geometryChanged(viewport(offset: idleContent - 680, height: statusLineContent))
        let request = try #require(state.pendingBottomRequest)
        #expect(request.contentHeight == statusLineContent)
        let begun = state.begin(request)
        let command = try #require(begun)
        // The travelling frames supersede nothing: no restart, no backstop.
        state.geometryChanged(viewport(offset: idleContent - 680 + 10, height: statusLineContent))
        #expect(state.pendingBottomRequest == nil || state.pendingBottomRequest == request)
        let asked = state.reconcileToBottom()
        #expect(!asked)
        // The follow lands at the new bottom; the taller tier is the truth.
        state.geometryChanged(viewport(offset: statusLineContent - 680, height: statusLineContent))
        let completed = state.complete(command)
        #expect(completed && state.mode == .following)
        #expect(state.pendingBottomRequest == nil && !state.showsBottomButton())
        #expect(state.viewportIsAtBottom)
    }
}

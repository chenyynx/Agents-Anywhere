import Foundation
import Testing
@testable import ClientCore

/// S2/K5 (2026-10-02): pins the non-invalidating publication rules, the
/// keyboard payload parse and the keyboard-follow coordination gate, plus the
/// command counts and order the timeline relies on. Expectations are spelled
/// as literals so any change to a rule turns these red.

@Suite struct TimelineViewportPublicationDecisionTests {
    private func viewport(content: CGFloat = 2000, container: CGFloat = 800,
                          top: CGFloat = 80, bottom: CGFloat = 120, offset: CGFloat = 0) -> TimelineViewport {
        TimelineViewport(contentHeight: content, containerHeight: container,
            topInset: top, bottomInset: bottom, offsetY: offset)
    }
    private func outcome(published: TimelineViewport, next: TimelineViewport,
                         keyboardTransitionActive: Bool = false,
                         tailChanged: Bool = false) -> TimelineViewportPublicationDecision.Outcome {
        TimelineViewportPublicationDecision.outcome(published: published, next: next,
            keyboardTransitionActive: keyboardTransitionActive, tailChanged: tailChanged)
    }

    @Test func offsetOnlySamplesNeverPublish() {
        // The rendered page does not depend on the native offset; restoration
        // reads it straight from the sample box.
        let published = viewport(offset: 1320)
        #expect(outcome(published: published, next: viewport(offset: 1000)) == .ignore)
        #expect(outcome(published: published, next: viewport(offset: 1320.25)) == .ignore)
    }

    @Test func firstMeasuredSampleWasAlwaysPublished() {
        // Opening and the instant return gate on `viewport.isMeasured`.
        let unmeasured = TimelineViewport()
        #expect(!unmeasured.isMeasured)
        #expect(outcome(published: unmeasured, next: viewport()) == .publish)
        // The case rule ① exists for: the sample already carries the content
        // height and inset but no visible height yet, so it differs from the
        // measured one by visible height alone. The first measurement must
        // still publish — even inside a transition window (① wins over ④),
        // otherwise opening waits for a second callback that may not come.
        let emptyViewport = TimelineViewport(contentHeight: 2000, containerHeight: 80,
            topInset: 80, bottomInset: 0, offsetY: 0)
        #expect(!emptyViewport.isMeasured)
        let measured = viewport()
        #expect(measured.contentHeight == emptyViewport.contentHeight && measured.topInset == emptyViewport.topInset)
        #expect(outcome(published: emptyViewport, next: measured) == .publish)
        #expect(outcome(published: emptyViewport, next: measured,
            keyboardTransitionActive: true, tailChanged: false) == .publish)
        // A still-unmeasured sample is not a first measurement.
        #expect(outcome(published: emptyViewport,
            next: TimelineViewport(contentHeight: 2000, containerHeight: 40,
                topInset: 80, bottomInset: 0, offsetY: 0)) == .ignore)
    }

    @Test func contentHeightChangePublishesDuringATransition() {
        // Streaming growth moves the follow target; withholding it while the
        // keyboard animates would stall following, not just the body.
        let published = viewport()
        #expect(outcome(published: published, next: viewport(content: 2020),
            keyboardTransitionActive: true) == .publish)
    }

    @Test func topInsetChangePublishesDuringATransition() {
        // The reader's reference line moved; that is not the keyboard.
        let published = viewport()
        #expect(outcome(published: published, next: viewport(top: 92),
            keyboardTransitionActive: true) == .publish)
    }

    @Test func keyboardVisibleHeightOnlyChangeIsWithheldUntilTheProbeFlips() {
        let published = viewport() // visibleHeight 600
        // The keyboard shrinks the container (mobile drawer path) or grows the
        // bottom inset (iPad path) frame by frame; nothing about the content
        // changed, so publishing it per frame is the body storm rule ④ removes.
        let keyboardSample = viewport(container: 500) // visibleHeight 300
        #expect(outcome(published: published, next: keyboardSample,
            keyboardTransitionActive: true) == .ignore)
        // The end probe flipping during the same transition is the bottom
        // truth moving: publish the sample with it.
        #expect(outcome(published: published, next: keyboardSample,
            keyboardTransitionActive: true, tailChanged: true) == .publish)
        // Outside a transition the same visible-height change is a rotation or
        // split-view resize and must publish.
        #expect(outcome(published: published, next: keyboardSample) == .publish)
    }

    @Test func theSettledSampleReconcilesTheWithheldHeight() {
        // Rule ⑤ is this same decision evaluated with the window closed: the
        // withheld height lands and `lastRequest` dedup cannot stay pinned to
        // a pre-keyboard value.
        let published = viewport()
        let settled = viewport(container: 500)
        #expect(outcome(published: published, next: settled,
            keyboardTransitionActive: true) == .ignore)
        #expect(outcome(published: published, next: settled,
            keyboardTransitionActive: false) == .publish)
    }
}

@Suite struct TimelineKeyboardEventTests {
    /// NSValue geometry construction is the same platform split the production
    /// parse documents: the iOS family spells it `cgRect:`, macOS `rect:`.
    private func frameValue(_ rect: CGRect) -> NSValue {
#if canImport(UIKit)
        NSValue(cgRect: rect)
#else
        NSValue(rect: rect)
#endif
    }
    /// The payload keys are deliberately spelled as the documented raw
    /// strings: the production parse reads those same strings (ClientCore also
    /// builds for macOS, where the `UIResponder` constants do not exist), so a
    /// typo in either place fails these assertions.
    private func payload(duration: NSNumber? = NSNumber(value: 0.25),
                         curve: NSNumber? = NSNumber(value: 7),
                         begin: CGRect? = nil, end: CGRect? = nil,
                         isLocal: NSNumber? = NSNumber(value: true)) -> [AnyHashable: Any] {
        var userInfo: [AnyHashable: Any] = [:]
        if let duration { userInfo["UIKeyboardAnimationDurationUserInfoKey"] = duration }
        if let curve { userInfo["UIKeyboardAnimationCurveUserInfoKey"] = curve }
        if let begin { userInfo["UIKeyboardFrameBeginUserInfoKey"] = frameValue(begin) }
        if let end { userInfo["UIKeyboardFrameEndUserInfoKey"] = frameValue(end) }
        if let isLocal { userInfo["UIKeyboardIsLocalUserInfoKey"] = isLocal }
        return userInfo
    }
    private let onScreen = CGRect(x: 0, y: 564, width: 390, height: 336)
    private let offScreen = CGRect(x: 0, y: 900, width: 390, height: 336)

    @Test func willShowCarriesItsDirectionWithoutFrames() {
        let event = TimelineKeyboardEvent(source: .willShow, userInfo: payload())
        #expect(event.direction == .showing)
        #expect(event.duration == 0.25)
        #expect(event.curve == .privateSpring)
        #expect(event.isLocal)
        #expect(!event.isFinal)
    }

    @Test func willHideCarriesItsDirectionWithoutFrames() {
        let event = TimelineKeyboardEvent(source: .willHide, userInfo: payload(duration: NSNumber(value: 0.35)))
        #expect(event.direction == .hiding)
        #expect(event.duration == 0.35)
    }

    @Test func frameComparisonNamesTheDirection() {
        // Appearance: the top edge travels up from below the screen.
        let showing = TimelineKeyboardEvent(source: .willChangeFrame,
            userInfo: payload(begin: offScreen, end: onScreen))
        #expect(showing.direction == .showing)
        // Dismissal: it travels back down.
        let hiding = TimelineKeyboardEvent(source: .willChangeFrame,
            userInfo: payload(begin: onScreen, end: offScreen))
        #expect(hiding.direction == .hiding)
        // A height-only change (the predictive row, a keyboard swap) keeps the
        // top edge: not an appearance or a dismissal.
        let resized = TimelineKeyboardEvent(source: .willChangeFrame,
            userInfo: payload(begin: onScreen, end: CGRect(x: 0, y: 564, width: 390, height: 300)))
        #expect(resized.direction == .unchanged)
    }

    @Test func emptyAndMissingFramesStaySafe() {
        // Some systems report a zero begin frame on the first presentation.
        let firstPresentation = TimelineKeyboardEvent(source: .willChangeFrame,
            userInfo: payload(begin: .zero, end: onScreen))
        #expect(firstPresentation.direction == .showing)
        let teardown = TimelineKeyboardEvent(source: .willChangeFrame,
            userInfo: payload(begin: onScreen, end: .zero))
        #expect(teardown.direction == .hiding)
        #expect(TimelineKeyboardEvent(source: .willChangeFrame,
            userInfo: payload(begin: .zero, end: .zero)).direction == .unchanged)
        #expect(TimelineKeyboardEvent(source: .willChangeFrame, userInfo: payload()).direction == .unchanged)
        #expect(TimelineKeyboardEvent(source: .willChangeFrame,
            userInfo: payload(begin: onScreen)).direction == .unchanged)
    }

    @Test func missingFieldsFallBackToTheDocumentedDefaults() {
        let event = TimelineKeyboardEvent(source: .willChangeFrame, userInfo: [:])
        #expect(event.duration == 0)
        #expect(event.isFinal)
        #expect(event.curve == .easeInOut)
        #expect(event.isLocal)
        // A missing duration is a no-animation change: there is no transition
        // window to coordinate with.
        #expect(TimelineKeyboardEvent(source: .willShow,
            userInfo: payload(duration: NSNumber(value: 0))).isFinal)
        #expect(!TimelineKeyboardEvent(source: .willShow,
            userInfo: payload(duration: NSNumber(value: 0.01))).isFinal)
        #expect(!TimelineKeyboardEvent(source: .willShow,
            userInfo: payload(isLocal: NSNumber(value: false))).isLocal)
        // A missing curve can never be parsed as the private spring.
        #expect(TimelineKeyboardEvent(source: .willShow,
            userInfo: payload(curve: nil)).curve == .easeInOut)
    }

    @Test func curvesMapToTheirDocumentedRawValues() {
        let expected: [(Int, TimelineKeyboardEvent.Curve)] = [
            (0, .easeInOut), (1, .easeIn), (2, .easeOut), (3, .linear), (7, .privateSpring),
        ]
        for (raw, curve) in expected {
            #expect(TimelineKeyboardEvent.Curve(rawValue: raw) == curve)
            #expect(TimelineKeyboardEvent(source: .willShow,
                userInfo: payload(curve: NSNumber(value: raw))).curve == curve)
        }
        #expect(TimelineKeyboardEvent.Curve(rawValue: 99) == .unknown(99))
    }
}

@Suite struct TimelineKeyboardFollowPolicyTests {
    private func context(_ event: TimelineKeyboardFollowPolicy.Event,
                         isAtBottom: Bool = true,
                         mode: TimelineScrollState.Mode = .following,
                         phase: TimelineScrollState.Phase = .idle,
                         navigationIsSuspended: Bool = false,
                         hasPendingRequest: Bool = false) -> TimelineKeyboardFollowPolicy.Context {
        TimelineKeyboardFollowPolicy.Context(event: event, isAtBottom: isAtBottom, mode: mode,
            phase: phase, navigationIsSuspended: navigationIsSuspended, hasPendingRequest: hasPendingRequest)
    }
    private func action(_ context: TimelineKeyboardFollowPolicy.Context) -> TimelineKeyboardFollowPolicy.Action {
        TimelineKeyboardFollowPolicy.action(for: context)
    }

    @Test func showAtTheBottomRequestsOneKeyboardMatchedReturn() {
        #expect(action(context(.willShow)) == .requestReturn(.keyboardMatched))
    }

    @Test func showFollowsWheneverTheTimelineIsSteadyFollowing() {
        // Round 1.3: bottom-ness no longer gates a show — the device probe
        // showed the flag falsely negative while the reader watched the latest
        // messages, so the follow never started. The user-intent gate is the
        // mode (pinned above); a steady-following timeline takes the return
        // regardless of what the bottom probe says.
        #expect(action(context(.willShow, isAtBottom: false)) == .requestReturn(.keyboardMatched))
    }

    @Test func hideAtTheBottomSuppressesProgrammaticScrolling() {
        // The system clamp carries the content down with the keyboard; any
        // programmatic scroll would be a second animation fighting it.
        #expect(action(context(.willHide)) == .suppressProgrammatic)
    }

    @Test func hideOutOfViewDoesNothing() {
        #expect(action(context(.willHide, isAtBottom: false)) == .none)
    }

    @Test func draggingOwnsEveryTransition() {
        // The K4 interactive dismissal and any other gesture-driven scroll:
        // every non-idle phase answers .none for both directions, even with
        // otherwise-favorable inputs.
        for phase in [TimelineScrollState.Phase.tracking, .interacting, .decelerating, .animating] {
            #expect(action(context(.willShow, phase: phase)) == .none)
            #expect(action(context(.willHide, phase: phase)) == .none)
            #expect(action(context(.transitionEnded, isAtBottom: false,
                phase: phase, hasPendingRequest: true)) == .none)
        }
    }

    @Test func aSuspendedDrawerIgnoresTheKeyboard() {
        for event in [TimelineKeyboardFollowPolicy.Event.willShow, .willHide, .transitionEnded] {
            #expect(action(context(event, isAtBottom: false,
                navigationIsSuspended: true, hasPendingRequest: true)) == .none)
        }
    }

    @Test func onlyASteadyFollowingTimelineFollowsTheKeyboard() {
        // Reading — including a presented interaction card — owns the
        // position...
        #expect(action(context(.willShow, mode: .reading)) == .none)
        #expect(action(context(.willHide, mode: .reading)) == .none)
        // ...and an in-flight return needs no second opinion.
        #expect(action(context(.willShow, mode: .returning)) == .none)
        #expect(action(context(.willHide, mode: .returning)) == .none)
    }

    @Test func theEndRecheckOnlyFiresWhenTheReturnIsStillOwed() {
        // The window closed with the bottom unreached and a return withheld:
        // release it for exactly one make-up landing.
        #expect(action(context(.transitionEnded, isAtBottom: false, hasPendingRequest: true)) == .recheckAtEnd)
        // Already at the bottom again after the clamp: nothing to make up.
        #expect(action(context(.transitionEnded, isAtBottom: true, hasPendingRequest: true)) == .none)
        // Nothing owed.
        #expect(action(context(.transitionEnded, isAtBottom: false, hasPendingRequest: false)) == .none)
        // The reader is not at the bottom by choice.
        #expect(action(context(.transitionEnded, isAtBottom: false,
            mode: .reading, hasPendingRequest: false)) == .none)
    }
}

/// End-to-end traces: the policy decision, the transition window and the
/// scroll state's command production together, per the six scenarios the
/// audit lists. Command counts and their issuing moment are asserted directly.
@Suite struct TimelineKeyboardFollowCoordinationTests {
    private func viewport(offset: CGFloat = 0, height: CGFloat = 2000, container: CGFloat = 800) -> TimelineViewport {
        TimelineViewport(contentHeight: height, containerHeight: container, topInset: 80, bottomInset: 120, offsetY: offset)
    }
    private func visibility(_ state: inout TimelineScrollState, end: Bool, near: Bool? = nil) {
        state.tailVisibilityChanged(.near, visible: near ?? end)
        state.tailVisibilityChanged(.end, visible: end)
    }
    private func nextCommand(_ state: inout TimelineScrollState) throws -> TimelineScrollState.BottomCommand {
        // The macro captures its expression immutably; take the mutating
        // result out of the macro first (same as TimelineNavigationTests).
        let request = try #require(state.pendingBottomRequest)
        let command = state.begin(request)
        return try #require(command)
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
    private func action(_ event: TimelineKeyboardFollowPolicy.Event, _ state: TimelineScrollState,
                        isAtBottom: Bool? = nil) -> TimelineKeyboardFollowPolicy.Action {
        TimelineKeyboardFollowPolicy.action(for: .init(event: event,
            isAtBottom: isAtBottom ?? state.viewportIsAtBottom, mode: state.mode, phase: state.phase,
            navigationIsSuspended: state.navigationIsSuspended,
            hasPendingRequest: state.pendingBottomRequest != nil))
    }

    @Test func showAtTheBottomBeginsOneMatchedCommandInTheKeyboardTurn() throws {
        var state = try openedAtBottom()
        #expect(action(.willShow, state) == .requestReturn(.keyboardMatched))
        // Flag-first, as the view does it: the window opens before the command
        // is begun, so the hold is armed for this same turn.
        state.setKeyboardTransitionActive(true)
        let keyboardReturn = state.beginKeyboardReturn()
        let command = try #require(keyboardReturn)
        #expect(command.keyboardMatched && !command.instant)
        // Beginning in the notification's own turn consumes the request, so
        // the 24ms coalescing task has nothing to restart: one command only.
        #expect(state.pendingBottomRequest == nil)
        // The frame stream while the container shrinks is withheld (S2) and
        // the tail probe's flip during the transition cannot start the spring
        // (F11) while the window is open.
        let shrinking = viewport(offset: 1520, container: 600)
        #expect(TimelineViewportPublicationDecision.outcome(published: state.viewport, next: shrinking,
            keyboardTransitionActive: true, tailChanged: false) == .ignore)
        visibility(&state, end: false)
        #expect(state.pendingBottomRequest == nil)
        // K5 (round 1.1): an early completion — a zero-distance match reports
        // one immediately — is held by the open window, not settled.
        let heldEarly = state.complete(command)
        #expect(!heldEarly)
        #expect(state.activeCommand == command)
        #expect(state.mode == .returning)
        visibility(&state, end: true)
        // The window's end is what settles the held matched command; the
        // caller releases the edge target then.
        let settledAtWindowEnd = state.endKeyboardTransition()
        #expect(settledAtWindowEnd)
        #expect(state.activeCommand == nil)
        #expect(state.mode == .following)
        #expect(!state.keyboardTransitionActive)
        // Window close: the settled height lands, the bottom is reached, and
        // no make-up is owed.
        #expect(TimelineViewportPublicationDecision.outcome(published: state.viewport, next: shrinking,
            keyboardTransitionActive: false, tailChanged: false) == .publish)
        state.geometryChanged(shrinking)
        #expect(action(.transitionEnded, state) == .none)
        #expect(state.pendingBottomRequest == nil)
    }

    @Test func theEndRecheckLandsOneMakeUpWhenTheBottomIsStillUnreached() throws {
        var state = try openedAtBottom()
        state.setKeyboardTransitionActive(true)
        let keyboardReturn = state.beginKeyboardReturn()
        let command = try #require(keyboardReturn)
        let shrinking = viewport(offset: 1220, container: 600)
        visibility(&state, end: false)
        // K5 (round 1.1): the early completion is held while the window is
        // open; the window's end settles the matched command instead.
        let heldEarly = state.complete(command)
        #expect(!heldEarly)
        #expect(state.mode == .returning)
        // The probe never flipped back (a stubby remaining gap): the settled
        // sample publishes, the recheck sees the return still owed, and
        // exactly one normal make-up return follows.
        state.geometryChanged(shrinking)
        let settledAtWindowEnd = state.endKeyboardTransition()
        #expect(settledAtWindowEnd)
        #expect(state.activeCommand == nil)
        #expect(state.mode == .following)
        #expect(action(.transitionEnded, state) == .recheckAtEnd)
        state.requestBottom()
        let makeUp = try nextCommand(&state)
        #expect(!makeUp.keyboardMatched && !makeUp.instant)
        let makeUpLanded = state.complete(makeUp)
        #expect(makeUpLanded && state.mode == .following)
        // Once landed, the same layout does not request again (dedup intact).
        state.geometryChanged(shrinking)
        #expect(state.pendingBottomRequest == nil)
    }

    @Test func aMatchedCompletionIsHeldWhileTheWindowIsOpen() throws {
        var state = try openedAtBottom()
        state.setKeyboardTransitionActive(true)
        let keyboardReturn = state.beginKeyboardReturn()
        let command = try #require(keyboardReturn)
        // A zero-distance match can report completion in the window's own
        // turn; the hold keeps the command (and its edge target) alive.
        let settledEarly = state.complete(command)
        #expect(!settledEarly)
        #expect(state.activeCommand == command)
        #expect(state.mode == .returning)
    }

    @Test func endingTheWindowOnlySettlesAHeldMatchedCommand() throws {
        // Nothing active: the window closes and reports nothing to release.
        var idle = try openedAtBottom()
        idle.setKeyboardTransitionActive(true)
        let idleSettled = idle.endKeyboardTransition()
        #expect(!idleSettled)
        #expect(!idle.keyboardTransitionActive)
        #expect(idle.activeCommand == nil)

        // A plain (non-matched) return is not the window's to settle: it stays
        // active after the window closes and its own completion lands it.
        var plain = try openedAtBottom()
        visibility(&plain, end: false)
        plain.geometryChanged(viewport(offset: 1220, height: 2200))
        plain.requestBottom()
        let plainCommand = try nextCommand(&plain)
        #expect(!plainCommand.keyboardMatched)
        plain.setKeyboardTransitionActive(true)
        let plainEnded = plain.endKeyboardTransition()
        #expect(!plainEnded)
        #expect(!plain.keyboardTransitionActive)
        #expect(plain.activeCommand == plainCommand)
        let plainSettled = plain.complete(plainCommand)
        #expect(plainSettled)
        #expect(plain.mode == .following)
    }

    @Test func aPlainReturnCompletesNormallyInsideTheWindow() throws {
        var state = try openedAtBottom()
        visibility(&state, end: false)
        state.geometryChanged(viewport(offset: 1220, height: 2200))
        state.requestBottom()
        let command = try nextCommand(&state)
        #expect(!command.keyboardMatched)
        // The window only holds the matched return it was opened for; a plain
        // command settles on its own completion even while it is open.
        state.setKeyboardTransitionActive(true)
        let settled = state.complete(command)
        #expect(settled)
        #expect(state.activeCommand == nil)
        #expect(state.mode == .following)
    }

    @Test func aMatchedReturnCompletesNormallyOnceTheWindowIsClosed() throws {
        var state = try openedAtBottom()
        state.setKeyboardTransitionActive(true)
        let keyboardReturn = state.beginKeyboardReturn()
        let command = try #require(keyboardReturn)
        // The window closed before the animation reported: the command's own
        // completion is no longer held.
        state.setKeyboardTransitionActive(false)
        let settled = state.complete(command)
        #expect(settled)
        #expect(state.activeCommand == nil)
        #expect(state.mode == .following)
    }

    @Test func theHeldMatchedReturnWaitsForTheContainerToMove() throws {
        // K5 (round 1.3): the notification's own turn still measures the
        // pre-keyboard container, so a scroll issued then resolves against the
        // old layout and travels nothing. The held return fires at the first
        // sample whose visible height moved off the begin-time baseline — the
        // device probe shows exactly one such step per transition, carrying
        // the full travel.
        var state = try openedAtBottom()
        state.setKeyboardTransitionActive(true)
        let keyboardReturn = state.beginKeyboardReturn()
        let command = try #require(keyboardReturn)
        // Unchanged (600pt) and a sub-half-point wobble are rounding, not the
        // keyboard reaching the layout.
        #expect(state.keyboardReturnScrollDue(sample: viewport(offset: 1320)) == nil)
        #expect(state.keyboardReturnScrollDue(sample: viewport(offset: 1320, container: 799.5)) == nil)
        // A whole point of movement is the container answering: fire.
        #expect(state.keyboardReturnScrollDue(sample: viewport(offset: 1320, container: 799)) == command)
    }

    @Test func theHeldMatchedReturnFiresExactlyOncePerWindow() throws {
        var state = try openedAtBottom()
        state.setKeyboardTransitionActive(true)
        let keyboardReturn = state.beginKeyboardReturn()
        let command = try #require(keyboardReturn)
        #expect(state.keyboardReturnScrollDue(sample: viewport(offset: 1320, container: 600)) == command)
        // Any further change in the same window cannot issue a second scroll.
        #expect(state.keyboardReturnScrollDue(sample: viewport(offset: 1320, container: 500)) == nil)
        #expect(state.keyboardReturnScrollDue(sample: viewport(offset: 1320, container: 700)) == nil)
    }

    @Test func onlyAHeldMatchedCommandCanBecomeDue() throws {
        // Nothing begun: there is no command to fire.
        var idle = try openedAtBottom()
        #expect(idle.keyboardReturnScrollDue(sample: viewport(offset: 1320, container: 600)) == nil)
        // A plain spring return replacing the active command refuses the due.
        var replaced = try openedAtBottom()
        let matchedReturn = replaced.beginKeyboardReturn()
        _ = try #require(matchedReturn)
        visibility(&replaced, end: false)
        replaced.geometryChanged(viewport(offset: 1220, height: 2200))
        let nextRequest = try #require(replaced.pendingBottomRequest)
        let plainReturn = replaced.begin(nextRequest)
        let plainCommand = try #require(plainReturn)
        #expect(!plainCommand.keyboardMatched)
        #expect(replaced.activeCommand == plainCommand)
        #expect(replaced.keyboardReturnScrollDue(
            sample: viewport(offset: 1220, height: 2200, container: 500)) == nil)
        // A matched command already settled by the window's end is no longer
        // held; nothing fires for it.
        var settled = try openedAtBottom()
        settled.setKeyboardTransitionActive(true)
        let heldReturn = settled.beginKeyboardReturn()
        _ = try #require(heldReturn)
        let settledAtWindowEnd = settled.endKeyboardTransition()
        #expect(settledAtWindowEnd)
        #expect(settled.keyboardReturnScrollDue(sample: viewport(offset: 1320, container: 600)) == nil)
    }

    @Test func aReopenedWindowTakesItsBaselineFromTheLatestBegin() throws {
        // Two returns in one keyboard cycle (a reopening transition): each
        // begin resets the baseline, so the second window is judged against
        // the layout it started from, not the first window's stale height.
        var state = try openedAtBottom()
        state.setKeyboardTransitionActive(true)
        let firstReturn = state.beginKeyboardReturn()
        let first = try #require(firstReturn)
        let shrinking = viewport(offset: 1320, container: 600)
        #expect(state.keyboardReturnScrollDue(sample: shrinking) == first)
        state.geometryChanged(shrinking)
        let firstEnd = state.endKeyboardTransition()
        #expect(firstEnd)
        state.setKeyboardTransitionActive(true)
        let secondReturn = state.beginKeyboardReturn()
        let second = try #require(secondReturn)
        #expect(state.keyboardReturnScrollDue(sample: shrinking) == nil)
        #expect(state.keyboardReturnScrollDue(sample: viewport(offset: 1320, container: 500)) == second)
    }

    @Test func theAtBottomTruthIsMeasuredNotProbed() throws {
        // K5 (round 1.3): the device probe logged "at bottom" from the tail
        // flag while the measured gap sat 213pt short — the follow chain,
        // gated on that flag, never started. Glued geometry reads at bottom
        // even against a negative probe…
        var glued = try openedAtBottom()
        visibility(&glued, end: false)
        #expect(glued.viewportIsAtBottom)
        // …a measured gap overrules a probe that says yes, so the drifted
        // page produces the return the flag used to suppress (the exact
        // device reading: content 2000, resting 213pt short)…
        var lied = try openedAtBottom()
        lied.geometryChanged(viewport(offset: 1107, height: 2200))
        #expect(!lied.viewportIsAtBottom)
        #expect(lied.pendingBottomRequest != nil)
        // …and before the first measurement the probes remain the fallback.
        var unmeasured = TimelineScrollState()
        unmeasured.tailVisibilityChanged(.near, visible: true)
        unmeasured.tailVisibilityChanged(.end, visible: true)
        #expect(unmeasured.viewportIsAtBottom)
    }

    @Test func theWindowEndSendsAPresentedReturnToReading() throws {
        // complete()'s established rule: an arrived return with an interaction
        // presented goes to reading, not following. The window-end settlement
        // keeps that rule.
        var direct = try openedAtBottom()
        direct.setInteractionPresented(true)
        let directReturn = direct.beginKeyboardReturn()
        let directCommand = try #require(directReturn)
        let directSettled = direct.complete(directCommand)
        #expect(directSettled)
        #expect(direct.mode == .reading)

        var held = try openedAtBottom()
        held.setInteractionPresented(true)
        held.setKeyboardTransitionActive(true)
        let heldReturn = held.beginKeyboardReturn()
        let heldCommand = try #require(heldReturn)
        let heldEarly = held.complete(heldCommand)
        #expect(!heldEarly)
        #expect(held.mode == .returning)
        let heldSettled = held.endKeyboardTransition()
        #expect(heldSettled)
        #expect(held.mode == .reading)
    }

    @Test func hideAtTheBottomSuppressesTheSpringUntilTheWindowCloses() throws {
        var state = try openedAtBottom()
        #expect(action(.willHide, state) == .suppressProgrammatic)
        state.setKeyboardTransitionActive(true)
        // The clamp grows the container; the withheld sample and the probe
        // flip cannot produce a command during the window.
        let grown = viewport(offset: 1000, container: 1000)
        #expect(TimelineViewportPublicationDecision.outcome(published: state.viewport, next: grown,
            keyboardTransitionActive: true, tailChanged: false) == .ignore)
        visibility(&state, end: false)
        #expect(state.pendingBottomRequest == nil)
        // The window closes: the settled height lands and the still-unreached
        // bottom is made up exactly once.
        state.geometryChanged(grown)
        state.setKeyboardTransitionActive(false)
        #expect(action(.transitionEnded, state) == .recheckAtEnd)
        state.requestBottom()
        let makeUp = try nextCommand(&state)
        #expect(!makeUp.keyboardMatched && !makeUp.instant)
        let makeUpLanded = state.complete(makeUp)
        #expect(makeUpLanded && state.mode == .following)
    }

    @Test func readingIgnoresBothDirections() throws {
        var state = try openedAtBottom()
        state.browseHistory()
        #expect(action(.willShow, state, isAtBottom: false) == .none)
        #expect(action(.willHide, state, isAtBottom: false) == .none)
        #expect(action(.transitionEnded, state, isAtBottom: false) == .none)
        // Nothing the keyboard does can move the reader.
        #expect(state.pendingBottomRequest == nil && !state.returningToBottom)
    }

    @Test func theOpeningInstantReturnIsNeverConsumedByAKeyboardReturn() throws {
        var state = TimelineScrollState()
        state.geometryChanged(viewport())
        visibility(&state, end: false)
        state.open()
        // While the opening return is still pending the gate refuses to touch
        // it (mode == .returning is not steady following).
        #expect(action(.willShow, state, isAtBottom: true) == .none)
        let opening = try nextCommand(&state)
        #expect(opening.instant && !opening.keyboardMatched)
        let openingLanded = state.complete(opening)
        #expect(openingLanded)
        // Every later keyboard return is an animated, matched one.
        let laterReturn = state.beginKeyboardReturn()
        let keyboard = try #require(laterReturn)
        #expect(!keyboard.instant && keyboard.keyboardMatched)
    }

    @Test func aSuspendedDrawerWithholdsAndResumes() throws {
        var state = try openedAtBottom()
        state.setNavigationSuspended(true)
        #expect(action(.willShow, state, isAtBottom: true) == .none)
        #expect(action(.willHide, state, isAtBottom: true) == .none)
        state.requestBottom()
        #expect(state.pendingBottomRequest == nil)
        state.setNavigationSuspended(false)
        #expect(state.pendingBottomRequest != nil)
    }

    @Test func aDragOwnsTheInteractiveDismissal() throws {
        var state = try openedAtBottom()
        state.phaseChanged(.tracking, viewport: viewport(offset: 1320))
        state.phaseChanged(.interacting, viewport: viewport(offset: 900))
        #expect(action(.willHide, state) == .none)
        #expect(state.mode == .reading && state.pendingBottomRequest == nil)
    }

    @Test func theHoldWithholdsOnlyWhileItIsSet() throws {
        var state = try openedAtBottom()
        // Away from the bottom, so only the hold can be what withholds.
        visibility(&state, end: false)
        state.setKeyboardTransitionActive(true)
        state.geometryChanged(viewport(offset: 1220, height: 2200))
        #expect(state.pendingBottomRequest == nil)
        // Releasing the hold lets the same conditions produce their request.
        state.setKeyboardTransitionActive(false)
        #expect(state.pendingBottomRequest != nil)
    }

    /// The six audit combinations: following + tail visible / reading /
    /// opening instant / drawer suspended / drag, each under show and hide.
    /// Exactly the following-at-the-bottom branch issues a command, and only
    /// on show.
    @Test func showAndHideIssueCommandsOnlyInTheFollowingAtBottomBranch() throws {
        for direction in [TimelineKeyboardFollowPolicy.Event.willShow, TimelineKeyboardFollowPolicy.Event.willHide] {
            for scenario in TransitionScenario.allCases {
                var state = try scenario.makeState()
                let decision = action(direction, state)
                #expect(decision == scenario.expectedAction(for: direction))
                var commands = 0
                switch decision {
                case .requestReturn(.keyboardMatched):
                    if state.beginKeyboardReturn() != nil { commands += 1 }
                case .suppressProgrammatic:
                    state.setKeyboardTransitionActive(true)
                case .none, .recheckAtEnd:
                    break
                }
                #expect(commands == scenario.expectedCommands(for: direction))
            }
        }
        // The two branches that do act: the matched return on show, the
        // suppression window on hide.
        #expect(action(.willShow, try TransitionScenario.followingAtBottom.makeState()) == .requestReturn(.keyboardMatched))
        #expect(action(.willHide, try TransitionScenario.followingAtBottom.makeState()) == .suppressProgrammatic)
    }
}

private enum TransitionScenario: CaseIterable {
    case followingAtBottom
    case reading
    case openingPending
    case drawerSuspended
    case dragging

    private func viewport(offset: CGFloat = 0, height: CGFloat = 2000, container: CGFloat = 800) -> TimelineViewport {
        TimelineViewport(contentHeight: height, containerHeight: container, topInset: 80, bottomInset: 120, offsetY: offset)
    }
    func makeState() throws -> TimelineScrollState {
        switch self {
        case .openingPending:
            var state = TimelineScrollState()
            state.geometryChanged(viewport(offset: 1320))
            state.tailVisibilityChanged(.near, visible: true)
            state.tailVisibilityChanged(.end, visible: true)
            state.open()
            return state
        case .reading, .drawerSuspended, .dragging, .followingAtBottom:
            var state = TimelineScrollState()
            state.geometryChanged(viewport(offset: 1320))
            state.tailVisibilityChanged(.near, visible: true)
            state.tailVisibilityChanged(.end, visible: true)
            state.open()
            let request = try #require(state.pendingBottomRequest)
            let pendingCommand = state.begin(request)
            let command = try #require(pendingCommand)
            let completed = state.complete(command)
            #expect(completed)
            switch self {
            case .reading: state.browseHistory()
            case .drawerSuspended: state.setNavigationSuspended(true)
            case .dragging:
                state.phaseChanged(.tracking, viewport: viewport(offset: 1320))
                state.phaseChanged(.interacting, viewport: viewport(offset: 900))
            case .followingAtBottom, .openingPending: break
            }
            return state
        }
    }
    func expectedAction(for direction: TimelineKeyboardFollowPolicy.Event) -> TimelineKeyboardFollowPolicy.Action {
        guard self == .followingAtBottom else { return .none }
        return direction == .willShow ? .requestReturn(.keyboardMatched) : .suppressProgrammatic
    }
    func expectedCommands(for direction: TimelineKeyboardFollowPolicy.Event) -> Int {
        expectedAction(for: direction) == .requestReturn(.keyboardMatched) ? 1 : 0
    }
}

import Foundation
import Testing
@testable import ClientCore

/// Snapshot fixture with `rows` recent records and a controllable history flag.
private func openingSnapshotPage(rows: Int, hasMore: Bool) throws -> Data {
    var snapshot = try fixtureObject("snapshot")
    var timeline = snapshot["timeline"] as! [String: Any]
    timeline["items"] = try (1...rows).map { try itemObject(id: "reply-\($0)", order: $0) }
    timeline["hasMore"] = hasMore
    snapshot["timeline"] = timeline
    return try JSONSerialization.data(withJSONObject: snapshot)
}

/// Timeline page fixture holding the given record orders.
private func openingTimelinePage(rows: [Int], hasMore: Bool = false) throws -> Data {
    var page = try fixtureObject("timeline")
    page["items"] = try rows.map { try itemObject(id: "reply-\($0)", order: $0) }
    page["hasMore"] = hasMore
    return try JSONSerialization.data(withJSONObject: page)
}

/// T1.2 — the first return after opening lands without an animation; every
/// later return keeps the spring, and the reading/returning state machine is
/// unchanged around it.
@Suite struct OpeningInstantReturnTests {
    private func viewport(offset: CGFloat = 0, height: CGFloat = 2000, container: CGFloat = 800) -> TimelineViewport {
        TimelineViewport(contentHeight: height, containerHeight: container, topInset: 80, bottomInset: 120, offsetY: offset)
    }
    private func nextCommand(_ state: inout TimelineScrollState) throws -> TimelineScrollState.BottomCommand {
        let request = try #require(state.pendingBottomRequest)
        // The macro captures its expression immutably; take the mutating
        // result out of the macro first (same for the assertions below).
        let command = state.begin(request)
        return try #require(command)
    }
    private func visibility(_ state: inout TimelineScrollState, end: Bool) {
        state.tailVisibilityChanged(.near, visible: end)
        state.tailVisibilityChanged(.end, visible: end)
    }

    @Test func theOpeningReturnIsInstantAndLaterReturnsKeepTheAnimation() throws {
        var state = TimelineScrollState()
        state.geometryChanged(viewport())
        visibility(&state, end: false)
        state.open()
        let opening = try nextCommand(&state)
        #expect(opening.instant)
        // The instant return lands before its completion is acknowledged
        // (the view acknowledges on measured arrival), so the resting state
        // is judged at the bottom.
        state.geometryChanged(viewport(offset: 1320))
        let completed = state.complete(opening)
        #expect(completed)
        #expect(state.mode == .following && state.pendingBottomRequest == nil)
        // Sending, accepted responses and the bottom pill all reuse the
        // animated return.
        state.requestBottom()
        let later = try nextCommand(&state)
        #expect(!later.instant)
        let completedLater = state.complete(later)
        #expect(completedLater)
        #expect(state.mode == .following)
    }

    @Test func aReaderGestureBeforeTheFirstCommandLeavesLaterReturnsAnimated() throws {
        var state = TimelineScrollState()
        state.geometryChanged(viewport())
        visibility(&state, end: false)
        state.open()
        // The reader takes over before the opening command is issued. The
        // opening intent is gone; the next explicit return is a normal one.
        state.phaseChanged(.tracking, viewport: viewport(offset: -40))
        state.phaseChanged(.interacting, viewport: viewport(offset: -40))
        state.phaseChanged(.idle, viewport: viewport(offset: -40))
        state.settleUserScroll()
        #expect(state.mode == .reading)
        state.requestBottom()
        let command = try nextCommand(&state)
        #expect(!command.instant)
    }

    @Test func aDrawerInterruptionDoesNotConsumeTheInstantOpening() throws {
        var state = TimelineScrollState()
        state.geometryChanged(viewport())
        visibility(&state, end: false)
        state.open()
        state.setNavigationSuspended(true)
        #expect(state.pendingBottomRequest == nil)
        state.setNavigationSuspended(false)
        let opening = try nextCommand(&state)
        #expect(opening.instant)
        let completed = state.complete(opening)
        #expect(completed && state.mode == .following)
    }

    @Test func openingAtTheBottomStillIssuesItsOneInstantCommand() throws {
        var state = TimelineScrollState()
        state.geometryChanged(viewport(offset: 1320))
        visibility(&state, end: true)
        state.open()
        let opening = try nextCommand(&state)
        #expect(opening.instant)
        let completed = state.complete(opening)
        #expect(completed && state.mode == .following && state.pendingBottomRequest == nil)
    }

    @Test func readingAndExplicitReturnsKeepFollowingSemanticsAfterTheInstantOpening() throws {
        var state = TimelineScrollState()
        state.geometryChanged(viewport())
        visibility(&state, end: false)
        state.open()
        let opening = try nextCommand(&state)
        #expect(opening.instant)
        let completed = state.complete(opening)
        #expect(completed && state.mode == .following)
        // Manual reading still wins, and the reader can return with the pill.
        state.phaseChanged(.interacting, viewport: viewport(offset: 300))
        state.phaseChanged(.idle, viewport: viewport(offset: 300))
        state.settleUserScroll()
        #expect(state.mode == .reading && state.showsBottomButton())
        state.requestBottom()
        let returned = try nextCommand(&state)
        #expect(!returned.instant && state.returningToBottom)
        state.phaseChanged(.animating, viewport: viewport(offset: 800))
        visibility(&state, end: true)
        state.phaseChanged(.idle, viewport: viewport(offset: 1320))
        let returnedCompleted = state.complete(returned)
        #expect(returnedCompleted && state.mode == .following && !state.showsBottomButton())
    }
}

/// T1.4 — a memory-cached visit presents its snapshot before the network
/// refresh completes; the cold path keeps presenting only after the snapshot
/// arrives, and the cold-load mask waits for the first positioning or its
/// bounded fallback.
@Suite @MainActor struct OpeningFastPathPresentationTests {
    /// A tiny window (one record) makes the history-overflow flag reachable:
    /// one older page pushes the newest rows out of the projection, so `open()`
    /// must still fetch the latest page for an in-memory projection.
    private func overflowed(_ http: TestHTTPTransport) async throws -> V2SessionRepository {
        let repo = repository(transport: http, policy: V2SessionCachePolicy(maximumTimelineItems: 1))
        _ = try await repo.load(sessionId: "session")
        _ = try await repo.loadOlder(sessionId: "session")
        return repo
    }
    private func chat(_ repo: V2SessionRepository, _ http: TestHTTPTransport) -> SessionChatModel {
        SessionChatModel(session: repo.session(id: "session"), repository: repo,
            attachments: .init(attachmentAPI: V2AttachmentAPI(transport: http)))
    }

    @Test func cachedOpeningPresentsBeforeTheNetworkRefreshCompletes() async throws {
        let http = TestHTTPTransport()
        let gate = TestGate()
        var latestStarted = false
        http.respond = { call in
            if call.path.hasSuffix("snapshot") { return try openingSnapshotPage(rows: 2, hasMore: true) }
            if call.path.hasSuffix("timeline") {
                if call.query.contains(where: { $0.name == "mode" && $0.value == "history" }) {
                    return try openingTimelinePage(rows: [1])
                }
                latestStarted = true
                await gate.wait()
                return try openingTimelinePage(rows: [1, 2])
            }
            return try http.defaultResponse(call)
        }
        let repo = try await overflowed(http)
        defer { repo.reset() }
        #expect(repo.cached(sessionId: "session")?.hasNewerItems == true)
        let model = chat(repo, http)
        // The memory snapshot suppresses the full-screen cold mask from the
        // first frame (D3).
        #expect(model.opensFromCachedSnapshot)
        #expect(!model.showsOpeningMask)
        let opening = Task { await model.prepareOpening() }
        defer { gate.release(); opening.cancel() }
        try await eventually { latestStarted }
        // The refresh is still blocked in the network, but the cached window is
        // already presented and the page is ready (D3). Presentation preceded
        // the refresh.
        #expect(model.timeline.rows.map(\.id) == ["reply-1"])
        #expect(model.isOpeningReady && model.openingError == nil)
        #expect(!model.openingPositionSettled)
        gate.release()
        await opening.value
        // The late refresh merges through the same stage/flush path without
        // rebuilding or duplicating rows.
        #expect(model.timeline.rows.map(\.id) == ["reply-2"])
        #expect(model.isOpeningReady && model.openingError == nil)
    }

    /// R-a guard — the early window is trimmed exactly like `open()` trims the
    /// projection: when the cached visit holds more than one page, the reader
    /// sees the newest 100 rows, so a later refresh can never remove a row
    /// that was already presented. Dropping `.suffix(100)` in
    /// `prepareOpening` presents the untrimmed cache and turns this red.
    @Test func cachedOpeningPresentsTheTrimmedWindowWhileTheRefreshIsBlocked() async throws {
        let http = TestHTTPTransport()
        let gate = TestGate()
        var latestStarted = false
        http.respond = { call in
            if call.path.hasSuffix("snapshot") { return try openingSnapshotPage(rows: 130, hasMore: true) }
            if call.path.hasSuffix("timeline") {
                if call.query.contains(where: { $0.name == "mode" && $0.value == "history" }) {
                    return try openingTimelinePage(rows: Array(1...10))
                }
                latestStarted = true
                await gate.wait()
                return try openingTimelinePage(rows: Array(121...130))
            }
            return try http.defaultResponse(call)
        }
        // A window wider than one opening page, so the cached visit really
        // holds more rows than the early presentation is allowed to show.
        let repo = repository(transport: http, policy: V2SessionCachePolicy(maximumTimelineItems: 120))
        defer { repo.reset() }
        _ = try await repo.load(sessionId: "session")
        _ = try await repo.loadOlder(sessionId: "session")
        let cached = try #require(repo.cached(sessionId: "session"))
        #expect(cached.items.count == 120)
        #expect(cached.hasNewerItems)

        let model = chat(repo, http)
        let opening = Task { await model.prepareOpening() }
        defer { gate.release(); opening.cancel() }
        try await eventually { latestStarted }
        // The refresh is still blocked in the network. The cached window was
        // presented before it, trimmed to the newest 100 rows.
        #expect(model.timeline.rows.map(\.id) == (21...120).map { "reply-\($0)" })
        gate.release()
        await opening.value
        #expect(model.isOpeningReady && model.openingError == nil)
    }

    @Test func cachedOpeningStaysReadyWhenTheRefreshFails() async throws {
        let http = TestHTTPTransport()
        http.respond = { call in
            if call.path.hasSuffix("snapshot") { return try openingSnapshotPage(rows: 2, hasMore: true) }
            if call.path.hasSuffix("timeline"), call.query.contains(where: { $0.name == "mode" && $0.value == "history" }) {
                return try openingTimelinePage(rows: [1])
            }
            return try http.defaultResponse(call)
        }
        let repo = try await overflowed(http)
        defer { repo.reset() }
        let model = chat(repo, http)
        repo.updateConnectivity(.init(availability: .offline))
        await model.prepareOpening()
        // The catch path is unchanged: the cached window still opens, and the
        // failure surfaces as an actionable error instead of a blocked mask.
        #expect(model.isOpeningReady && model.openingError != nil)
        #expect(model.timeline.rows.map(\.id) == ["reply-1"])
    }

    @Test func coldOpeningPresentsOnlyAfterTheSnapshotArrives() async throws {
        let http = TestHTTPTransport()
        let gate = TestGate()
        var snapshotStarted = false
        http.respond = { call in
            guard call.path.hasSuffix("snapshot") else { return try http.defaultResponse(call) }
            snapshotStarted = true
            await gate.wait()
            return try http.defaultResponse(call)
        }
        let repo = repository(transport: http)
        defer { repo.reset() }
        let model = chat(repo, http)
        #expect(!model.opensFromCachedSnapshot && model.showsOpeningMask)
        let opening = Task { await model.prepareOpening() }
        defer { gate.release(); opening.cancel() }
        try await eventually { snapshotStarted }
        // A cold load never presents rows before its snapshot arrives.
        #expect(!model.isOpeningReady && model.timeline.rows.isEmpty)
        #expect(model.showsOpeningMask)
        gate.release()
        await opening.value
        #expect(model.isOpeningReady && !model.timeline.rows.isEmpty)
        #expect(model.openingError == nil)
    }

    @Test func coldMaskWaitsForTheFirstPositioningOrItsBoundedFallback() async throws {
        let http = TestHTTPTransport()
        let repo = repository(transport: http)
        defer { repo.reset() }
        let model = chat(repo, http)
        await model.prepareOpening()
        #expect(model.isOpeningReady && !model.timeline.rows.isEmpty)
        // The first return has not been acknowledged yet: the cold mask still
        // covers the page so the reader never sees the top of the window.
        #expect(!model.openingPositionSettled && model.showsOpeningMask)
        model.openingPositionDidSettle()
        #expect(model.openingPositionSettled && !model.showsOpeningMask)
        model.openingPositionDidSettle()
        #expect(model.openingPositionSettled && !model.showsOpeningMask)
    }

}

/// 2026-10-08 — the parked-viewport fix (sess_ps8Z29uknMTIhw: a switch into a
/// running heavy session rendered blank/only a few rows until a manual
/// scroll). The opening lands through one instant return; every later
/// wholesale window change (the opening's trim/latest-page surgery, a
/// recovery or snapshot replacement) anchors to the top of the new content,
/// so the page can rest at the window top instead of the newest rows. The
/// follow machinery is not a guarantee there: its gates judge
/// reading/interaction/at-bottom from the instant's state. The opening visit
/// therefore re-arms its own instant return for each window change, and only
/// the reader can end that claim.
@Suite struct OpeningWindowReassertTests {
    private func viewport(offset: CGFloat = 0, height: CGFloat = 2000, container: CGFloat = 800) -> TimelineViewport {
        TimelineViewport(contentHeight: height, containerHeight: container, topInset: 80, bottomInset: 120, offsetY: offset)
    }
    private func nextCommand(_ state: inout TimelineScrollState) throws -> TimelineScrollState.BottomCommand {
        let request = try #require(state.pendingBottomRequest)
        let command = state.begin(request)
        return try #require(command)
    }
    private func visibility(_ state: inout TimelineScrollState, end: Bool) {
        state.tailVisibilityChanged(.near, visible: end)
        state.tailVisibilityChanged(.end, visible: end)
    }
    /// The opening return already landed at the bottom of the presented
    /// window: the state follows and has nothing pending.
    private func openedAtBottom() throws -> TimelineScrollState {
        var state = TimelineScrollState()
        state.geometryChanged(viewport(offset: 1320))
        visibility(&state, end: true)
        state.open()
        let command = try nextCommand(&state)
        // The macro captures its expression immutably; take the mutating
        // result out of it (same for the assertions below).
        let completed = state.complete(command)
        #expect(completed)
        #expect(state.mode == .following && state.pendingBottomRequest == nil)
        return state
    }

    @Test func anApprovalParkedPageStillReassertsTheOpeningReturn() throws {
        var state = try openedAtBottom()
        // An approval arrives: automatic following stops (the reader may be
        // looking at the card), so the mode turns reading and every follow
        // gate closes — including the R2 backstop, which requires following.
        state.setInteractionPresented(true)
        #expect(state.mode == .reading)
        // The window is then replaced wholesale (the opening's latest-page
        // surgery, or a recovery snapshot that dropped the presented rows).
        // The content anchors to the top, so the page now rests at the top of
        // the new window.
        state.geometryChanged(viewport(offset: 0, height: 2600))
        visibility(&state, end: false)
        // The follow machinery refuses the parked page...
        #expect(state.pendingBottomRequest == nil)
        let reconciled = state.reconcileToBottom()
        #expect(!reconciled)
        // ...and the opening re-assert owns it: the same instant return the
        // opening itself issues, not a new animated behaviour.
        let reasserted = state.reassertOpeningReturn()
        #expect(reasserted)
        let command = try nextCommand(&state)
        #expect(command.instant)
        state.geometryChanged(viewport(offset: 1920, height: 2600))
        visibility(&state, end: true)
        let completed = state.complete(command)
        #expect(completed)
        // The approval keeps following off, but the page is at the bottom
        // again: the notice's card lives at the tail.
        #expect(state.viewport.measuredAtBottom)
        #expect(state.mode == .reading)
    }

    @Test func aWindowChangeWhileFollowingReissuesTheInstantReturn() throws {
        var state = try openedAtBottom()
        state.geometryChanged(viewport(offset: 0, height: 2600))
        visibility(&state, end: false)
        // Mutation guard: dropping `openingReturnIsPending = true` from the
        // re-assert issues an animated return instead, and this turns red.
        let reasserted = state.reassertOpeningReturn()
        #expect(reasserted)
        let command = try nextCommand(&state)
        #expect(command.instant)
    }

    @Test func aReaderGestureEndsTheOpeningClaim() throws {
        var state = try openedAtBottom()
        state.phaseChanged(.tracking, viewport: viewport(offset: 900, height: 2600))
        #expect(state.readerTookOver && state.mode == .reading)
        // The reader owns the page now: a later window change must not move
        // them, and the re-assert refuses instead of yanking.
        let reasserted = state.reassertOpeningReturn()
        #expect(!reasserted)
    }

    @Test func aTookOverFollowerStillGetsTheInstantRePin() throws {
        var state = try openedAtBottom()
        // The reader takes over and reads mid-history...
        state.phaseChanged(.tracking, viewport: viewport(offset: 900, height: 2600))
        state.phaseChanged(.idle, viewport: viewport(offset: 900, height: 2600))
        state.settleUserScroll()
        #expect(state.readerTookOver && state.mode == .reading)
        // ...then scrolls back to the bottom and rests there: following again.
        state.phaseChanged(.tracking, viewport: viewport(offset: 1920, height: 2600))
        state.phaseChanged(.idle, viewport: viewport(offset: 1920, height: 2600))
        state.settleUserScroll()
        #expect(state.readerTookOver && state.mode == .following)
        // A window change (a prepend landing above) displaces the resting
        // follower. The re-assert is theirs too now: the instant return lands
        // exactly where they rest, so it moves nothing they can see — the
        // batch-2 prepend re-pin no longer skips taken-over followers.
        state.geometryChanged(viewport(offset: 1920, height: 3000))
        let reasserted = state.reassertOpeningReturn()
        #expect(reasserted)
        let command = try nextCommand(&state)
        #expect(command.instant)
        state.geometryChanged(viewport(offset: 2320, height: 3000))
        visibility(&state, end: true)
        let completed = state.complete(command)
        #expect(completed && state.mode == .following)
        // The instant flag was consumed with that return: the next explicit
        // return is a normal animated one. A lingering `openingReturnIsPending`
        // would make the bottom pill land without its spring, and this turns
        // red.
        state.geometryChanged(viewport(offset: 1920, height: 3000))
        state.requestBottom()
        let next = try nextCommand(&state)
        #expect(!next.instant)
    }

    @Test func aParkedHistoryReaderStillRefusesTheReAssert() throws {
        var state = try openedAtBottom()
        // Taken over and resting away from the bottom: the one state the
        // re-assert must keep its hands off — a return here would yank them
        // off what they stopped to read.
        state.phaseChanged(.tracking, viewport: viewport(offset: 900, height: 2600))
        state.phaseChanged(.idle, viewport: viewport(offset: 900, height: 2600))
        state.settleUserScroll()
        #expect(state.readerTookOver && state.mode == .reading)
        let reasserted = state.reassertOpeningReturn()
        #expect(!reasserted)
    }

    @Test func anExplicitHistoryRequestEndsTheOpeningClaim() throws {
        var state = try openedAtBottom()
        state.browseHistory(byReader: true)
        #expect(state.readerTookOver)
        let reasserted = state.reassertOpeningReturn()
        #expect(!reasserted)
    }

    @Test func aPresentedInteractionDoesNotEndTheOpeningClaim() throws {
        var state = try openedAtBottom()
        state.setInteractionPresented(true)
        #expect(!state.readerTookOver)
        let reasserted = state.reassertOpeningReturn()
        #expect(reasserted)
    }

    @Test func aSuspendedDrawerRefusesTheReAssertUntilItSettles() throws {
        var state = try openedAtBottom()
        state.setNavigationSuspended(true)
        let suspended = state.reassertOpeningReturn()
        #expect(!suspended)
        state.setNavigationSuspended(false)
        let settled = state.reassertOpeningReturn()
        #expect(settled)
    }

    @Test func anUnopenedPageRefusesTheReAssert() {
        var state = TimelineScrollState()
        state.geometryChanged(viewport(offset: 1320))
        let reasserted = state.reassertOpeningReturn()
        #expect(!reasserted)
    }
}

/// The presentation-side signal behind the re-assert: a window that drops a
/// row it had presented is a replacement (the trim/latest-page surgery, a
/// recovery snapshot); an append keeps every presented row and must not move
/// the reader.
@Suite @MainActor struct OpeningWindowRevisionTests {
    private func items(_ orders: ClosedRange<Int>) throws -> [V2TimelineItem] {
        try orders.map { try decode(itemObject(id: "reply-\($0)", order: $0), as: V2TimelineItem.self) }
    }

    @Test func aReplacedWindowBumpsTheRevisionButAnAppendDoesNot() throws {
        let timeline = SessionTimelinePresentation()
        // The opening's own first presentation has no claim to re-assert: the
        // opening return is already armed by `open()`.
        timeline.presentOpening(try items(1...3), pendingMessages: [])
        #expect(timeline.rows.map(\.id) == ["reply-1", "reply-2", "reply-3"])
        #expect(timeline.windowRevision == 0)
        // The post-surgery window (the newest page) drops rows that were on
        // screen: the reader must be re-anchored to the new bottom.
        timeline.presentOpening(try items(2...4), pendingMessages: [])
        #expect(timeline.windowRevision == 1)
        // A live append keeps every presented row: nothing to re-assert.
        timeline.stage(try items(2...5), animate: false)
        timeline.flush(now: 1)
        #expect(timeline.rows.map(\.id) == ["reply-2", "reply-3", "reply-4", "reply-5"])
        #expect(timeline.windowRevision == 1)
        // A recovery/snapshot replacement is the same shape as the surgery.
        timeline.stage(try items(51...53), animate: false)
        timeline.flush(now: 2)
        #expect(timeline.rows.map(\.id) == ["reply-51", "reply-52", "reply-53"])
        #expect(timeline.windowRevision == 2)
    }

    @Test func rePresentingTheSameWindowDoesNotBumpTheRevision() throws {
        let timeline = SessionTimelinePresentation()
        timeline.presentOpening(try items(1...3), pendingMessages: [])
        timeline.presentOpening(try items(1...3), pendingMessages: [])
        #expect(timeline.windowRevision == 0)
    }
}

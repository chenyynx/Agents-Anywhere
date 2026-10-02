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
        return try #require(state.begin(request))
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
        #expect(state.complete(opening))
        #expect(state.mode == .following && state.pendingBottomRequest == nil)
        // Sending, accepted responses and the bottom pill all reuse the
        // animated return.
        state.requestBottom()
        let later = try nextCommand(&state)
        #expect(!later.instant)
        #expect(state.complete(later))
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
        #expect(state.complete(opening) && state.mode == .following && state.pendingBottomRequest == nil)
    }

    @Test func readingAndExplicitReturnsKeepFollowingSemanticsAfterTheInstantOpening() throws {
        var state = TimelineScrollState()
        state.geometryChanged(viewport())
        visibility(&state, end: false)
        state.open()
        let opening = try nextCommand(&state)
        #expect(opening.instant)
        #expect(state.complete(opening) && state.mode == .following)
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
        #expect(state.complete(returned) && state.mode == .following && !state.showsBottomButton())
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

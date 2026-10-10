import Foundation
import Synchronization
import Testing
@testable import ClientCore

/// session-open-coverage P2: the automatic post-paint backfill. The loop
/// walks the same `loadOlder` path the reader's swipes use and stops at the
/// session start, at the window budget, on error, or when a round cannot
/// advance the window; the reader's scroll/input state pauses it between
/// pages. Every coverage read carries `exclude=agent_children`.
@Suite @MainActor struct SessionBackfillTests {
    /// A snapshot whose window holds `orders`, with `hasMore` set.
    private func snapshotResponse(orders: ClosedRange<Int>, hasMore: Bool) throws -> Data {
        var response = try fixtureObject("snapshot")
        var timeline = response["timeline"] as! [String: Any]
        timeline["items"] = try orders.map { try itemObject(id: "item-\($0)", order: $0) }
        timeline["hasMore"] = hasMore
        response["timeline"] = timeline
        return try JSONSerialization.data(withJSONObject: response)
    }

    /// A history page: the 100 rows below `before`, down to `floor`; more
    /// remains exactly while the page did not reach the floor.
    private func historyResponse(before: Int, floor: Int = 1) throws -> Data {
        let start = max(floor, before - 100)
        let items = try (start..<before).map { try itemObject(id: "item-\($0)", order: $0) }
        return try JSONSerialization.data(withJSONObject: ["sessionId": "session", "items": items,
            "nextSeq": 1000, "hasMore": start > floor])
    }

    private func isTimeline(_ call: TestHTTPTransport.Call) -> Bool { call.path.hasSuffix("timeline") }

    private func ordered(_ call: TestHTTPTransport.Call) -> Int {
        Int(call.query.first { $0.name == "beforeOrderSeq" }?.value ?? "") ?? 201
    }

    /// A more patient sibling of `eventually` for the backfill's multi-hop
    /// work (task start, quiet gate, page, merge, emit). The suite runs in
    /// parallel with every other suite, and the shared one-second budget has
    /// produced scheduler-starvation flakes.
    private func waitForCoverage(_ predicate: () -> Bool) async throws {
        for _ in 0..<5000 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        Issue.record("Coverage condition never became true")
    }

    @Test func backfillWalksToTheSessionStartThroughTheCoverageReads() async throws {
        let http = TestHTTPTransport()
        http.respond = { call in
            if call.path.hasSuffix("snapshot") {
                return try self.snapshotResponse(orders: 201...300, hasMore: true)
            }
            if self.isTimeline(call) {
                return try self.historyResponse(before: self.ordered(call))
            }
            return try http.defaultResponse(call)
        }
        let repo = repository(transport: http)
        defer { repo.reset() }
        _ = try await repo.open(sessionId: "session")
        #expect(http.count("timeline") == 0, "Opening must not page history by itself")

        repo.beginHistoryBackfill(sessionId: "session")
        try await waitForCoverage {
            let data = repo.cached(sessionId: "session")
            return data?.hasOlderItems == false && data?.items.count == 300
        }
        let data = try #require(repo.cached(sessionId: "session"))
        #expect(data.items.map(\.orderSeq) == Array(1...300))
        #expect(http.count("timeline") == 2)
        // Contract #1: the snapshot and every history page ask the server to
        // exclude SubAgent child rows; the decode path is unchanged.
        #expect(http.calls.first { $0.path.hasSuffix("snapshot") }?.query
            .contains(URLQueryItem(name: "exclude", value: "agent_children")) == true)
        #expect(http.calls.filter(isTimeline).allSatisfy { call in
            call.query.contains(URLQueryItem(name: "exclude", value: "agent_children"))
                && call.query.contains(URLQueryItem(name: "mode", value: "history"))
        })
    }

    @Test func anEmptyPageWithMoreBehindIsContinuedPast() async throws {
        let http = TestHTTPTransport()
        let pages = Mutex(0)
        http.respond = { call in
            if call.path.hasSuffix("snapshot") {
                return try self.snapshotResponse(orders: 201...300, hasMore: true)
            }
            if self.isTimeline(call) {
                let index = pages.withLock { $0 += 1; return $0 }
                if index == 1 {
                    // The server scanned a span of child rows only: nothing to
                    // return, but the filtered set continues behind it.
                    return try JSONSerialization.data(withJSONObject: ["sessionId": "session", "items": [Any](),
                        "nextSeq": 1000, "hasMore": true])
                }
                return try JSONSerialization.data(withJSONObject: ["sessionId": "session",
                    "items": try (101...200).map { try itemObject(id: "item-\($0)", order: $0) },
                    "nextSeq": 1000, "hasMore": false])
            }
            return try http.defaultResponse(call)
        }
        let repo = repository(transport: http)
        defer { repo.reset() }
        _ = try await repo.open(sessionId: "session")

        repo.beginHistoryBackfill(sessionId: "session")
        try await waitForCoverage { repo.cached(sessionId: "session")?.hasOlderItems == false }
        let data = try #require(repo.cached(sessionId: "session"))
        #expect(data.items.map(\.orderSeq) == Array(101...300), "The empty page must not end the backfill")
        #expect(http.count("timeline") == 2)
    }

    @Test func theRowBudgetStopsTheBackfill() async throws {
        let http = TestHTTPTransport()
        http.respond = { call in
            if call.path.hasSuffix("snapshot") {
                return try self.snapshotResponse(orders: 251...350, hasMore: true)
            }
            if self.isTimeline(call) {
                return try self.historyResponse(before: self.ordered(call))
            }
            return try http.defaultResponse(call)
        }
        let repo = repository(transport: http, policy: V2SessionCachePolicy(maximumTimelineItems: 250))
        defer { repo.reset() }
        _ = try await repo.open(sessionId: "session")

        repo.beginHistoryBackfill(sessionId: "session")
        try await waitForCoverage { (repo.cached(sessionId: "session")?.items.count ?? 0) >= 250 }
        // Give a spinning loop the chance to prove it stops: no further pages.
        try await Task.sleep(for: .milliseconds(30))
        let data = try #require(repo.cached(sessionId: "session"))
        #expect(data.items.count == 250)
        #expect(http.count("timeline") == 2, "The page that overflowed the cap is the last one fetched")
        #expect(data.hasOlderItems, "The session still has older rows; the budget is what stopped the fill")
    }

    @Test func theByteBudgetTrimsTheWindowAndStopsTheBackfill() async throws {
        let unit: V2TimelineItem = try decode(itemObject(id: "unit", order: 1, text: String(repeating: "x", count: 4000)))
        let perItem = V2SessionProjection.approximateWireBytes(unit)
        #expect(perItem > 4000)
        let budget = perItem * 3 + perItem / 2

        let http = TestHTTPTransport()
        http.respond = { call in
            if call.path.hasSuffix("snapshot") {
                var response = try fixtureObject("snapshot")
                var timeline = response["timeline"] as! [String: Any]
                timeline["items"] = try (101...102).map { try itemObject(id: "item-\($0)", order: $0, text: String(repeating: "x", count: 4000)) }
                timeline["hasMore"] = true
                response["timeline"] = timeline
                return try JSONSerialization.data(withJSONObject: response)
            }
            if self.isTimeline(call) {
                return try JSONSerialization.data(withJSONObject: ["sessionId": "session",
                    "items": try (99...100).map { try itemObject(id: "item-\($0)", order: $0, text: String(repeating: "x", count: 4000)) },
                    "nextSeq": 1000, "hasMore": true])
            }
            return try http.defaultResponse(call)
        }
        let repo = repository(transport: http, policy: V2SessionCachePolicy(maximumTimelineBytes: budget))
        defer { repo.reset() }
        _ = try await repo.open(sessionId: "session")

        repo.beginHistoryBackfill(sessionId: "session")
        try await waitForCoverage { repo.cached(sessionId: "session")?.items.count == 3 }
        try await Task.sleep(for: .milliseconds(30))
        let data = try #require(repo.cached(sessionId: "session"))
        // History merges keep the oldest side under the byte gate: the three
        // oldest rows fit, the fourth is trimmed away, and the window is at
        // capacity — the loop stops instead of fetching pages it would drop.
        #expect(data.items.map(\.orderSeq) == [99, 100, 101])
        #expect(data.hasNewerItems, "The trimmed newest rows are offered forward, as any history overflow")
        #expect(data.hasOlderItems)
        #expect(http.count("timeline") == 1)
    }

    @Test func aFailedPageStopsTheFillUntilTheNextOpen() async throws {
        let http = TestHTTPTransport()
        let failing = Mutex(true)
        http.respond = { call in
            if call.path.hasSuffix("snapshot") {
                return try self.snapshotResponse(orders: 201...300, hasMore: true)
            }
            if self.isTimeline(call) {
                if failing.withLock({ $0 }) { throw URLError(.networkConnectionLost) }
                return try self.historyResponse(before: self.ordered(call))
            }
            return try http.defaultResponse(call)
        }
        let repo = repository(transport: http)
        defer { repo.reset() }
        _ = try await repo.open(sessionId: "session")

        repo.beginHistoryBackfill(sessionId: "session")
        try await waitForCoverage { http.count("timeline") == 1 }
        try await Task.sleep(for: .milliseconds(30))
        #expect(http.count("timeline") == 1, "A failed page stops the loop instead of retrying")
        #expect(repo.cached(sessionId: "session")?.hasOlderItems == true)

        // The next open resumes from wherever it stopped.
        failing.withLock { $0 = false }
        _ = try await repo.open(sessionId: "session")
        repo.beginHistoryBackfill(sessionId: "session")
        try await waitForCoverage { repo.cached(sessionId: "session")?.hasOlderItems == false }
        #expect(repo.cached(sessionId: "session")?.items.count == 300)
    }

    @Test func scrollingPausesTheBackfillAndQuietResumesIt() async throws {
        let http = TestHTTPTransport()
        http.respond = { call in
            if call.path.hasSuffix("snapshot") {
                return try self.snapshotResponse(orders: 201...300, hasMore: true)
            }
            if self.isTimeline(call) {
                return try self.historyResponse(before: self.ordered(call))
            }
            return try http.defaultResponse(call)
        }
        let repo = repository(transport: http)
        defer { repo.reset() }
        _ = try await repo.open(sessionId: "session")

        repo.setBackfillReaderState(scrolling: true, parkedInHistory: false, sessionId: "session")
        repo.beginHistoryBackfill(sessionId: "session")
        try await Task.sleep(for: .milliseconds(60))
        #expect(http.count("timeline") == 0, "Pages wait while the reader is scrolling")
        #expect(repo.cached(sessionId: "session")?.hasOlderItems == true)

        repo.setBackfillReaderState(scrolling: false, parkedInHistory: false, sessionId: "session")
        try await waitForCoverage { repo.cached(sessionId: "session")?.hasOlderItems == false }
        #expect(http.count("timeline") >= 1)
    }

    @Test func aReaderParkedMidHistoryHoldsTheBackfillUntilTheyReturn() async throws {
        let http = TestHTTPTransport()
        http.respond = { call in
            if call.path.hasSuffix("snapshot") {
                return try self.snapshotResponse(orders: 201...300, hasMore: true)
            }
            if self.isTimeline(call) {
                return try self.historyResponse(before: self.ordered(call))
            }
            return try http.defaultResponse(call)
        }
        let repo = repository(transport: http)
        defer { repo.reset() }
        _ = try await repo.open(sessionId: "session")

        // B11: the reader took over and is resting mid-history. A merge now
        // would prepend above them with nothing to anchor it, so the fill
        // holds outright — not merely defers the apply.
        repo.setBackfillReaderState(scrolling: false, parkedInHistory: true, sessionId: "session")
        repo.beginHistoryBackfill(sessionId: "session")
        try await Task.sleep(for: .milliseconds(60))
        #expect(http.count("timeline") == 0, "Pages wait while the reader is parked mid-history")
        #expect(repo.cached(sessionId: "session")?.hasOlderItems == true)

        // Back at the bottom (following) — or at the top's older-pull region,
        // which the view folds into the same clear — the fill resumes.
        repo.setBackfillReaderState(scrolling: false, parkedInHistory: false, sessionId: "session")
        try await waitForCoverage { repo.cached(sessionId: "session")?.hasOlderItems == false }
        #expect(http.count("timeline") >= 1)
    }

    @Test func anInFlightPageWaitsOutTheReaderWhoTookItBack() async throws {
        let http = TestHTTPTransport()
        let gate = TestGate()
        http.respond = { call in
            if call.path.hasSuffix("snapshot") {
                return try self.snapshotResponse(orders: 201...300, hasMore: true)
            }
            if self.isTimeline(call) {
                await gate.wait()
                return try self.historyResponse(before: self.ordered(call))
            }
            return try http.defaultResponse(call)
        }
        let repo = repository(transport: http)
        defer { repo.reset() }
        _ = try await repo.open(sessionId: "session")

        repo.beginHistoryBackfill(sessionId: "session")
        try await waitForCoverage { http.count("timeline") == 1 } // the page is in flight
        // The reader takes the page back mid-fetch and parks mid-history. The
        // quiet gate was sampled before the request went out; merging the
        // response now would prepend rows under them with nothing to anchor
        // the offset (the 2026-10-10 field report). The page must wait.
        repo.setBackfillReaderState(scrolling: false, parkedInHistory: true, sessionId: "session")
        gate.release()
        try await Task.sleep(for: .milliseconds(80))
        #expect(repo.cached(sessionId: "session")?.items.count == 100, "The fetched page waits for the reader")
        #expect(repo.cached(sessionId: "session")?.hasOlderItems == true)

        // Back at the bottom the held page lands and the loop resumes from
        // there: the wait is a pause, not a stall (nothing is dropped — a
        // dropped page would read as a stalled round and two would end the
        // fill).
        repo.setBackfillReaderState(scrolling: false, parkedInHistory: false, sessionId: "session")
        try await waitForCoverage { repo.cached(sessionId: "session")?.hasOlderItems == false }
        #expect(repo.cached(sessionId: "session")?.items.count == 300)
        #expect(http.count("timeline") == 2, "The held page is applied, never re-fetched or dropped")
    }

    @Test func aManualRequestJoiningAWaitingPageLandsForTheReader() async throws {
        let http = TestHTTPTransport()
        let gate = TestGate()
        http.respond = { call in
            if call.path.hasSuffix("snapshot") {
                return try self.snapshotResponse(orders: 201...300, hasMore: true)
            }
            if self.isTimeline(call) {
                await gate.wait()
                return try self.historyResponse(before: self.ordered(call))
            }
            return try http.defaultResponse(call)
        }
        let repo = repository(transport: http)
        defer { repo.reset() }
        _ = try await repo.open(sessionId: "session")

        repo.beginHistoryBackfill(sessionId: "session")
        try await waitForCoverage { http.count("timeline") == 1 }
        // The reader parks while the backfill's page is in flight...
        repo.setBackfillReaderState(scrolling: false, parkedInHistory: true, sessionId: "session")
        gate.release()
        // ...and then asks for a page themselves. The manual request joins the
        // same in-flight task and takes it over: the page must land for the
        // reader — their own history anchor absorbs the prepend — instead of
        // waiting out the hold that exists to protect them from unanchored
        // merges.
        let manual = Task { _ = try await repo.loadOlder(sessionId: "session") }
        try await waitForCoverage { (repo.cached(sessionId: "session")?.items.count ?? 0) >= 200 }
        _ = try await manual.value
        #expect(repo.cached(sessionId: "session")?.items.count == 200)
        #expect(http.count("timeline") == 1, "The manual request joins the in-flight page, never duplicating it")
    }

    @Test func reopeningTheSessionReArmsAnInterruptedBackfill() async throws {
        let http = TestHTTPTransport()
        let gate = TestGate()
        http.respond = { call in
            if call.path.hasSuffix("snapshot") {
                return try self.snapshotResponse(orders: 201...300, hasMore: true)
            }
            if self.isTimeline(call) {
                await gate.wait()
                return try self.historyResponse(before: self.ordered(call))
            }
            return try http.defaultResponse(call)
        }
        let repo = repository(transport: http)
        defer { repo.reset() }
        _ = try await repo.open(sessionId: "session")
        repo.beginHistoryBackfill(sessionId: "session")
        try await waitForCoverage { http.count("timeline") == 1 } // the first page is in flight

        // The re-open's version bump cancels the in-flight read — and with it
        // the loop. F6: the visit must re-arm the fill, not abandon it.
        _ = try await repo.open(sessionId: "session")
        gate.release()
        try await waitForCoverage { repo.cached(sessionId: "session")?.hasOlderItems == false }
        #expect(repo.cached(sessionId: "session")?.items.count == 300)
        #expect(http.count("timeline") >= 3, "The interrupted page is re-issued by the re-armed loop")
    }

    /// The view's mapping from the scroll state machine onto its two reader
    /// signals, pinned at its source (red team F1): parked mid-history holds;
    /// the bottom (following) and the top's older-pull region resume.
    @Test func theBackfillHoldsOnlyForAParkedReader() throws {
        func viewport(offset: CGFloat, height: CGFloat = 2000, container: CGFloat = 800) -> TimelineViewport {
            TimelineViewport(contentHeight: height, containerHeight: container, topInset: 80, bottomInset: 120, offsetY: offset)
        }
        var state = TimelineScrollState()
        state.geometryChanged(viewport(offset: 1320))
        state.tailVisibilityChanged(.near, visible: true)
        state.tailVisibilityChanged(.end, visible: true)
        state.open()
        let request = try #require(state.pendingBottomRequest)
        let began = state.begin(request)
        let command = try #require(began)
        _ = state.complete(command)
        // A fresh opening is not parked: the fill runs while the claim holds.
        #expect(state.mode == .following)
        #expect(!state.backfillReaderIsParked(atOlderPrompt: false))

        // The reader takes over and stops away from the bottom.
        state.phaseChanged(.tracking, viewport: viewport(offset: 500))
        state.phaseChanged(.idle, viewport: viewport(offset: 500))
        state.settleUserScroll()
        #expect(state.mode == .reading)
        #expect(state.backfillReaderIsParked(atOlderPrompt: false))
        // At the top's older-pull region the merge is what they are there for.
        #expect(!state.backfillReaderIsParked(atOlderPrompt: true))

        // Returning to the bottom settles into following: not parked.
        state.phaseChanged(.tracking, viewport: viewport(offset: 500))
        state.phaseChanged(.idle, viewport: viewport(offset: 1320))
        state.settleUserScroll()
        #expect(state.mode == .following)
        #expect(!state.backfillReaderIsParked(atOlderPrompt: false))
    }

    @Test func theComposerHoldsTheBackfillWhileTyping() async throws {
        let http = TestHTTPTransport()
        http.respond = { call in
            if call.path.hasSuffix("snapshot") {
                return try self.snapshotResponse(orders: 201...300, hasMore: true)
            }
            if self.isTimeline(call) {
                return try self.historyResponse(before: self.ordered(call))
            }
            return try http.defaultResponse(call)
        }
        let repo = repository(transport: http)
        defer { repo.reset() }
        _ = try await repo.open(sessionId: "session")

        repo.session(id: "session").composer.isFocused = true
        repo.beginHistoryBackfill(sessionId: "session")
        try await Task.sleep(for: .milliseconds(60))
        #expect(http.count("timeline") == 0, "Pages wait while the keyboard is up")

        repo.session(id: "session").composer.isFocused = false
        try await waitForCoverage { repo.cached(sessionId: "session")?.hasOlderItems == false }
    }

    @Test func aPrependReArmsTheViewportReAssertLikeADrop() throws {
        func items(_ orders: ClosedRange<Int>) throws -> [V2TimelineItem] {
            try orders.map { try decode(itemObject(id: "reply-\($0)", order: $0), as: V2TimelineItem.self) }
        }
        let timeline = SessionTimelinePresentation()
        timeline.presentOpening(try items(2...3), pendingMessages: [])
        #expect(timeline.windowRevision == 0)
        // History rows prepended above everything the reader has seen move the
        // window under them; the re-assert re-pins it like a drop would.
        timeline.stage(try items(0...3), animate: false)
        timeline.flush(now: 1)
        #expect(timeline.rows.map(\.id) == ["reply-0", "reply-1", "reply-2", "reply-3"])
        #expect(timeline.windowRevision == 1)
        // A pure append still does not bump.
        timeline.stage(try items(0...4), animate: false)
        timeline.flush(now: 2)
        #expect(timeline.windowRevision == 1)
    }

    @Test func theApiLayerSendsTheContractQueryItems() async throws {
        let http = TestHTTPTransport()
        let api = V2SessionAPI(transport: http)
        _ = try await api.snapshot(sessionId: "session", limit: 100, exclude: .agentChildren)
        _ = try await api.latestTimeline(sessionId: "session", limit: 100, exclude: .agentChildren)
        _ = try await api.timelineHistory(sessionId: "session", beforeOrderSeq: 80, limit: 25, exclude: .agentChildren)
        _ = try await api.timelineChildren(sessionId: "session", parentId: "card", beforeOrderSeq: nil, limit: 100)
        _ = try await api.timelineChildren(sessionId: "session", parentId: "card", beforeOrderSeq: 42, limit: 100)
        func query(_ index: Int) -> [URLQueryItem] { http.calls[index].query }
        #expect(query(0) == [URLQueryItem(name: "limit", value: "100"),
                             URLQueryItem(name: "exclude", value: "agent_children")])
        #expect(query(1) == [URLQueryItem(name: "mode", value: "latest"), URLQueryItem(name: "limit", value: "100"),
                             URLQueryItem(name: "exclude", value: "agent_children")])
        #expect(query(2) == [URLQueryItem(name: "mode", value: "history"), URLQueryItem(name: "limit", value: "25"),
                             URLQueryItem(name: "beforeOrderSeq", value: "80"),
                             URLQueryItem(name: "exclude", value: "agent_children")])
        #expect(query(3) == [URLQueryItem(name: "mode", value: "children"), URLQueryItem(name: "limit", value: "100"),
                             URLQueryItem(name: "parentId", value: "card")])
        #expect(query(4) == [URLQueryItem(name: "mode", value: "children"), URLQueryItem(name: "limit", value: "100"),
                             URLQueryItem(name: "beforeOrderSeq", value: "42"),
                             URLQueryItem(name: "parentId", value: "card")])
    }

    @Test func omittingExcludeKeepsTheOldRequestByteForByte() async throws {
        let http = TestHTTPTransport()
        let api = V2SessionAPI(transport: http)
        _ = try await api.snapshot(sessionId: "session", limit: 100)
        _ = try await api.timelineHistory(sessionId: "session", beforeOrderSeq: 80, limit: 25)
        #expect(http.calls[0].query == [URLQueryItem(name: "limit", value: "100")])
        #expect(http.calls[1].query == [URLQueryItem(name: "mode", value: "history"),
                                        URLQueryItem(name: "limit", value: "25"),
                                        URLQueryItem(name: "beforeOrderSeq", value: "80")])
    }
}

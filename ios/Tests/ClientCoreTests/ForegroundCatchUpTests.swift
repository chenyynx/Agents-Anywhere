import Foundation
import Testing
@testable import ClientCore

/// Ordered record shared by the fake realtime API and the fake transports, so
/// tests can assert the order in which recovery reads and the socket ticket
/// are issued.
@MainActor
private final class ForegroundLog {
    private(set) var entries: [String] = []
    func append(_ value: String) { entries.append(value) }
    func clear() { entries.removeAll() }
}

/// Real-time stub that can hold the ws-ticket request open, keeping the socket
/// in `.connecting` while the foreground catch-up runs to completion.
@MainActor
private final class TicketGatedRealtime: V2RealtimeAPIProtocol {
    let inner = TestRealtimeAPI()
    let log: ForegroundLog
    var ticketGate: TestGate?

    init(log: ForegroundLog) { self.log = log }

    var tickets: Int { inner.tickets }
    var recoveries: [String] { inner.recoveries }

    func ticket(clientId: String, scope: V2RealtimeScope) async throws -> V2WebSocketTicket {
        log.append("ticket")
        if let gate = ticketGate { await gate.wait() }
        return try await inner.ticket(clientId: clientId, scope: scope)
    }

    func recover(sessionId: V2SessionID, after cursor: String) async throws -> V2EventRecoveryResponse {
        log.append("recover")
        return try await inner.recover(sessionId: sessionId, after: cursor)
    }

    func sessionEvents(sessionId: V2SessionID, ticket: String) throws -> AsyncThrowingStream<V2SessionEvent, Error> {
        try inner.sessionEvents(sessionId: sessionId, ticket: ticket)
    }

    func dashboardSnapshots(ticket: String) throws -> AsyncThrowingStream<V2DashboardSnapshot, Error> {
        try inner.dashboardSnapshots(ticket: ticket)
    }
}

@MainActor
private func catchUpRepository(
    transport: TestHTTPTransport,
    realtime: any V2RealtimeAPIProtocol,
    readinessWindow: Duration = .seconds(1.5),
    sleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
) -> V2SessionRepository {
    let runtime = V2RuntimeAPI(transport: transport)
    return V2SessionRepository(
        scope: V2ClientScope(serverURL: URL(string: "https://example.test/api/v2")!, accountID: "account"),
        detail: V2SessionDetailService(
            sessionAPI: V2SessionAPI(transport: transport),
            runtimeAPI: runtime,
            realtimeAPI: realtime
        ),
        interactions: V2RuntimeInteractionService(runtimeAPI: runtime),
        sleep: sleep,
        connectionReadinessWindow: readinessWindow
    )
}

@Suite @MainActor struct ForegroundCatchUpTests {
    /// T1.3 ① — the incremental events read is issued before the socket ticket,
    /// and the recovery completes while the ticket is still blocked.
    @Test func foregroundCatchUpIssuesRecoveryBeforeTheSocketTicket() async throws {
        let http = TestHTTPTransport()
        let log = ForegroundLog()
        let realtime = TicketGatedRealtime(log: log)
        let repo = catchUpRepository(transport: http, realtime: realtime, readinessWindow: .seconds(5))
        defer { repo.reset() }
        repo.updateConnectivity(V2NetworkStatus(availability: .online))
        let model = repo.session(id: "session")
        let connection = Task { await model.connect() }
        defer { connection.cancel() }
        try await eventually { model.connection == .connected }

        log.clear()
        let gate = TestGate()
        realtime.ticketGate = gate
        repo.suspend()
        repo.resume()

        try await eventually { log.entries.contains("recover") && log.entries.contains("ticket") }
        let recovery = try #require(log.entries.firstIndex(of: "recover"))
        let ticket = try #require(log.entries.firstIndex(of: "ticket"))
        #expect(recovery < ticket, "The incremental events read must not queue behind the socket ticket")

        try await eventually { model.runtime.isFresh }
        #expect(model.connection != .connected, "Catch-up must not wait for the socket handshake")

        gate.release()
        try await eventually { model.connection == .connected }
    }

    /// T1.3 ④ / A2 — the REST catch-up publishes authoritative facts before
    /// the socket confirms, and cached content alone never opens the gate.
    @Test func catchUpPublishesAuthoritativeFactsBeforeTheSocketConfirms() async throws {
        let http = TestHTTPTransport()
        let log = ForegroundLog()
        let realtime = TicketGatedRealtime(log: log)
        let repo = catchUpRepository(transport: http, realtime: realtime)
        defer { repo.reset() }
        repo.updateConnectivity(V2NetworkStatus(availability: .online))
        let model = repo.session(id: "session")
        let connection = Task { await model.connect() }
        defer { connection.cancel() }
        try await eventually { model.connection == .connected }
        #expect(model.runtime.isFresh && model.canSend)

        let gate = TestGate()
        realtime.ticketGate = gate
        repo.suspend()
        #expect(model.connection == .inactive)
        // Cached content stays readable, but it is not authoritative: the gate
        // must stay closed until live facts have been re-read.
        #expect(model.timeline.count == 1)
        #expect(!model.runtime.isFresh && !model.canSend)

        repo.resume()
        try await eventually { model.runtime.isFresh }
        #expect(model.connection == .connecting)
        #expect(model.canSend, "A completed REST catch-up makes authoritative facts usable without the socket")
        #expect(model.timeline.count == 1, "Cached content stays readable throughout")

        gate.release()
        try await eventually { model.connection == .connected }
        #expect(model.runtime.isFresh && model.canSend)
    }

    /// T1.3 ② — a path that has not reported yet holds the first attempt until
    /// it goes online, then the attempt starts with no extra delay.
    @Test func firstAttemptWaitsForReadinessAndStartsAsSoonAsThePathIsOnline() async throws {
        let http = TestHTTPTransport()
        let realtime = TestRealtimeAPI()
        let repo = catchUpRepository(
            transport: http,
            realtime: realtime,
            readinessWindow: .seconds(5),
            sleep: { _ in try await Task.sleep(for: .milliseconds(20)) }
        )
        defer { repo.reset() }
        #expect(repo.network.availability == .unknown)
        let model = repo.session(id: "session")
        let connection = Task { await model.connect() }
        defer { connection.cancel() }
        // The window is 50 probes of the injected 20ms sleep (~1s), so the
        // assertion below sits far inside it on any machine.
        try await Task.sleep(for: .milliseconds(30))
        #expect(realtime.tickets == 0, "A not-ready path must not open a socket")
        #expect(http.calls.isEmpty, "A not-ready path must not issue requests")

        repo.updateConnectivity(V2NetworkStatus(availability: .online))
        try await eventually { realtime.tickets == 1 }
        try await eventually { model.connection == .connected }
    }

    /// T1.3 ② — the readiness wait is bounded: a missing monitor report only
    /// delays the attempt, it can never block it forever.
    @Test func firstAttemptProceedsAfterTheBoundedReadinessWindow() async throws {
        let http = TestHTTPTransport()
        let realtime = TestRealtimeAPI()
        let repo = catchUpRepository(
            transport: http,
            realtime: realtime,
            readinessWindow: .milliseconds(100),
            sleep: { _ in try await Task.sleep(for: .milliseconds(1)) }
        )
        defer { repo.reset() }
        let model = repo.session(id: "session")
        let connection = Task { await model.connect() }
        defer { connection.cancel() }
        try await eventually { realtime.tickets == 1 }
        try await eventually { model.connection == .connected }
    }

    /// T1.3 ② red line — a positively offline path never issues requests, and
    /// the connection recovers as soon as the path returns.
    @Test func offlinePathNeverIssuesRequestsAndRecoversOnReconnect() async throws {
        let http = TestHTTPTransport()
        let realtime = TestRealtimeAPI()
        let repo = catchUpRepository(transport: http, realtime: realtime, readinessWindow: .milliseconds(50))
        defer { repo.reset() }
        repo.updateConnectivity(V2NetworkStatus(availability: .offline))
        let model = repo.session(id: "session")
        #expect(model.connection == .offline)
        let connection = Task { await model.connect() }
        defer { connection.cancel() }
        try await Task.sleep(for: .milliseconds(20))
        #expect(realtime.tickets == 0)
        #expect(http.calls.isEmpty)

        repo.updateConnectivity(V2NetworkStatus(availability: .online))
        try await eventually { model.connection == .connected }
        #expect(http.count("snapshot") == 1)
    }

    /// T1.3 ③ — recovery replays are idempotent: duplicate and out-of-order
    /// events from both the catch-up round and the socket round merge once.
    @Test func repeatedAndOutOfOrderRecoveryEventsStayIdempotent() async throws {
        let http = TestHTTPTransport()
        let realtime = TestRealtimeAPI()
        let repo = catchUpRepository(transport: http, realtime: realtime)
        defer { repo.reset() }
        repo.updateConnectivity(V2NetworkStatus(availability: .online))
        let created = try event("timeline.item_created", seq: 12,
                                payload: ["item": itemObject(id: "recovered", order: 2, seq: 12)])
        let stale = try event("timeline.item_updated", seq: 9,
                              payload: ["item": itemObject(id: "item", order: 1, revision: 9, seq: 9)])
        realtime.onRecover = {
            V2EventRecoveryResponse(events: [created, created, stale], nextCursor: "seq:12",
                                    snapshotRequired: false, serverTime: "")
        }
        let model = repo.session(id: "session")
        let connection = Task { await model.connect() }
        defer { connection.cancel() }
        try await eventually { model.connection == .connected }
        #expect(model.timeline.count == 2)
        #expect(model.timeline.filter { $0.id == "recovered" }.count == 1)
        #expect(model.timeline.first { $0.id == "item" }?.value.revision == 1, "An event at or behind the cursor must not regress state")
        #expect(repo.cached(sessionId: "session")?.cursor == "seq:12")
        #expect(model.runtime.isFresh)
    }

    /// A1 — a round that `stop()` superseded applies nothing, surfaces no
    /// error, and a later caller runs its own recovery instead of inheriting it.
    @Test func supersededRecoveryAppliesNothingAndDoesNotSurfaceErrors() async throws {
        let http = TestHTTPTransport()
        let realtime = TestRealtimeAPI()
        let repo = catchUpRepository(transport: http, realtime: realtime)
        defer { repo.reset() }
        repo.updateConnectivity(V2NetworkStatus(availability: .online))
        let model = repo.session(id: "session")
        let connection = Task { await model.connect() }
        defer { connection.cancel() }
        try await eventually { model.connection == .connected }

        let gate = TestGate()
        var gateNextRecovery = true
        let late = try event("timeline.item_created", seq: 62,
                             payload: ["item": itemObject(id: "late", order: 2, seq: 62)])
        realtime.onRecover = {
            if gateNextRecovery {
                gateNextRecovery = false
                await gate.wait()
                return V2EventRecoveryResponse(events: [late], nextCursor: "seq:62",
                                               snapshotRequired: false, serverTime: "")
            }
            return V2EventRecoveryResponse(events: [], nextCursor: "seq:10",
                                           snapshotRequired: false, serverTime: "")
        }
        realtime.yield(try event("session.refetch_required", seq: 11))
        try await eventually { realtime.recoveries.count == 2 }

        repo.suspend()
        repo.resume()
        gate.release()

        try await eventually { model.connection == .connected }
        #expect(model.timeline.count == 1)
        #expect(model.timeline.allSatisfy { $0.id != "late" }, "A superseded round must not apply its events")
        #expect(repo.cached(sessionId: "session")?.cursor == "seq:10")
        #expect(model.failure == nil)
        #expect(model.runtime.isFresh)
    }

    /// `requiringRoundAfter` — a round that started before the socket
    /// subscribed cannot stand in for the subscribe read. The subscribe path
    /// waits for the older in-flight round quietly, then runs a round of its
    /// own, so events the older read could not have seen are still applied.
    /// If the subscribe path simply joined the in-flight round instead, the
    /// third read below would never happen and `missed` would be lost.
    @Test func subscribeReplacesAnOlderInFlightRoundInsteadOfInheritingIt() async throws {
        let http = TestHTTPTransport()
        let realtime = TestRealtimeAPI()
        let repo = catchUpRepository(transport: http, realtime: realtime)
        defer { repo.reset() }
        repo.updateConnectivity(V2NetworkStatus(availability: .online))
        let model = repo.session(id: "session")
        let connection = Task { await model.connect() }
        defer { connection.cancel() }
        try await eventually { model.connection == .connected }
        #expect(realtime.recoveries.count == 1, "The initial subscribe owns exactly one round")

        // The catch-up round's read is held open while the socket subscribes.
        // It predates the subscribe, so it cannot have seen `missed`; only the
        // round the subscribe path launches afterwards returns it.
        let catchUpGate = TestGate()
        let freshGate = TestGate()
        var recoverCall = 0
        let missed = try event("timeline.item_created", seq: 12,
                               payload: ["item": itemObject(id: "missed", order: 2, seq: 12)])
        realtime.onRecover = {
            recoverCall += 1
            if recoverCall == 1 {
                await catchUpGate.wait()
                return V2EventRecoveryResponse(events: [], nextCursor: "seq:11",
                                               snapshotRequired: false, serverTime: "")
            }
            await freshGate.wait()
            return V2EventRecoveryResponse(events: [missed], nextCursor: "seq:12",
                                           snapshotRequired: false, serverTime: "")
        }
        repo.suspend()
        repo.resume()
        try await eventually { realtime.recoveries.count == 2 }
        #expect(model.connection == .connecting)
        // Let the socket's subscribe frame reach its recovery decision (it
        // awaits the held round) before that round is allowed to finish.
        try await eventually { realtime.streams.count == 2 }
        try await Task.sleep(for: .milliseconds(20))

        catchUpGate.release()
        try await eventually { realtime.recoveries.count == 3 }
        #expect(model.connection != .connected, "Subscribe stays unconfirmed until its own round finishes")
        #expect(model.timeline.allSatisfy { $0.id != "missed" }, "Only the fresh round may publish the missed event")

        freshGate.release()
        try await eventually { model.connection == .connected }
        #expect(model.timeline.contains { $0.id == "missed" })
        #expect(model.failure == nil)
    }

    /// D5 — the default cache window keeps the recent working set resident.
    @Test func cacheWindowKeepsTheRecentWorkingSetResident() {
        let repo = repository(transport: TestHTTPTransport())
        defer { repo.reset() }
        for index in 0..<12 { _ = repo.session(id: "session-\(index)") }
        #expect(repo.cachedSessionIDs.count == 12)
    }
}

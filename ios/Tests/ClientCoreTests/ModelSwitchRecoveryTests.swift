import Foundation
import Testing
@testable import ClientCore

/// Model switch = stop and switch, and the composer's recovery from it
/// (`.local-dev/model-switch-and-composer-recovery-tasks.md`, A1/A2/A3).
///
/// Every fixture here is built from the shared backend fixtures and driven
/// through the real repository paths, so the tests exercise the same ordering,
/// reconciliation and self-healing the app runs.
@Suite @MainActor struct ModelSwitchRecoveryTests {
    /// Models served by the session's catalog; the state starts on the first.
    private static let modelA = "sel_model_a"
    private static let modelB = "sel_model_b"

    private func stateJSON(status: String, model: String = ModelSwitchRecoveryTests.modelA) throws -> [String: Any] {
        var object = try fixtureObject("state")
        var state = object["state"] as! [String: Any]
        state["status"] = status
        state["selections"] = ["model": model, "effort": NSNull()]
        object["state"] = state
        return object
    }

    private func capabilityJSON(_ id: String, available: Bool) throws -> [String: Any] {
        [
            "allowed": true, "available": available, "capabilityId": id, "parameters": [:],
            "runtime": "claude", "runtimeId": "rti_work", "scope": "runtime", "sessionId": NSNull(),
            "supported": true, "unavailableReason": NSNull(), "version": "1",
        ]
    }

    /// The documented turn window: while the turn runs, send is unavailable
    /// and interrupt is available; idle is the mirror image. Catalog
    /// capabilities ride along so the options sheet can load and apply.
    private func capabilitiesJSON(sendAvailable: Bool, interruptAvailable: Bool) throws -> [String: Any] {
        [
            "capabilitySet": [
                "capabilities": [
                    try capabilityJSON("session.send_message", available: sendAvailable),
                    try capabilityJSON("session.interrupt", available: interruptAvailable),
                    try capabilityJSON("catalog.model", available: true),
                    try capabilityJSON("catalog.permission", available: true),
                ],
                "revision": 10,
            ],
            "connectorId": "device",
            "serverTime": "2026-09-05T12:00:00Z",
        ]
    }

    private func catalogJSON() -> [String: Any] {
        [
            "catalog": [
                "models": [
                    ["default": false, "description": NSNull(), "displayName": "Model A", "id": "model-a",
                     "metadata": [:], "reasoningItems": [], "selectionId": Self.modelA],
                    ["default": false, "description": NSNull(), "displayName": "Model B", "id": "model-b",
                     "metadata": [:], "reasoningItems": [], "selectionId": Self.modelB],
                ],
                "revision": 1, "runtime": "claude",
            ],
            "serverTime": "2026-09-05T12:00:00Z",
        ]
    }

    private func selectionResponseJSON(status: String, model: String) throws -> [String: Any] {
        var object = try stateJSON(status: status, model: model)
        return ["ok": true, "state": object["state"]!, "connectorResult": ["ok": true],
                "serverTime": "2026-09-05T12:00:00Z"]
    }

    /// A connected session whose live facts say `running` (send closed,
    /// interrupt open) until the interrupt endpoint flips it to idle.
    private final class RunningSession {
        var status = "running"
        var interruptAttempts = 0
        var interruptCalls = 0
        var interruptFailure: HTTPError?
        var selectionsHandled = false
        var liveStateReads = 0
        var failLiveState = false
        var gateLiveState: TestGate?
        var gated = false

        func json(_ value: [String: Any]) throws -> Data {
            try JSONSerialization.data(withJSONObject: value)
        }
    }

    private func makeSession(
        _ http: TestHTTPTransport,
        _ realtime: TestRealtimeAPI,
        _ running: RunningSession
    ) throws -> (V2SessionRepository, V2SessionModel, SessionChatModel) {
        http.respond = { [weak running] call in
            guard let running else { throw HTTPError.invalidResponse }
            if call.path.hasSuffix("/state") {
                running.liveStateReads += 1
                if running.failLiveState { throw URLError(.networkConnectionLost) }
                if running.gated { await running.gateLiveState?.wait() }
                return try running.json(try self.stateJSON(status: running.status))
            }
            if call.path.hasSuffix("capabilities") {
                let send = running.status == "idle"
                return try running.json(try self.capabilitiesJSON(sendAvailable: send, interruptAvailable: !send))
            }
            if call.path.hasSuffix("catalogs/model") { return try running.json(self.catalogJSON()) }
            if call.path.hasSuffix("selections") {
                // The server's selection response for a runtime whose result
                // carries no state: selections are real, status is synthesised.
                running.selectionsHandled = true
                return try running.json(try self.selectionResponseJSON(status: "idle", model: Self.modelB))
            }
            if call.path.hasSuffix("interrupt") {
                running.interruptAttempts += 1
                if let failure = running.interruptFailure { throw failure }
                running.interruptCalls += 1
                running.status = "idle"
                return try fixtureData("rpc")
            }
            return try http.defaultResponse(call)
        }
        let repo = repository(transport: http, realtime: realtime)
        let session = repo.session(id: "session")
        let chat = SessionChatModel(session: session, repository: repo,
            attachments: .init(attachmentAPI: V2AttachmentAPI(transport: http)))
        return (repo, session, chat)
    }

    private func connect(_ session: V2SessionModel) async throws -> Task<Void, Never> {
        let connection = Task { await session.connect() }
        try await eventually { session.runtime.isFresh }
        return connection
    }

    // MARK: - A1: the switch is selection → interrupt

    @Test func runningModelSwitchSelectsThenInterruptsAndLeavesTheComposerReady() async throws {
        let http = TestHTTPTransport(), realtime = TestRealtimeAPI()
        let running = RunningSession()
        let (repo, session, chat) = try makeSession(http, realtime, running)
        defer { repo.reset() }
        let connection = try await connect(session)
        defer { connection.cancel() }
        #expect(chat.isRunning && !session.canSend)

        await chat.loadSettings()
        #expect(chat.settings.selectModel("model-b"))
        #expect(await chat.applySettings())

        // pp 2026-10-05 order: the selection lands first, the interrupt
        // follows it; there is exactly one of each.
        let selectionsIndex = try #require(http.calls.firstIndex { $0.path.hasSuffix("selections") })
        let interruptIndex = try #require(http.calls.firstIndex { $0.path.hasSuffix("interrupt") })
        #expect(selectionsIndex < interruptIndex)
        #expect(http.count("interrupt") == 1)
        // The switch reports itself, once, and never mentions the interrupt.
        #expect(chat.switchFeedback?.title == "已切换到 Model B")
        #expect(chat.error == nil)
        // The turn is really over and the composer is usable without any
        // further user action.
        #expect(!chat.isRunning && !chat.isComposerStreaming && session.canSend)
        #expect(session.runtime.state?.status == .idle)
    }

    @Test func idleModelSwitchNeverInterrupts() async throws {
        let http = TestHTTPTransport(), realtime = TestRealtimeAPI()
        let running = RunningSession()
        running.status = "idle"
        let (repo, session, chat) = try makeSession(http, realtime, running)
        defer { repo.reset() }
        let connection = try await connect(session)
        defer { connection.cancel() }

        await chat.loadSettings()
        #expect(chat.settings.selectModel("model-b"))
        #expect(await chat.applySettings())
        #expect(http.count("interrupt") == 0)
        #expect(chat.switchFeedback?.title == "已切换到 Model B")
    }

    // MARK: - A2: interrupt acknowledgement and the local turn window

    @Test func noActiveTurnConflictIsTreatedAsSuccess() async throws {
        let http = TestHTTPTransport(), realtime = TestRealtimeAPI()
        let running = RunningSession()
        let (repo, session, _) = try makeSession(http, realtime, running)
        defer { repo.reset() }
        let connection = try await connect(session)
        defer { connection.cancel() }
        running.interruptFailure = HTTPError.server(
            statusCode: 409, message: "session capability is unavailable: session.interrupt")
        // The turn ended between the tap and the request; the stop is done.
        try await repo.interrupt(sessionId: "session")
        #expect(running.interruptAttempts == 1)
        #expect(session.failure == nil)
    }

    @Test func readOnlyTakeoverConflictKeepsFailingLoudly() async throws {
        let http = TestHTTPTransport(), realtime = TestRealtimeAPI()
        let running = RunningSession()
        let (repo, session, _) = try makeSession(http, realtime, running)
        defer { repo.reset() }
        let connection = try await connect(session)
        defer { connection.cancel() }
        running.interruptFailure = HTTPError.server(
            statusCode: 409, message: "session is read-only until takeover is enabled")
        // A conflict that is not the no-active-turn gate is a real failure and
        // must not be swallowed as success.
        await #expect(throws: HTTPError.self) {
            try await repo.interrupt(sessionId: "session")
        }
    }

    @Test func switchedButNotStoppedReportsThroughTheExistingChannel() async throws {
        let http = TestHTTPTransport(), realtime = TestRealtimeAPI()
        let running = RunningSession()
        let (repo, session, chat) = try makeSession(http, realtime, running)
        defer { repo.reset() }
        let connection = try await connect(session)
        defer { connection.cancel() }
        running.interruptFailure = HTTPError.server(statusCode: 502, message: "connector is unavailable")

        await chat.loadSettings()
        #expect(chat.settings.selectModel("model-b"))
        // The selection landed; the stop did not. There is no rollback of the
        // confirmed write and no fake success — the switch is announced and
        // the real failure goes out on the existing error channel while the
        // turn keeps running under the old model.
        #expect(await chat.applySettings())
        #expect(http.count("selections") == 1)
        #expect(running.interruptAttempts == 1)
        #expect(chat.switchFeedback?.title == "已切换到 Model B")
        #expect(chat.error != nil)
        #expect(chat.isRunning && session.runtime.state?.status == .running)
    }

    @Test func acceptedInterruptMakesTheComposerUsableBeforeAnyFrame() async throws {
        let http = TestHTTPTransport(), realtime = TestRealtimeAPI()
        let running = RunningSession()
        let (repo, session, chat) = try makeSession(http, realtime, running)
        defer { repo.reset() }
        let connection = try await connect(session)
        defer { connection.cancel() }
        #expect(chat.isRunning && !session.canSend)

        // The follow-up recovery is parked inside its live read, so the
        // window between the acknowledgement and the authoritative facts is
        // observable.
        running.gated = true
        let gate = TestGate()
        running.gateLiveState = gate
        let stop = Task { try await repo.interrupt(sessionId: "session") }
        try await eventually { running.interruptCalls == 1 && running.liveStateReads > 1 }

        // Within the acknowledgement: the predicted turn end opens the send
        // key, and it announces nothing. The prediction stays inside the
        // composer — every other reader still sees the authoritative turn.
        #expect(session.runtime.predictedIdle)
        #expect(chat.isRunning && !chat.isComposerStreaming && session.canSend)
        #expect(session.runtime.authoritativeTurnEnds == 0)
        #expect(chat.switchFeedback == nil)

        running.gated = false
        gate.release()
        try await stop.value
        // Truth landed: the prediction is over, the idle facts stand, and
        // now the turn ending is authoritative.
        #expect(!session.runtime.predictedIdle)
        #expect(session.runtime.state?.status == .idle)
        #expect(!chat.isRunning && !chat.isComposerStreaming && session.canSend)
        #expect(session.runtime.authoritativeTurnEnds == 1)
    }

    @Test func failedFollowUpReadRollsThePredictionBackAndReportsIt() async throws {
        let http = TestHTTPTransport(), realtime = TestRealtimeAPI()
        let running = RunningSession()
        let (repo, session, chat) = try makeSession(http, realtime, running)
        defer { repo.reset() }
        let connection = try await connect(session)
        defer { connection.cancel() }
        running.failLiveState = true

        try await repo.interrupt(sessionId: "session")

        // The acknowledgement landed but the truth could not be confirmed:
        // the optimistic value rolls back to the last authoritative state and
        // the failure goes out on the existing channel — the stop re-appears
        // and stays reachable while stale.
        #expect(!session.runtime.predictedIdle)
        #expect(chat.isRunning && chat.isComposerStreaming)
        #expect(session.runtime.permitsInterruptAttempt())
        #expect(session.failure != nil)
        #expect(!session.canSend)
    }

    @Test func manualStopWhileStaleStillAttemptsTheInterrupt() async throws {
        let http = TestHTTPTransport(), realtime = TestRealtimeAPI()
        let running = RunningSession()
        let (repo, session, chat) = try makeSession(http, realtime, running)
        defer { repo.reset() }
        let connection = try await connect(session)
        defer { connection.cancel() }
        // Stale without any local write: a failed read leaves the projection
        // stale while the socket stays up.
        running.failLiveState = true
        try await repo.setTakeover(sessionId: "session", enabled: true)
        #expect(!session.runtime.isFresh)
        #expect(chat.isRunning && session.runtime.permitsInterruptAttempt())

        running.failLiveState = false
        await chat.interrupt()

        #expect(running.interruptCalls == 1)
        #expect(!chat.isRunning && !chat.isComposerStreaming && session.canSend)
        #expect(session.runtime.state?.status == .idle)
    }

    // MARK: - A2: selection responses cannot rewrite the turn window

    @Test func selectionResponseSynthesizedIdleNeverOverwritesARunningProjection() async throws {
        let http = TestHTTPTransport(), realtime = TestRealtimeAPI()
        let running = RunningSession()
        let (repo, session, chat) = try makeSession(http, realtime, running)
        defer { repo.reset() }
        let connection = try await connect(session)
        defer { connection.cancel() }

        running.gated = true
        let gate = TestGate()
        running.gateLiveState = gate
        let write = Task { try await repo.setSelection(sessionId: "session", scope: .model, selectionId: Self.modelB) }
        try await eventually { running.selectionsHandled && running.liveStateReads > 1 }

        // The write response carried `status: "idle"` (the server synthesises
        // it when the runtime's selection result has no state) while the turn
        // is still running. The projection must show the turn, not the lie —
        // this is the exact shape of the 2026-10-05 grey send key.
        let data = try #require(repo.cached(sessionId: "session"))
        #expect(data.state?.status == .running)
        let model: String? = data.state?.selections[.model].flatMap { $0 }
        #expect(model == Self.modelB)
        #expect(chat.isRunning)
        #expect(!session.runtime.allows("session.send_message"))
        #expect(session.runtime.authoritativeTurnEnds == 0)

        running.gated = false
        gate.release()
        try await write.value
        #expect(session.runtime.state?.status == .running)
    }

    @Test func modelSwitchPlacesTheInterruptAfterASelectionTheServerRefused() async throws {
        let http = TestHTTPTransport(), realtime = TestRealtimeAPI()
        let running = RunningSession()
        let (repo, session, chat) = try makeSession(http, realtime, running)
        defer { repo.reset() }
        let connection = try await connect(session)
        defer { connection.cancel() }
        http.respond = { call in
            if call.path.hasSuffix("selections") {
                throw HTTPError.server(statusCode: 422, message: "unknown Claude model selection")
            }
            return try http.defaultResponse(call)
        }
        await chat.loadSettings()
        #expect(chat.settings.selectModel("model-b"))
        #expect(!(await chat.applySettings()))
        // A refused selection aborts the switch; the running turn is not
        // stopped and the failure stays on the sheet's existing channel.
        #expect(http.count("interrupt") == 0)
        #expect(chat.settingsError != nil)
        #expect(chat.switchFeedback == nil)
        #expect(chat.isRunning)
    }

    // MARK: - A3: self-healing and honest feedback

    @Test func staleProjectionHealsItselfWithoutUserAction() async throws {
        let http = TestHTTPTransport(), realtime = TestRealtimeAPI()
        let running = RunningSession()
        let (repo, session, _) = try makeSession(http, realtime, running)
        defer { repo.reset() }
        let connection = try await connect(session)
        defer { connection.cancel() }
        running.failLiveState = true
        try await repo.setTakeover(sessionId: "session", enabled: true)
        #expect(!session.runtime.isFresh)

        // The heal keeps retrying while the read fails — a visible session is
        // never abandoned.
        let attemptsWhileFailing = running.liveStateReads
        try await eventually { running.liveStateReads > attemptsWhileFailing + 1 }

        running.failLiveState = false
        // No tap, no reconnect, no refresh: the background heal re-runs
        // recovery and the gate opens by itself.
        try await eventually { session.runtime.isFresh }
        #expect(session.canSend == false) // still a running turn, still honest
        #expect(session.runtime.allows("session.interrupt"))
    }

    @Test func freshStateCapabilityContradictionHealsWithoutWaitingForAnotherFrame() async throws {
        let http = TestHTTPTransport(), realtime = TestRealtimeAPI()
        let running = RunningSession()
        let (repo, session, _) = try makeSession(http, realtime, running)
        defer { repo.reset() }
        let connection = try await connect(session)
        defer { connection.cancel() }
        #expect(session.runtime.allows("session.interrupt"))

        // One of the two independently delivered frames of the turn window is
        // lost/wrong: the capability frame claims idle while the state says a
        // turn is in flight. No follow-up frame is coming, so the
        // contradiction itself has to trigger the read.
        let capabilityFrame = try capabilitiesJSON(sendAvailable: true, interruptAvailable: false)
        realtime.yield(try event("runtime.capability.updated", seq: 11,
            payload: ["capabilitySet": capabilityFrame["capabilitySet"]!]))
        try await eventually { !session.runtime.allows("session.interrupt") }

        try await eventually { session.runtime.allows("session.interrupt") }
        #expect(!session.runtime.allows("session.send_message"))
    }

    @Test func predictedTurnEndNeverAnnouncesACompletion() async throws {
        let http = TestHTTPTransport(), realtime = TestRealtimeAPI()
        let running = RunningSession()
        let (repo, session, _) = try makeSession(http, realtime, running)
        defer { repo.reset() }
        let connection = try await connect(session)
        defer { connection.cancel() }
        running.gated = true
        let gate = TestGate()
        running.gateLiveState = gate
        let stop = Task { try await repo.interrupt(sessionId: "session") }
        try await eventually { session.runtime.predictedIdle }

        // The running flag's edge moves, but the completion cue's source — the
        // authoritative turn-ending count — does not: the cue is the model's,
        // and it stays still until facts confirm an idle turn.
        #expect(session.runtime.authoritativeTurnEnds == 0)
        running.gated = false
        gate.release()
        try await stop.value
        #expect(session.runtime.authoritativeTurnEnds == 1)
    }
}

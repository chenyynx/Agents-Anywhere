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
    private static let effortHigh = "sel_effort_high"

    private static func turnInFlight(_ status: String) -> Bool {
        ["running", "pending", "waiting", "waiting_approval", "stopping", "blocked"].contains(status)
    }

    private func stateJSON(status: String, model: String = ModelSwitchRecoveryTests.modelA) throws -> [String: Any] {
        var object = try fixtureObject("state")
        var state = object["state"] as! [String: Any]
        state["status"] = status
        state["selections"] = ["model": model, "effort": NSNull()]
        object["state"] = state
        return object
    }

    private func capabilityJSON(_ id: String, available: Bool, supported: Bool = true, allowed: Bool = true) -> [String: Any] {
        [
            "allowed": allowed, "available": available, "capabilityId": id, "parameters": [:],
            "runtime": "claude", "runtimeId": "rti_work", "scope": "runtime", "sessionId": NSNull(),
            "supported": supported, "unavailableReason": NSNull(), "version": "1",
        ]
    }

    /// The documented turn window: while the turn runs, send is unavailable
    /// and interrupt is available; idle is the mirror image. Catalog
    /// capabilities ride along so the options sheet can load and apply.
    private func capabilitiesJSON(
        sendAvailable: Bool,
        interruptAvailable: Bool,
        interruptSupported: Bool = true,
        interruptAllowed: Bool = true
    ) -> [String: Any] {
        [
            "capabilitySet": [
                "capabilities": [
                    capabilityJSON("session.send_message", available: sendAvailable),
                    capabilityJSON("session.interrupt", available: interruptAvailable,
                        supported: interruptSupported, allowed: interruptAllowed),
                    capabilityJSON("catalog.model", available: true),
                    capabilityJSON("catalog.permission", available: true),
                ],
                "revision": 10,
            ],
            "connectorId": "device",
            "serverTime": "2026-09-05T12:00:00Z",
        ]
    }

    /// Two models; the first carries reasoning options so an effort-only
    /// change (the same model id) is expressible.
    private func catalogJSON() -> [String: Any] {
        func reasoning(_ id: String, _ title: String, _ selection: String, `default`: Bool) -> [String: Any] {
            ["default": `default`, "description": NSNull(), "displayName": title, "fullModelId": NSNull(),
             "id": id, "metadata": [:], "selectionId": selection]
        }
        func model(_ id: String, _ title: String, _ selection: String, _ reasoningItems: [[String: Any]]) -> [String: Any] {
            ["default": false, "description": NSNull(), "displayName": title, "id": id,
             "metadata": [:], "reasoningItems": reasoningItems, "selectionId": selection]
        }
        return [
            "catalog": [
                "models": [
                    model("model-a", "Model A", Self.modelA, [
                        reasoning("low", "Low", "sel_effort_low", default: true),
                        reasoning("high", "High", Self.effortHigh, default: false),
                    ]),
                    model("model-b", "Model B", Self.modelB, []),
                ],
                "revision": 1, "runtime": "claude",
            ],
            "serverTime": "2026-09-05T12:00:00Z",
        ]
    }

    private func selectionResponseJSON(status: String, model: String) throws -> [String: Any] {
        let object = try stateJSON(status: status, model: model)
        return ["ok": true, "state": object["state"]!, "connectorResult": ["ok": true],
                "serverTime": "2026-09-05T12:00:00Z"]
    }

    /// A connected session whose live facts say `running` (send closed,
    /// interrupt open) until the interrupt endpoint flips it to idle.
    ///
    /// Live-state reads are addressable by 1-based index so a test can park a
    /// specific round inside its read — the gate order is what makes a
    /// background round's behaviour observable.
    private final class RunningSession {
        var status = "running"
        var interruptAttempts = 0
        var interruptCalls = 0
        var interruptFailure: HTTPError?
        var selectionsHandled = false
        var liveStateReads = 0
        var failLiveState = false
        var interruptSupported = true
        var interruptAllowed = true
        /// Live-state reads with an index greater than this block on
        /// `overflowGate`.
        var blockReadsAbove: Int?
        var overflowGate: TestGate?
        /// Specific read indexes (1-based) block on their own gates.
        var readGates: [Int: TestGate] = [:]

        func json(_ value: [String: Any]) throws -> Data {
            try JSONSerialization.data(withJSONObject: value)
        }
    }

    private func makeSession(
        _ http: TestHTTPTransport,
        _ realtime: TestRealtimeAPI,
        _ running: RunningSession,
        healBackoff: V2SessionHealBackoff = V2SessionHealBackoff(),
        sleep: @escaping (Duration) async throws -> Void = { _ in try await Task.sleep(for: .milliseconds(1)) }
    ) throws -> (V2SessionRepository, V2SessionModel, SessionChatModel) {
        http.respond = { [weak running] call in
            guard let running else { throw HTTPError.invalidResponse }
            if call.path.hasSuffix("/state") {
                running.liveStateReads += 1
                let read = running.liveStateReads
                if running.failLiveState { throw URLError(.networkConnectionLost) }
                // The response is the read's own view: captured before any
                // gate, so a parked read cannot observe a later write.
                let captured = running.status
                if let gate = running.readGates[read] { await gate.wait() }
                if let blockAbove = running.blockReadsAbove, read > blockAbove {
                    await running.overflowGate?.wait()
                }
                return try running.json(try self.stateJSON(status: captured))
            }
            if call.path.hasSuffix("capabilities") {
                let active = Self.turnInFlight(running.status)
                return try running.json(self.capabilitiesJSON(
                    sendAvailable: !active, interruptAvailable: active,
                    interruptSupported: running.interruptSupported,
                    interruptAllowed: running.interruptAllowed))
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
        let runtime = V2RuntimeAPI(transport: http)
        let repo = V2SessionRepository(
            scope: V2ClientScope(serverURL: URL(string: "https://example.test/api/v2")!, accountID: "account"),
            detail: V2SessionDetailService(sessionAPI: V2SessionAPI(transport: http), runtimeAPI: runtime, realtimeAPI: realtime),
            interactions: V2RuntimeInteractionService(runtimeAPI: runtime),
            sleep: sleep,
            healBackoff: healBackoff
        )
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

    /// F8 (red team): an effort-only change inside the same model interrupts
    /// the turn (the connection rebuild semantics) but announces nothing —
    /// the note names a model, and the model did not change.
    @Test func effortOnlySwitchInterruptsWithoutAnnouncingAModelChange() async throws {
        let http = TestHTTPTransport(), realtime = TestRealtimeAPI()
        let running = RunningSession()
        let (repo, session, chat) = try makeSession(http, realtime, running)
        defer { repo.reset() }
        let connection = try await connect(session)
        defer { connection.cancel() }

        await chat.loadSettings()
        #expect(chat.settings.selectModel("model-a", reasoning: "high"))
        #expect(await chat.applySettings())
        #expect(http.count("selections") == 1)
        #expect(http.count("interrupt") == 1)
        #expect(chat.switchFeedback == nil)
        #expect(chat.error == nil)
        #expect(!chat.isRunning)
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

    /// F2 (red team): the server answers the same sentence for every
    /// capability refusal, so the text alone must not turn "this runtime has
    /// no interrupt at all" into a silent success.
    @Test func capabilityRefusalOnAnUnsupportedRuntimeIsNotSwallowed() async throws {
        let http = TestHTTPTransport(), realtime = TestRealtimeAPI()
        let running = RunningSession()
        let (repo, session, _) = try makeSession(http, realtime, running)
        defer { repo.reset() }
        let connection = try await connect(session)
        defer { connection.cancel() }
        running.interruptSupported = false
        // The live read rewrites the capability snapshot before the failure.
        try await repo.sync(sessionId: "session")
        #expect(session.runtime.capabilities?.capability(id: "session.interrupt")?.supported == false)

        running.interruptFailure = HTTPError.server(
            statusCode: 409, message: "session capability is unavailable: session.interrupt")
        await #expect(throws: HTTPError.self) {
            try await repo.interrupt(sessionId: "session")
        }
    }

    /// F2 (red team), client half: a switch on a runtime that cannot interrupt
    /// does not attempt one — the refusal could only be noise the user cannot
    /// act on (DG-10).
    @Test func modelSwitchSkipsTheInterruptAnUnsupportedRuntimeCannotDo() async throws {
        let http = TestHTTPTransport(), realtime = TestRealtimeAPI()
        let running = RunningSession()
        let (repo, session, chat) = try makeSession(http, realtime, running)
        defer { repo.reset() }
        let connection = try await connect(session)
        defer { connection.cancel() }
        running.interruptSupported = false
        try await repo.sync(sessionId: "session")

        await chat.loadSettings()
        #expect(chat.settings.selectModel("model-b"))
        #expect(await chat.applySettings())
        #expect(http.count("interrupt") == 0)
        #expect(chat.error == nil)
        #expect(chat.switchFeedback?.title == "已切换到 Model B")
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

    /// F1 (red team): the window the acceptance criterion measures is the one
    /// the *model* layer sees — `perform`'s `isWorking` gate must not cover the
    /// follow-up reads. The old implementation held `isWorking` for the whole
    /// read and fails this test.
    @Test func stopThroughTheChatModelLeavesTheComposerUsableAtTheAcknowledgement() async throws {
        let http = TestHTTPTransport(), realtime = TestRealtimeAPI()
        let running = RunningSession()
        let (repo, session, chat) = try makeSession(http, realtime, running)
        defer { repo.reset() }
        let connection = try await connect(session)
        defer { connection.cancel() }
        #expect(chat.isRunning && !session.canSend)

        // Park the follow-up read so the window between the acknowledgement
        // and the authoritative facts is observable.
        running.blockReadsAbove = 1
        let gate = TestGate()
        running.overflowGate = gate
        let stop = Task { await chat.interrupt() }
        try await eventually { running.interruptCalls == 1 && running.liveStateReads > 1 }

        // Within the acknowledgement, through the full model layer: the call
        // has returned (no `isWorking`), the send key is open, and nothing has
        // announced a completion.
        #expect(!chat.isWorking)
        #expect(session.runtime.predictedIdle)
        #expect(chat.isRunning && !chat.isComposerStreaming && session.canSend)
        #expect(session.runtime.authoritativeTurnEnds == 0)
        #expect(chat.switchFeedback == nil)

        running.blockReadsAbove = nil
        gate.release()
        await stop.value
        // Truth landed: the prediction is over, the idle facts stand, and now
        // the turn ending is authoritative.
        try await eventually { !session.runtime.predictedIdle }
        #expect(session.runtime.state?.status == .idle)
        #expect(!chat.isRunning && !chat.isComposerStreaming && session.canSend)
        #expect(session.runtime.authoritativeTurnEnds == 1)
    }

    /// F1 (red team), sheet half: the switch returns after its two writes, not
    /// after their recovery reads — the sheet is never frozen by read I/O.
    @Test func modelSwitchReturnsWhileItsFollowUpReadsAreStillParked() async throws {
        let http = TestHTTPTransport(), realtime = TestRealtimeAPI()
        let running = RunningSession()
        let (repo, session, chat) = try makeSession(http, realtime, running)
        defer { repo.reset() }
        let connection = try await connect(session)
        defer { connection.cancel() }

        await chat.loadSettings()
        #expect(chat.settings.selectModel("model-b"))
        // The selection's own follow-up read parks; the interrupt still lands.
        running.blockReadsAbove = 1
        let gate = TestGate()
        running.overflowGate = gate
        let apply = Task { await chat.applySettings() }

        try await eventually { !chat.isWorking && running.interruptCalls == 1 && session.runtime.predictedIdle }
        #expect(chat.error == nil)
        #expect(!chat.isComposerStreaming && session.canSend)

        running.blockReadsAbove = nil
        gate.release()
        #expect(await apply.value)
        try await eventually { !session.runtime.predictedIdle }
        #expect(session.runtime.state?.status == .idle)
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
        try await eventually { session.failure != nil }
        #expect(!session.runtime.predictedIdle)
        #expect(chat.isRunning && chat.isComposerStreaming)
        #expect(session.runtime.permitsInterruptAttempt())
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

        #expect(running.interruptAttempts == 1)
        try await eventually { !chat.isComposerStreaming && session.canSend }
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

        running.blockReadsAbove = 1
        let gate = TestGate()
        running.overflowGate = gate
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

        running.blockReadsAbove = nil
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

    /// F3 (red team): a stale projection refuses the switch *visibly* (the
    /// sheet's own error surface) instead of a silent no-op, and the retry
    /// after the background heal succeeds.
    @Test func staleModelSwitchRefusesVisiblyAndWorksAfterHealing() async throws {
        let http = TestHTTPTransport(), realtime = TestRealtimeAPI()
        let running = RunningSession()
        let (repo, session, chat) = try makeSession(http, realtime, running)
        defer { repo.reset() }
        let connection = try await connect(session)
        defer { connection.cancel() }
        await chat.loadSettings()
        running.failLiveState = true
        try await repo.setTakeover(sessionId: "session", enabled: true)
        #expect(!session.runtime.isFresh)
        #expect(chat.settings.selectModel("model-b"))

        #expect(!(await chat.applySettings()))
        #expect(chat.settingsError == "连接恢复后可更改对话选项。")
        #expect(http.count("selections") == 0 && http.count("interrupt") == 0)

        // The heal re-reads on its own; the same intent then lands.
        running.failLiveState = false
        try await eventually { session.runtime.isFresh }
        #expect(await chat.applySettings())
        #expect(http.count("selections") == 1)
        #expect(chat.switchFeedback?.title == "已切换到 Model B")
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

    /// F7 (red team): the contradiction has its own trigger. The periodic loop
    /// is parked for ten minutes here, so only the frame's own debounced heal
    /// can repair the projection inside the test window.
    @Test func connectionContradictionHealsFromTheFrameNotThePeriodicLoop() async throws {
        let http = TestHTTPTransport(), realtime = TestRealtimeAPI()
        let running = RunningSession()
        let parked = V2SessionHealBackoff(initial: .seconds(600), maximum: .seconds(600), mismatch: .milliseconds(1))
        let (repo, session, _) = try makeSession(http, realtime, running, healBackoff: parked,
            sleep: { try await Task.sleep(for: $0 / 1000) })
        defer { repo.reset() }
        let connection = try await connect(session)
        defer { connection.cancel() }
        #expect(session.runtime.allows("session.interrupt"))

        let capabilityFrame = capabilitiesJSON(sendAvailable: true, interruptAvailable: false)
        realtime.yield(try event("runtime.capability.updated", seq: 11,
            payload: ["capabilitySet": capabilityFrame["capabilitySet"]!]))
        try await eventually { !session.runtime.allows("session.interrupt") }

        // Healed far sooner than the parked periodic loop could have fired.
        try await Task.sleep(for: .milliseconds(50))
        #expect(session.runtime.allows("session.interrupt"))
        #expect(!session.runtime.allows("session.send_message"))
    }

    /// The periodic loop is the backstop for a contradiction nothing
    /// re-observes: with the frame trigger parked it still heals.
    @Test func connectionContradictionAlsoHealsFromThePeriodicBackstop() async throws {
        let http = TestHTTPTransport(), realtime = TestRealtimeAPI()
        let running = RunningSession()
        let slowMismatch = V2SessionHealBackoff(initial: .seconds(1), maximum: .seconds(1), mismatch: .seconds(600))
        let (repo, session, _) = try makeSession(http, realtime, running, healBackoff: slowMismatch,
            sleep: { try await Task.sleep(for: $0 / 1000) })
        defer { repo.reset() }
        let connection = try await connect(session)
        defer { connection.cancel() }

        let capabilityFrame = capabilitiesJSON(sendAvailable: true, interruptAvailable: false)
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
        running.blockReadsAbove = 1
        let gate = TestGate()
        running.overflowGate = gate
        let stop = Task { try await repo.interrupt(sessionId: "session") }
        try await eventually { session.runtime.predictedIdle }

        // The running flag's edge moves, but the completion cue's source — the
        // authoritative turn-ending count — does not: the cue is the model's,
        // and it stays still until facts confirm an idle turn.
        #expect(session.runtime.authoritativeTurnEnds == 0)
        running.blockReadsAbove = nil
        gate.release()
        try await stop.value
        try await eventually { session.runtime.authoritativeTurnEnds == 1 }
    }

    // MARK: - Red team F4: the prediction's lifetime

    /// F4 (red team): a round launched before the prediction cannot end it —
    /// its read carries pre-write facts. Only a round the prediction ordered
    /// may clear the window.
    @Test func aPreWriteRecoveryRoundCannotEndTheAcknowledgementWindow() async throws {
        let http = TestHTTPTransport(), realtime = TestRealtimeAPI()
        let running = RunningSession()
        let (repo, session, _) = try makeSession(http, realtime, running)
        defer { repo.reset() }
        let connection = try await connect(session)
        defer { connection.cancel() }
        // Read 2 is a round that was launched before the stop; read 3 is the
        // stop's own follow-up.
        let preWriteGate = TestGate(), followUpGate = TestGate()
        running.readGates = [2: preWriteGate, 3: followUpGate]
        realtime.yield(try event("session.refetch_required", seq: 11))
        try await eventually { running.liveStateReads == 2 }

        let stop = Task { try await repo.interrupt(sessionId: "session") }
        try await eventually { session.runtime.predictedIdle }

        // The pre-write round lands (it still says running)…
        preWriteGate.release()
        try await eventually { running.liveStateReads == 3 }
        // …and the window it could have killed is still open; only the round
        // the prediction ordered may end it.
        #expect(session.runtime.predictedIdle)

        followUpGate.release()
        try await stop.value
        try await eventually { !session.runtime.predictedIdle }
        #expect(session.runtime.state?.status == .idle)
    }

    /// F4 (red team): stopping or losing the connection clears the prediction
    /// explicitly instead of relying on `isFresh` to mask a stuck value.
    @Test func stoppingOrDisconnectingClearsTheOptimisticTurnEnd() async throws {
        let http = TestHTTPTransport(), realtime = TestRealtimeAPI()
        let running = RunningSession()
        let (repo, session, _) = try makeSession(http, realtime, running)
        defer { repo.reset() }
        let connection = try await connect(session)
        defer { connection.cancel() }
        running.blockReadsAbove = 1
        let gate = TestGate()
        running.overflowGate = gate
        let stop = Task { try await repo.interrupt(sessionId: "session") }
        try await eventually { session.runtime.predictedIdle }

        repo.suspend()

        #expect(!session.runtime.predictedIdle)
        running.blockReadsAbove = nil
        gate.release()
        _ = await stop.result
    }

    // MARK: - Red team F5/F6: heal cadence and cost

    /// F5 (red team): healing belongs to observed sessions; a cached entry
    /// nobody is looking at gets no spinning task at all.
    @Test func unobservedSessionsNeverStartAHealLoop() async throws {
        let http = TestHTTPTransport(), realtime = TestRealtimeAPI()
        let running = RunningSession()
        let sleeps = SleepProbe()
        let (repo, _, _) = try makeSession(http, realtime, running,
            sleep: { duration in sleeps.record(); try await Task.sleep(for: duration / 100) })
        defer { repo.reset() }
        _ = try await repo.load(sessionId: "session")
        repo.updateConnectivity(.init(availability: .online))
        try await Task.sleep(for: .milliseconds(60))
        #expect(sleeps.calls == 0)
    }

    /// F6 (red team): the cadence is the documented one — doubling from the
    /// initial delay, capped, and never zero.
    @Test func healBackoffFollowsItsDocumentedSchedule() {
        let backoff = V2SessionHealBackoff()
        let schedule = (0...7).map { backoff.delay(step: $0) }
        #expect(schedule == [.seconds(1), .seconds(2), .seconds(4), .seconds(8),
                             .seconds(16), .seconds(30), .seconds(30), .seconds(30)])
        let custom = V2SessionHealBackoff(initial: .milliseconds(250), maximum: .seconds(1))
        #expect((0...5).map { custom.delay(step: $0) }
            == [.milliseconds(250), .milliseconds(500), .seconds(1), .seconds(1), .seconds(1), .seconds(1)])
    }

    /// F6 (red team): the first heal attempt actually waits out its delay —
    /// the schedule is not folded away by a test-shaped sleep. The production
    /// second is scaled to 100 ms; the assertion window is a fifth of that.
    @Test func healCadenceIsRespectedBeforeTheFirstAttempt() async throws {
        let http = TestHTTPTransport(), realtime = TestRealtimeAPI()
        let running = RunningSession()
        let (repo, session, _) = try makeSession(http, realtime, running,
            healBackoff: V2SessionHealBackoff(initial: .seconds(2), maximum: .seconds(2)),
            sleep: { try await Task.sleep(for: $0 / 20) })
        defer { repo.reset() }
        let connection = try await connect(session)
        defer { connection.cancel() }
        running.failLiveState = true
        try await repo.setTakeover(sessionId: "session", enabled: true)
        #expect(!session.runtime.isFresh)
        let readsWhenStale = running.liveStateReads

        // 2 s / 20 = 100 ms: nothing may run yet.
        try await Task.sleep(for: .milliseconds(15))
        #expect(running.liveStateReads == readsWhenStale)
        // And the attempt does arrive once the delay is out.
        try await eventually { running.liveStateReads > readsWhenStale }
    }

    /// The composer matrix (D0-4 / postfix table, timing form): every status
    /// renders the truth on connect, keeps write safety while stale, and
    /// returns to the truth once healing lands.
    @Test func composerMatrixMatchesTheTruthForEveryStatus() async throws {
        for status in ["idle", "waiting", "waiting_approval", "pending", "running",
                       "stopping", "blocked", "error", "disconnected", "unknown"] {
            let http = TestHTTPTransport(), realtime = TestRealtimeAPI()
            let running = RunningSession()
            running.status = status
            let (repo, session, chat) = try makeSession(http, realtime, running)
            let connection = try await connect(session)
            let inFlight = Self.turnInFlight(status)

            #expect(chat.isRunning == inFlight, "\(status): running flag")
            #expect(chat.isComposerStreaming == inFlight, "\(status): composer window")
            #expect(session.canSend == !inFlight, "\(status): send gate")
            #expect(session.runtime.permitsInterruptAttempt() == inFlight, "\(status): stop gate")

            // Stale: writes stay closed; a stale projection never blocks the
            // stop gate (the relaxation F7 asks about).
            running.failLiveState = true
            try await repo.setTakeover(sessionId: "session", enabled: true)
            #expect(!session.canSend, "\(status): stale send must fail closed")
            #expect(session.runtime.permitsInterruptAttempt(), "\(status): stale stop stays reachable")
            running.failLiveState = false
            try await eventually { session.runtime.isFresh }
            #expect(session.canSend == !inFlight, "\(status): healed send gate")

            connection.cancel()
            repo.reset()
        }
    }

    // MARK: - Red team F7: the stop gate's stale branch

    @Test func stopStaysReachableWhenADeadProjectionSaysItCannotInterrupt() async throws {
        let http = TestHTTPTransport(), realtime = TestRealtimeAPI()
        let running = RunningSession()
        // Both heal paths are parked: this test needs the contradiction to
        // stand still while it is looked at.
        let parked = V2SessionHealBackoff(initial: .seconds(600), maximum: .seconds(600), mismatch: .seconds(600))
        let (repo, session, _) = try makeSession(http, realtime, running, healBackoff: parked,
            sleep: { try await Task.sleep(for: $0 / 1000) })
        defer { repo.reset() }
        let connection = try await connect(session)
        defer { connection.cancel() }

        // A contradictory capability frame (DG-2a: state says running, the
        // capability says idle) makes the stop gate close while fresh…
        let idleShape = capabilitiesJSON(sendAvailable: true, interruptAvailable: false)
        realtime.yield(try event("runtime.capability.updated", seq: 11,
            payload: ["capabilitySet": idleShape["capabilitySet"]!]))
        try await eventually { !session.runtime.permitsInterruptAttempt() }

        // …and staleness must not leave it closed: that is the dead grey the
        // relaxation exists for.
        running.failLiveState = true
        try await repo.setTakeover(sessionId: "session", enabled: true)
        #expect(!session.runtime.isFresh)
        #expect(session.runtime.permitsInterruptAttempt())
    }
}

/// Counts how often an injected sleep ran, to prove a task exists (or not).
@MainActor
private final class SleepProbe {
    private(set) var calls = 0
    func record() { calls += 1 }
}

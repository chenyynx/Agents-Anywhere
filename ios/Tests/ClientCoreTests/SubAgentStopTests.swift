import Foundation
import Testing
@testable import ClientCore

/// A3 iOS batch (claude-subagent-preserve-tasks.md §2 P2, frozen interface
/// §7.3/§7.4): per-task SubAgent stop controls — the projection, the render
/// gate, the in-flight form and the manual-stop `preserveBackground` flip.
///
/// The call-layer cases drive the real `SessionChatModel → repository → API`
/// path instead of a below-model shortcut: the F1 lesson was that a test
/// bypassing `perform`/`isWorking` over-declares what the user can reach.
@Suite @MainActor struct SubAgentStopTests {

    // MARK: - Fixtures

    private func item(_ id: String, type: String = "tool", status: String = "running", order: Int = 1,
                      content: [String: Any]) throws -> V2TimelineItem {
        var value = try itemObject(id: id, order: order)
        value["type"] = type; value["status"] = status; value["content"] = content
        return try decode(value)
    }

    private func cardItem(_ id: String = "card", status: String = "running",
                          agents: [String: Any]? = nil) throws -> V2TimelineItem {
        var content: [String: Any] = ["kind": "agent_call", "action": "invoke", "description": "排查服务状态"]
        if let agents { content["agents"] = agents }
        return try item(id, status: status, content: content)
    }

    /// One capability entry in the server's snapshot shape; the caller flips
    /// exactly the state under test.
    private func capabilityJSON(_ id: String, supported: Bool = true,
                                available: Bool = true, allowed: Bool = true) -> [String: Any] {
        ["allowed": allowed, "available": available, "capabilityId": id, "parameters": [:],
         "runtime": "claude", "runtimeId": "rti_work", "scope": "runtime", "sessionId": NSNull(),
         "supported": supported, "unavailableReason": NSNull(), "version": "1"]
    }

    private func capabilities(_ entries: [[String: Any]]) throws -> V2RuntimeCapabilitySnapshot {
        try decode(["capabilities": entries, "revision": 1])
    }

    private func usableCapabilities() throws -> V2RuntimeCapabilitySnapshot {
        try capabilities([capabilityJSON("session.subagent_control")])
    }

    /// The real model stack over the mock transport, with the bounded release
    /// shortened where a test wants to see the timeout path.
    private func chat(_ http: TestHTTPTransport, releaseAfter: Duration = .seconds(20)) -> SessionChatModel {
        let repo = repository(transport: http)
        return SessionChatModel(session: repo.session(id: "session"), repository: repo,
            attachments: .init(attachmentAPI: V2AttachmentAPI(transport: http)),
            subagentStopReleaseDelay: releaseAfter)
    }

    // MARK: - Projection: what a control can bind to

    @Test func liveTasksReadOnlyTheConnectorLiveStatuses() throws {
        let card = try cardItem(agents: [
            "t-run": ["status": "running", "subagentType": "Explore"],
            "t-async": ["status": "async_launched"],
            "t-done": ["status": "completed"],
            "t-stopped": ["status": "stopped"],
            "t-killed": ["status": "killed"],
            // A task event without a status leaves `{}` behind; it is not live.
            "t-blank": ["lastToolName": "Bash"],
        ])
        let tasks = SubAgentProgress.liveTasks(in: card)
        #expect(tasks.map(\.taskID) == ["t-async", "t-run"])
        #expect(tasks.map(\.status) == ["async_launched", "running"])
        #expect(tasks.first(where: { $0.taskID == "t-run" })?.subagentType == "Explore")

        // Only {running, async_launched} may grow a control — terminal
        // entries of any wording, and status-less receipts, never do.
        #expect(SubAgentProgress.liveTasks(in: try cardItem(agents: [
            "t-done": ["status": "completed"], "t-stopped": ["status": "stopped"],
        ])).isEmpty)
        // No agents map at all = a dispatch with no task receipt (no taskId):
        // that shape must not produce a control.
        #expect(SubAgentProgress.liveTasks(in: try cardItem()).isEmpty)
        // Non-card rows never project tasks.
        #expect(SubAgentProgress.liveTasks(in: try item("tool", content: ["kind": "command", "command": "ls"])).isEmpty)
    }

    @Test func liveTaskIDIsTheMapKeyWithTheExplicitIDWinning() throws {
        // The connector's binding: agents-map key == task id == receipt agentId.
        let keyed = try cardItem(agents: ["task-key": ["status": "running"]])
        #expect(SubAgentProgress.liveTasks(in: keyed).first?.taskID == "task-key")
        // Defensive reading: an entry that names its own id wins over the key.
        let named = try cardItem(agents: ["task-key": ["status": "running", "taskId": "task-explicit"]])
        #expect(SubAgentProgress.liveTasks(in: named).first?.taskID == "task-explicit")
    }

    @Test func nestedTasksGetTheirOwnStopTargets() throws {
        // G3: a subagent another subagent dispatched is a live entry of its
        // own — its control binds the nested task id, never the parent's.
        let card = try cardItem(agents: [
            "t-outer": ["status": "running"],
            "t-inner": ["status": "running", "subagentType": "Explore", "spawnDepth": 1],
        ])
        let tasks = SubAgentProgress.stopTasks(in: card, capabilities: try usableCapabilities())
        #expect(tasks.map(\.taskID) == ["t-inner", "t-outer"])
        #expect(tasks.first?.spawnDepth == 1)
        #expect(tasks.first?.label == "Explore")
        // The spoken/rendered name falls back type → last tool → raw task id.
        #expect(SubAgentTask(taskID: "t9", status: "running", subagentType: nil,
                             lastToolName: "Bash", spawnDepth: nil).label == "Bash")
        #expect(SubAgentTask(taskID: "t9", status: "running", subagentType: nil,
                             lastToolName: nil, spawnDepth: nil).label == "t9")
    }

    // MARK: - Render gate (门控不渲染)

    @Test func stopControlsRenderOnlyUnderTheUsableCapability() throws {
        let card = try cardItem(agents: ["t1": ["status": "running"]])
        // No capability snapshot at all, a missing capability, and each of
        // the three states switched off in turn: nothing renders.
        #expect(SubAgentProgress.stopTasks(in: card, capabilities: nil).isEmpty)
        #expect(SubAgentProgress.stopTasks(in: card, capabilities: try capabilities([])).isEmpty)
        #expect(SubAgentProgress.stopTasks(in: card, capabilities:
            try capabilities([capabilityJSON("session.subagent_control", supported: false)])).isEmpty)
        #expect(SubAgentProgress.stopTasks(in: card, capabilities:
            try capabilities([capabilityJSON("session.subagent_control", available: false)])).isEmpty)
        #expect(SubAgentProgress.stopTasks(in: card, capabilities:
            try capabilities([capabilityJSON("session.subagent_control", allowed: false)])).isEmpty)
        // Another capability's availability never leaks in.
        #expect(SubAgentProgress.stopTasks(in: card, capabilities:
            try capabilities([capabilityJSON("session.interrupt")])).isEmpty)

        // All three usable: the live task renders exactly one control target.
        let open = try usableCapabilities()
        #expect(SubAgentProgress.stopTasks(in: card, capabilities: open).map(\.taskID) == ["t1"])
        // The capability alone renders nothing: the card must carry a live
        // task, and a non-card row still never grows a control.
        #expect(SubAgentProgress.stopTasks(in: try cardItem(), capabilities: open).isEmpty)
        #expect(SubAgentProgress.stopTasks(in: try item("tool", content: ["kind": "command", "command": "ls"]),
                                           capabilities: open).isEmpty)
    }

    @Test func cardProjectionExposesTheSameTargetsAsTheRow() throws {
        let open = try usableCapabilities()
        let card = try #require(SubAgentProgress.card(try cardItem(agents: [
            "t1": ["status": "running", "lastToolName": "Bash"],
        ])))
        #expect(card.liveTasks.map(\.taskID) == ["t1"])
        #expect(card.liveTasks.first?.label == "Bash")
        #expect(SubAgentProgress.stopTasks(for: card, capabilities: open).map(\.taskID) == ["t1"])
        #expect(SubAgentProgress.stopTasks(for: card, capabilities: nil).isEmpty)

        // A closed card carries no live task even with the capability open —
        // the panel header must not offer a stop for finished work.
        let closed = try #require(SubAgentProgress.card(try cardItem(status: "done", agents: [
            "t1": ["status": "completed"],
        ])))
        #expect(closed.liveTasks.isEmpty)
        #expect(SubAgentProgress.stopTasks(for: closed, capabilities: open).isEmpty)
    }

    // MARK: - Call layer (model → repository → endpoint)

    @Test func stopThroughTheChatModelReachesTheStopEndpoint() async throws {
        let http = TestHTTPTransport()
        let chat = chat(http)
        defer { chat.repository.reset() }
        await chat.stopSubagent(taskID: "t1")

        #expect(chat.error == nil)
        #expect(!chat.isWorking)
        let call = try #require(http.calls.last)
        #expect(call.method == .post)
        #expect(call.path == "/sessions/session/runtime/subagent/stop")
        #expect(call.body?["taskId"] == .string("t1"))
        #expect(http.count("subagent/stop") == 1)
        // Accepted: the control holds its in-flight form until the card's
        // terminal event converges (or the bounded release).
        #expect(chat.stoppingSubagentTaskIDs.contains("t1"))
    }

    @Test func secondTapWhileAStopIsInFlightIsNotASecondRequest() async throws {
        let http = TestHTTPTransport()
        let gate = TestGate()
        http.respond = { call in
            if call.path.hasSuffix("subagent/stop") { await gate.wait() }
            return try http.defaultResponse(call)
        }
        let chat = chat(http)
        defer { chat.repository.reset() }
        let first = Task { await chat.stopSubagent(taskID: "t1") }
        try await eventually { http.count("subagent/stop") == 1 }
        // The control is in flight: a second tap adds no request.
        await chat.stopSubagent(taskID: "t1")
        #expect(http.count("subagent/stop") == 1)
        gate.release()
        await first.value
        #expect(chat.stoppingSubagentTaskIDs.contains("t1"))
        #expect(chat.error == nil)
    }

    @Test func stopInFlightIsReleasedWhenTheTerminalFrameNeverLands() async throws {
        let http = TestHTTPTransport()
        let gate = TestGate()
        http.respond = { call in
            if call.path.hasSuffix("subagent/stop") { await gate.wait() }
            return try http.defaultResponse(call)
        }
        let chat = chat(http, releaseAfter: .milliseconds(30))
        defer { chat.repository.reset() }
        let stop = Task { await chat.stopSubagent(taskID: "t1") }
        // In flight while the request is still on the wire (no timer race).
        try await eventually { chat.stoppingSubagentTaskIDs.contains("t1") }
        gate.release()
        await stop.value
        // The terminal frame never lands: the bounded release is the exit.
        try await eventually { !chat.stoppingSubagentTaskIDs.contains("t1") }
    }

    @Test func aFailedStopRollsTheControlBackAndUsesTheErrorChannel() async throws {
        let http = TestHTTPTransport()
        http.respond = { call in
            if call.path.hasSuffix("subagent/stop") { throw HTTPError.server(statusCode: 500, message: "boom") }
            return try http.defaultResponse(call)
        }
        let chat = chat(http)
        defer { chat.repository.reset() }
        await chat.stopSubagent(taskID: "t1")
        #expect(chat.error != nil)
        #expect(!chat.stoppingSubagentTaskIDs.contains("t1"))
        #expect(!chat.isWorking)
    }

    @Test func unknownTaskIDIsANonEventNotAnError() async throws {
        // Frozen §7.2: the server answers `stopped: false` for an id that is
        // not in the running snapshot — no throw, no failure surface; the
        // card converges (or the bounded release lets the user retry).
        let http = TestHTTPTransport()
        http.respond = { call in
            if call.path.hasSuffix("subagent/stop") {
                return try JSONSerialization.data(withJSONObject: ["ok": true, "result": ["stopped": false]])
            }
            return try http.defaultResponse(call)
        }
        let chat = chat(http)
        defer { chat.repository.reset() }
        await chat.stopSubagent(taskID: "ghost")
        #expect(chat.error == nil)
        // Accepted (though not matched): the control holds its in-flight form
        // until the card converges or the bounded release expires.
        #expect(chat.stoppingSubagentTaskIDs.contains("ghost"))
    }

    @Test func manualStopCarriesThePreserveBackgroundFlip() async throws {
        // Frozen §7.4: the manual stop (the composer's own stop path) now
        // asks the runtime to spare background work; the per-task controls
        // ship in the same version.
        let http = TestHTTPTransport()
        let chat = chat(http)
        defer { chat.repository.reset() }
        await chat.interrupt()
        let call = try #require(http.calls.last { $0.path.hasSuffix("interrupt") })
        #expect(call.body?["preserveBackground"] == .bool(true))
    }

    // MARK: - F-I (review LOW-1): the follow-up reconcile belongs to the lifecycle

    /// One parked follow-up reconcile window: a connected session whose manual
    /// stop orders the background round; the round's live-state read parks on
    /// `gate` and fails with a real transport error once released.
    @MainActor private final class ParkedFollowUp {
        /// What the transport closure and the test share (a box, so the
        /// closure never captures the fixture mid-initialization).
        @MainActor final class Reads {
            var gated = false
            var parked = 0
        }
        let http: TestHTTPTransport
        let realtime = TestRealtimeAPI()
        let gate: TestGate
        let reads: Reads
        let repo: V2SessionRepository
        let session: V2SessionModel
        let chat: SessionChatModel

        init() {
            let transport = TestHTTPTransport()
            let gate = TestGate()
            let reads = Reads()
            transport.respond = { call in
                if reads.gated, call.path.hasSuffix("/state") {
                    reads.parked += 1
                    await gate.wait()
                    throw URLError(.networkConnectionLost)
                }
                return try transport.defaultResponse(call)
            }
            http = transport
            self.gate = gate
            self.reads = reads
            repo = repository(transport: transport, realtime: realtime)
            session = repo.session(id: "session")
            chat = SessionChatModel(session: session, repository: repo,
                attachments: .init(attachmentAPI: V2AttachmentAPI(transport: transport)))
        }

        /// Connects (its observation keeps the entry registered), arms the
        /// gate and stops manually — the follow-up round is ordered by the
        /// stop; returns once the round's read is parked, plus the connection
        /// task the caller cancels to stop the entry.
        func startParkedFollowUp() async throws -> Task<Void, Never> {
            let connection = Task { await session.connect() }
            try await eventually { session.runtime.isFresh }
            reads.gated = true
            await chat.interrupt()
            try await eventually { reads.parked == 1 }
            return connection
        }
    }

    /// F-I: the follow-up reconcile wrapper is registered on the entry and
    /// cancelled by the lifecycle stop, so a failure that lands after the
    /// entry was stopped never writes itself into a dead lifecycle. The entry
    /// stays registered across the stop (only the observer leaves), so the
    /// `isCurrent` guard alone cannot catch this — the parked read does fail
    /// with a real transport error, which is the one the stopped case must
    /// swallow.
    @Test func stoppedEntryNeverReceivesAFollowUpReconcileFailure() async throws {
        let fixture = ParkedFollowUp()
        defer { fixture.repo.reset() }
        let connection = try await fixture.startParkedFollowUp()

        // The last observer leaves: the entry stops but stays registered.
        connection.cancel()
        try await eventually { !fixture.session.runtime.isFresh }
        #expect(fixture.repo.cached(sessionId: "session") != nil)

        // The parked read now fails; the round completes with that real error.
        // Give the wrapper every chance to write it back.
        fixture.gate.release()
        try await Task.sleep(for: .milliseconds(80))
        #expect(fixture.session.failure == nil)
    }

    /// The control for the case above: with the lifecycle alive, the very same
    /// parked window surfaces the failure on the entry's error channel — the
    /// stopped case is exercised against wiring that does produce the error.
    @Test func liveEntrySurfacesTheSameFollowUpReconcileFailure() async throws {
        let fixture = ParkedFollowUp()
        defer { fixture.repo.reset() }
        let connection = try await fixture.startParkedFollowUp()
        defer { connection.cancel() }

        fixture.gate.release()
        try await eventually { fixture.session.failure != nil }
    }
}

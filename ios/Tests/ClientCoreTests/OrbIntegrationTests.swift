import Foundation
import Testing
@testable import ClientCore

/// Batch 3 integration tests: the activity mapping's resolver priority, the
/// receive-pulse policy, the projection merge outcomes that only the live
/// receive path consumes, and the compact predicate extraction shared with
/// the row presentation.
@Suite @MainActor struct OrbIntegrationTests {
    // MARK: - Fixtures

    private func signals(_ configure: (inout OrbActivitySignals) -> Void) -> OrbActivitySignals {
        var value = OrbActivitySignals(status: nil, hasRespondableNotice: false, runningSubagentCount: 0,
                                       hasActiveToolItem: false, hasActiveCompactItem: false,
                                       isStreamingAssistantText: false, hasActiveReasoningItem: false)
        configure(&value)
        return value
    }

    private func orbItem(type: String = "message", role: String? = "assistant",
                         status: String = "done") throws -> V2TimelineItem {
        var object = try itemObject()
        object["type"] = type
        if let role { object["role"] = role } else { object.removeValue(forKey: "role") }
        object["status"] = status
        return try decode(object, as: V2TimelineItem.self)
    }

    private func compactItem(state: String, status: String, type: String = "system") throws -> V2TimelineItem {
        var object = try itemObject(id: "compact")
        object["type"] = type
        object["status"] = status
        object["content"] = ["kind": "compact", "state": state]
        return try decode(object, as: V2TimelineItem.self)
    }

    /// The Codex file-read/write carrier: an artifact row whose wire kind is
    /// `file_change` (connector/runtimes/codex/timeline/items.py:98-99).
    private func fileChangeArtifactItem(status: String) throws -> V2TimelineItem {
        var object = try itemObject(id: "file-change")
        object["type"] = "artifact"
        object["status"] = status
        object["content"] = ["kind": "file_change", "path": "Sources/App.swift", "action": "modify"]
        return try decode(object, as: V2TimelineItem.self)
    }

    /// A running assistant message payload for the socket harness.
    private func liveItemObject(id: String = "item", order: Int = 1, revision: Int = 1,
                                seq: Int = 10, status: String = "running") throws -> [String: Any] {
        var object = try itemObject(id: id, order: order, revision: revision, seq: seq)
        object["status"] = status
        return object
    }

    // MARK: - Resolver priority

    @Test func resolverWaitingForUserWinsFromBothEntries() {
        // A respondable notice beats every lower signal, all of them hot.
        let everythingHot = signals {
            $0.hasRespondableNotice = true; $0.runningSubagentCount = 2
            $0.hasActiveToolItem = true; $0.hasActiveCompactItem = true
            $0.isStreamingAssistantText = true; $0.hasActiveReasoningItem = true
        }
        #expect(OrbActivityResolver.resolve(everythingHot) == .waitingForUser)
        // Either entry alone is enough.
        let approval = signals { $0.status = .waitingApproval }
        #expect(OrbActivityResolver.resolve(approval) == .waitingForUser)
        // A queued turn's .waiting (no notice) is not the waiting-for-you state.
        let queued = signals { $0.status = .waiting }
        #expect(OrbActivityResolver.resolve(queued) == .toolRunning)
    }

    @Test func resolverPriorityDescendsLayerByLayer() {
        // Each layer alone is hit…
        let subagents = signals { $0.runningSubagentCount = 1 }
        let tool = signals { $0.hasActiveToolItem = true }
        let compact = signals { $0.hasActiveCompactItem = true }
        let streaming = signals { $0.isStreamingAssistantText = true }
        let reasoning = signals { $0.hasActiveReasoningItem = true }
        #expect(OrbActivityResolver.resolve(subagents) == .parallelWork)
        #expect(OrbActivityResolver.resolve(tool) == .toolRunning)
        #expect(OrbActivityResolver.resolve(compact) == .summarizing)
        #expect(OrbActivityResolver.resolve(streaming) == .writing)
        #expect(OrbActivityResolver.resolve(reasoning) == .thinking)
        // …and each layer beats every layer below it.
        let subagentsPlusAll = signals {
            $0.runningSubagentCount = 1; $0.hasActiveToolItem = true; $0.hasActiveCompactItem = true
            $0.isStreamingAssistantText = true; $0.hasActiveReasoningItem = true
        }
        let toolPlusAll = signals {
            $0.hasActiveToolItem = true; $0.hasActiveCompactItem = true
            $0.isStreamingAssistantText = true; $0.hasActiveReasoningItem = true
        }
        let compactPlusAll = signals {
            $0.hasActiveCompactItem = true; $0.isStreamingAssistantText = true; $0.hasActiveReasoningItem = true
        }
        let streamingPlusThinking = signals {
            $0.isStreamingAssistantText = true; $0.hasActiveReasoningItem = true
        }
        #expect(OrbActivityResolver.resolve(subagentsPlusAll) == .parallelWork)
        #expect(OrbActivityResolver.resolve(toolPlusAll) == .toolRunning)
        #expect(OrbActivityResolver.resolve(compactPlusAll) == .summarizing)
        #expect(OrbActivityResolver.resolve(streamingPlusThinking) == .writing)
    }

    @Test func resolverFallsBackToTheScanWhenNothingIsLive() {
        let nothing = signals { _ in }
        let pending = signals { $0.status = .pending }
        let running = signals { $0.status = .running }
        #expect(OrbActivityResolver.resolve(nothing) == .toolRunning)
        #expect(OrbActivityResolver.resolve(pending) == .toolRunning)
        #expect(OrbActivityResolver.resolve(running) == .toolRunning)
    }

    // MARK: - Receive-pulse policy

    @Test func pulsePolicyAssistantInsertIsAFullPulseOutsideTheThrottle() throws {
        let anchor = Date(timeIntervalSinceReferenceDate: 3_000)
        let decision = OrbPulsePolicy.decide(item: try orbItem(status: "done"), wasInserted: true,
                                             now: anchor.addingTimeInterval(10), lastStreamPulseAt: anchor)
        #expect(decision.pulse?.strength == 1.0)
        // An insert neither spends nor moves the stream throttle.
        #expect(decision.streamPulseAt == anchor)
    }

    @Test func pulsePolicyExcludesNonAssistantRows() throws {
        let now = Date(timeIntervalSinceReferenceDate: 4_000)
        let user = OrbPulsePolicy.decide(item: try orbItem(role: "user", status: "running"),
                                         wasInserted: true, now: now, lastStreamPulseAt: nil)
        #expect(user.pulse == nil)
        #expect(user.streamPulseAt == nil)
        let userUpdate = OrbPulsePolicy.decide(item: try orbItem(role: "user", status: "running"),
                                               wasInserted: false, now: now, lastStreamPulseAt: nil)
        #expect(userUpdate.pulse == nil)
        let tool = OrbPulsePolicy.decide(item: try orbItem(type: "tool", role: nil, status: "running"),
                                         wasInserted: true, now: now, lastStreamPulseAt: nil)
        #expect(tool.pulse == nil)
        let reasoning = OrbPulsePolicy.decide(item: try orbItem(type: "reasoning", role: nil, status: "running"),
                                              wasInserted: true, now: now, lastStreamPulseAt: nil)
        #expect(reasoning.pulse == nil)
    }

    @Test func pulsePolicyStreamUpdateIsASmallThrottledPulse() throws {
        let streaming = try orbItem(status: "running")
        let anchor = Date(timeIntervalSinceReferenceDate: 5_000)

        // The first update has no anchor to throttle against: it pulses and
        // advances the anchor.
        let first = OrbPulsePolicy.decide(item: streaming, wasInserted: false,
                                          now: anchor, lastStreamPulseAt: nil)
        #expect(first.pulse?.strength == 0.3)
        #expect(first.streamPulseAt == anchor)

        // Inside the window: no pulse, the anchor stays put.
        let inside = OrbPulsePolicy.decide(item: streaming, wasInserted: false,
                                           now: anchor.addingTimeInterval(0.249),
                                           lastStreamPulseAt: first.streamPulseAt)
        #expect(inside.pulse == nil)
        #expect(inside.streamPulseAt == anchor)

        // Exactly at the boundary the next small pulse is allowed.
        let boundary = anchor.addingTimeInterval(0.25)
        let atBoundary = OrbPulsePolicy.decide(item: streaming, wasInserted: false,
                                               now: boundary, lastStreamPulseAt: first.streamPulseAt)
        #expect(atBoundary.pulse?.strength == 0.3)
        #expect(atBoundary.streamPulseAt == boundary)

        let pending = OrbPulsePolicy.decide(item: try orbItem(status: "pending"), wasInserted: false,
                                            now: boundary.addingTimeInterval(1), lastStreamPulseAt: nil)
        #expect(pending.pulse?.strength == 0.3)
    }

    @Test func pulsePolicyIgnoresSettledUpdates() throws {
        for status in ["done", "failed", "cancelled", "interrupted", "hidden"] {
            let decision = OrbPulsePolicy.decide(item: try orbItem(status: status), wasInserted: false,
                                                 now: Date(timeIntervalSinceReferenceDate: 6_000),
                                                 lastStreamPulseAt: nil)
            #expect(decision.pulse == nil, "status \(status) must not stream-pulse")
            #expect(decision.streamPulseAt == nil)
        }
    }

    // MARK: - Compact predicate extraction

    @Test func compactPredicateMatchesTheRowPresentationRule() throws {
        let activeByState = try compactItem(state: "running", status: "done")
        #expect(TimelineEntryPresentation.isCompactItem(activeByState))
        #expect(TimelineEntryPresentation.isActiveCompactItem(activeByState))
        #expect(TimelineEntryPresentation(item: activeByState, cwd: nil).kind == .compact)

        let activeByStatus = try compactItem(state: "done", status: "running", type: "marker")
        #expect(TimelineEntryPresentation.isCompactItem(activeByStatus))
        #expect(TimelineEntryPresentation.isActiveCompactItem(activeByStatus))

        let settled = try compactItem(state: "done", status: "done")
        #expect(TimelineEntryPresentation.isCompactItem(settled))
        #expect(!TimelineEntryPresentation.isActiveCompactItem(settled))

        // A `compact` wire kind rides only system/marker rows.
        let message = try compactItem(state: "running", status: "running", type: "message")
        #expect(!TimelineEntryPresentation.isCompactItem(message))
    }

    // MARK: - Tool-kind predicate extraction

    @Test func toolKindPredicateMatchesTheRowPresentationRule() throws {
        let tool = try orbItem(type: "tool", role: nil, status: "running")
        #expect(TimelineEntryPresentation.isToolKindItem(tool))
        #expect(TimelineEntryPresentation(item: tool, cwd: nil).kind == .tool)

        // Codex stamps file changes on artifact rows; the row still renders as
        // a tool row, so the predicate must accept it.
        let fileChange = try fileChangeArtifactItem(status: "running")
        #expect(TimelineEntryPresentation.isToolKindItem(fileChange))
        #expect(TimelineEntryPresentation(item: fileChange, cwd: nil).kind == .tool)

        let plainArtifact = try orbItem(type: "artifact", role: nil, status: "running")
        #expect(!TimelineEntryPresentation.isToolKindItem(plainArtifact))

        let message = try orbItem(status: "running")
        #expect(!TimelineEntryPresentation.isToolKindItem(message))
    }

    @Test func orbActivityTreatsCodexFileChangeRowsAsToolWork() throws {
        let http = TestHTTPTransport()
        let repo = repository(transport: http)
        let model = SessionChatModel(session: repo.session(id: "session"), repository: repo,
            attachments: .init(attachmentAPI: V2AttachmentAPI(transport: http)))
        model.timeline.presentOpening([
            try fileChangeArtifactItem(status: "running"),
            try orbItem(type: "reasoning", role: nil, status: "running"),
        ], pendingMessages: [])
        #expect(model.orbActivitySignals.hasActiveToolItem)
        #expect(model.orbActivitySignals.hasActiveReasoningItem)
        // The tool layer sits above the thinking layer: a live file change must
        // read as tool work even while reasoning rows are also running.
        #expect(model.orbActivity == .toolRunning)
    }

    // MARK: - Projection merge outcomes

    @Test func projectionMergeOutcomesReportInsertReplaceAndDrop() throws {
        let window = try [itemObject(id: "3", order: 3), itemObject(id: "4", order: 4)]
        var projection = V2SessionProjection(snapshot: try snapshot(items: window, hasMore: true), maximumItems: 5)

        let inserted = try projection.apply(event("timeline.item_created", seq: 11,
            payload: ["item": itemObject(id: "5", order: 5, seq: 11)]))
        #expect(inserted?.wasInserted == true)
        #expect(inserted?.item.id == "5")

        let replaced = try projection.apply(event("timeline.item_updated", seq: 12,
            payload: ["item": itemObject(id: "4", order: 4, revision: 2, seq: 12, text: "Streamed")]))
        #expect(replaced?.wasInserted == false)
        #expect(replaced?.item.id == "4")
        #expect(projection.data.items.first { $0.id == "4" }?.revision == 2)

        // Older rows outside the loaded window produce no outcome.
        let windowDrop = try projection.apply(event("timeline.item_created", seq: 13,
            payload: ["item": itemObject(id: "2", order: 2, seq: 13)]))
        #expect(windowDrop == nil)

        // A non-superseding revision produces no outcome.
        let staleDrop = try projection.apply(event("timeline.item_updated", seq: 14,
            payload: ["item": itemObject(id: "4", order: 4, revision: 1, seq: 14)]))
        #expect(staleDrop == nil)

        // Non-timeline frames never carry an outcome.
        let extensionFrame = try projection.apply(event("vendor.progress", seq: 15, payload: ["progress": 0.5]))
        #expect(extensionFrame == nil)
        #expect(projection.data.lastExtensionEvent?.type == "vendor.progress")
    }

    // MARK: - SessionChatModel collection

    @Test func chatModelOrbActivityRequiresFreshFactsAndReadsPresentedRows() throws {
        let http = TestHTTPTransport()
        let repo = repository(transport: http)
        let model = SessionChatModel(session: repo.session(id: "session"), repository: repo,
            attachments: .init(attachmentAPI: V2AttachmentAPI(transport: http)))

        var object = try fixtureObject("snapshot")
        var state = object["state"] as! [String: Any]
        state["status"] = "running"
        object["state"] = state
        // The shipped snapshot fixture carries an open, respondable interaction
        // notice, which correctly wins the resolver's first rule; this test
        // targets the layers below it, so the notice is cleared here (its
        // priority is pinned by `resolverWaitingForUserWinsFromBothEntries`).
        object["notices"] = []
        var data = V2SessionData(snapshot: try decode(object, as: V2SessionSnapshot.self))

        // Fresh facts land: the runtime status is read, and a running state
        // with nothing else live falls back to the scan.
        data.liveStateIsFresh = true
        model.session.update(V2SessionObservation(sessionId: "session", data: data, connection: .connected, error: nil),
            network: V2NetworkStatus())
        #expect(model.session.runtime.isFresh)
        #expect(model.orbActivitySignals.status == .running)
        #expect(model.orbActivity == .toolRunning)

        // A presented streaming assistant row turns the orb to writing.
        model.timeline.presentOpening([try orbItem(status: "running")], pendingMessages: [])
        #expect(model.orbActivitySignals.isStreamingAssistantText)
        #expect(model.orbActivity == .writing)

        // A stale projection keeps its state but withholds it from the orb.
        data.liveStateIsFresh = false
        model.session.update(V2SessionObservation(sessionId: "session", data: data, connection: .connected, error: nil),
            network: V2NetworkStatus())
        #expect(!model.session.runtime.isFresh)
        #expect(model.session.runtime.state?.status == .running)
        #expect(model.orbActivitySignals.status == nil)
    }

    // MARK: - Live receive-pulse wiring

    @Test func socketFrameRingsTheOrbPulse() async throws {
        let http = TestHTTPTransport(); let realtime = TestRealtimeAPI()
        let repo = repository(transport: http, realtime: realtime)
        defer { repo.reset() }
        let model = repo.session(id: "session")
        let connection = Task { await model.connect() }
        defer { connection.cancel() }
        try await eventually { model.connection == .connected }
        #expect(model.incomingPulse == nil)

        realtime.yield(try event("timeline.item_created", seq: 11,
            payload: ["item": liveItemObject(id: "reply", order: 2, seq: 11)]))
        try await eventually { model.incomingPulse != nil }
        #expect(model.incomingPulse?.strength == 1.0)
        try await eventually { model.timeline.count == 2 }
    }

    @Test func recoveryReplayNeverRingsTheOrbPulse() async throws {
        let http = TestHTTPTransport(); let realtime = TestRealtimeAPI()
        let replay = try event("timeline.item_created", seq: 11,
            payload: ["item": liveItemObject(id: "replayed", order: 2, seq: 11)])
        realtime.onRecover = {
            V2EventRecoveryResponse(events: [replay], nextCursor: "seq:11", snapshotRequired: false, serverTime: "")
        }
        let repo = repository(transport: http, realtime: realtime)
        defer { repo.reset() }
        let model = repo.session(id: "session")
        let connection = Task { await model.connect() }
        defer { connection.cancel() }
        try await eventually { model.connection == .connected }
        // The replayed row landed through the recovery path…
        try await eventually { model.timeline.count == 2 }
        // …and that path never touches the pulse.
        #expect(model.incomingPulse == nil)
    }

    @Test func pulseThrottleHoldsAcrossLiveFrames() async throws {
        let http = TestHTTPTransport(); let realtime = TestRealtimeAPI()
        let repo = repository(transport: http, realtime: realtime)
        defer { repo.reset() }
        let model = repo.session(id: "session")
        let connection = Task { await model.connect() }
        defer { connection.cancel() }
        try await eventually { model.connection == .connected }

        let anchor = Date(timeIntervalSinceReferenceDate: 9_000_000)
        var first = try event("timeline.item_updated", seq: 11,
            payload: ["item": liveItemObject(revision: 2, seq: 11)])
        first.receivedAt = anchor
        realtime.yield(first)
        try await eventually { model.incomingPulse != nil && model.timeline.first?.value.revision == 2 }
        let ring = try #require(model.incomingPulse)
        #expect(ring.strength == 0.3)

        var second = try event("timeline.item_updated", seq: 12,
            payload: ["item": liveItemObject(revision: 3, seq: 12)])
        second.receivedAt = anchor.addingTimeInterval(0.1)
        realtime.yield(second)
        try await eventually { model.timeline.first?.value.revision == 3 }
        // Inside the 250 ms window the update lands without a fresh pulse.
        #expect(model.incomingPulse?.id == ring.id)
        #expect(model.incomingPulse?.strength == 0.3)
    }
}

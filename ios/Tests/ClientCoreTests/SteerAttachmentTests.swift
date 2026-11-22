import Foundation
import Testing
@testable import ClientCore

/// Steering a draft that carries files (pp 2026-11-22).
///
/// The decision is a capability fact — `session.steer.parameters.attachments`
/// — never the runtime name: a runtime that declares it may take an
/// attachment draft into the running turn, and one that does not keeps the
/// queue as the only path for that draft. These cases pin the fact and the
/// composer gate that reads it.
@Suite @MainActor struct SteerAttachmentTests {
    private func capabilityJSON(_ id: String, parameters: [String: Any] = [:]) -> [String: Any] {
        [
            "allowed": true, "available": true, "capabilityId": id,
            "parameters": parameters, "runtime": "claude", "runtimeId": "rti_work",
            "scope": "runtime", "sessionId": NSNull(), "supported": true,
            "unavailableReason": NSNull(), "version": "1",
        ]
    }

    /// Pushes one authoritative live frame: a running turn whose steer
    /// capability carries the parameters under test.
    private func applyLive(_ model: V2SessionModel, steerParameters: [String: Any]) throws {
        var raw = try fixtureObject("snapshot")
        var state = raw["state"] as! [String: Any]
        state["status"] = V2RuntimeStatus.running.rawValue
        raw["state"] = state
        raw["effectiveCapabilities"] = [
            "capabilities": [
                capabilityJSON("session.steer", parameters: steerParameters),
                // The queue fallback needs the send capability's support and
                // permission (permitsQueuedSend), independent of availability.
                capabilityJSON("session.send_message"),
                // A long paste only becomes a file when the runtime can take
                // attachments at all (`canAttach`); without this fact the
                // conversion is a no-op and these cases would test nothing.
                capabilityJSON("runtime.attachment"),
            ],
            "revision": 10,
        ]
        var data = V2SessionData(snapshot: try decode(raw))
        data.liveStateIsFresh = true
        data.notices = []
        model.runtime.update(data, connection: .connected)
    }

    private func makeChat(_ http: TestHTTPTransport, _ repo: V2SessionRepository,
                          _ model: V2SessionModel) -> SessionChatModel {
        SessionChatModel(session: model, repository: repo,
            attachments: .init(attachmentAPI: V2AttachmentAPI(transport: http)))
    }

    @Test func gateFollowsTheDeclaredCapabilityFact() {
        func capability(_ parameters: JSONValue, supported: Bool = true,
                        allowed: Bool = true) -> V2RuntimeCapability {
            V2RuntimeCapability(
                capabilityId: "session.steer", version: "1", scope: .runtime,
                runtime: "claude", sessionId: nil, supported: supported,
                available: true, allowed: allowed, unavailableReason: nil,
                parameters: parameters)
        }

        #expect(SteerAttachmentGate.allows(
            capability(.object(["attachments": .bool(true)]))))
        // Absent, false, and non-bool all read as "not declared"; the runtime
        // keeps the queue rather than the client guessing.
        #expect(!SteerAttachmentGate.allows(capability(.object([:]))))
        #expect(!SteerAttachmentGate.allows(
            capability(.object(["attachments": .bool(false)]))))
        #expect(!SteerAttachmentGate.allows(
            capability(.object(["attachments": .string("yes")]))))
        // A capability the runtime does not support or allow never opens the
        // gate, even with the fact present.
        #expect(!SteerAttachmentGate.allows(
            capability(.object(["attachments": .bool(true)]), supported: false)))
        #expect(!SteerAttachmentGate.allows(
            capability(.object(["attachments": .bool(true)]), allowed: false)))
        #expect(!SteerAttachmentGate.allows(nil))
    }

    @Test func chatAcceptsAttachmentSteerOnlyWhenDeclared() throws {
        let http = TestHTTPTransport()
        let repo = repository(transport: http)
        defer { repo.reset() }
        let model = repo.session(id: "session")
        let chat = makeChat(http, repo, model)

        // Text alone steers for any runtime offering session.steer.
        try applyLive(model, steerParameters: [:])
        #expect(chat.canSteerSend)

        // The same running turn, now with a file in the draft: a runtime that
        // does not declare attachment steering keeps the queue.
        model.composer.attachments = [
            ChatAttachment(name: "shot.png", data: Data([0x89, 0x50, 0x4E, 0x47]),
                           mediaType: "image/png"),
        ]
        #expect(!chat.canSteerSend)

        try applyLive(model, steerParameters: ["attachments": true])
        #expect(chat.canSteerSend)
    }

    @Test func longPasteSteersAsAFileWhenTheRuntimeAcceptsAttachments() async throws {
        let http = TestHTTPTransport()
        let repo = repository(transport: http)
        defer { repo.reset() }
        let model = repo.session(id: "session")
        let chat = makeChat(http, repo, model)
        try applyLive(model, steerParameters: ["attachments": true])

        model.composer.text = String(repeating: "log line\n", count: 300)

        await chat.steerComposer()

        // The paste became a file before the wire: no giant bubble, no giant
        // steer text.
        #expect(model.composer.text.isEmpty)
        #expect(model.composer.attachments.count == 1)
        #expect(model.composer.attachments.first?.mediaType == "text/plain")
        #expect(model.composer.attachments.first?.name.hasPrefix("long-message-") == true)
        #expect(http.uploads.count == 1)
        let steer = try #require(http.calls.last { $0.path.hasSuffix("/runtime/steer") })
        #expect(steer.body?["content"]?.stringValue == "")
        #expect(steer.body?["attachments"]?.arrayValue?.first?["fileId"]?.stringValue == "file")
        let pending = try #require(model.pendingMessages.first)
        #expect(pending.isSteer)
        #expect(pending.attachmentIDs == ["file"])
    }

    @Test func longPasteFallsBackToTheQueueWithoutTheCapability() async throws {
        let http = TestHTTPTransport()
        let repo = repository(transport: http)
        defer { repo.reset() }
        let model = repo.session(id: "session")
        let chat = makeChat(http, repo, model)
        try applyLive(model, steerParameters: [:])

        model.composer.text = String(repeating: "log line\n", count: 300)

        await chat.steerComposer()

        // No attachment steering: the queue keeps the height protection (the
        // paste is filed there instead of riding the turn as one bubble).
        #expect(model.sendQueue.items.count == 1)
        #expect(model.sendQueue.items.first?.content.isEmpty == true)
        #expect(model.sendQueue.items.first?.attachments.count == 1)
        #expect(http.calls.allSatisfy { !$0.path.hasSuffix("/runtime/steer") })
    }
}

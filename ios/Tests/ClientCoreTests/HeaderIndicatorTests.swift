import Foundation
import Testing
@testable import ClientCore

/// Locks the header indicator contract after the "正在同步会话状态…" copy
/// retired: the not-ready state is always the copy-free glow sweep, and every
/// other status keeps its existing copy and indicator kind.
@Suite struct HeaderIndicatorTests {
    @Test func notReadyStateIsAlwaysTheCopyFreeGlowSweep() throws {
        let chat = makeChat()
        defer { chat.repository.reset() }

        // The sweep is model-side: the case keeps its name (`syncing` names
        // the logical state), but it must carry no copy and no spinner.
        #expect(ChatHeaderStatus.syncing.title == "")
        #expect(ChatHeaderStatus.syncing.detail == "")
        #expect(ChatHeaderStatus.syncing.isGlow)
        #expect(!ChatHeaderStatus.syncing.isProgress)

        // Stale live facts (resume/restore window) under every connection
        // state is one and the same glow state, regardless of runtime status.
        for connection: V2SessionConnectionState in [.connected, .connecting, .reconnecting, .inactive, .failed("boom")] {
            for status: V2RuntimeStatus in [.idle, .running, .waitingApproval, .stopping] {
                try update(chat, status: status, fresh: false, connection: connection)
                #expect(chat.headerStatus == .syncing)
                #expect(chat.headerStatus?.isGlow == true)
                #expect(chat.headerStatus?.title == "")
                #expect(chat.headerStatus?.detail == "")
                #expect(chat.headerStatus?.isProgress == false)
            }
        }

        // A rebuilt connection is the same not-ready family even when the
        // cached live facts still read fresh.
        try update(chat, status: .idle, fresh: true, connection: .reconnecting)
        #expect(chat.headerStatus == .syncing)
        #expect(chat.headerStatus?.isGlow == true)
        #expect(chat.headerStatus?.title == "")
    }

    @Test func readyStatesDoNotShowTheGlow() throws {
        let chat = makeChat()
        defer { chat.repository.reset() }

        try update(chat, status: .idle)
        #expect(chat.headerStatus == nil)
        try update(chat, status: .running)
        #expect(chat.headerStatus == nil)
        // Connecting alone is not a not-ready display trigger (unchanged).
        try update(chat, status: .idle, connection: .connecting)
        #expect(chat.headerStatus == nil)
    }

    /// The rebuilt-socket window shows the sweep; a completed rebuild must
    /// stop it. After reconnecting → connected (facts still fresh) no glow may
    /// remain, even while the runtime is busy.
    @Test func aCompletedConnectionRebuildStopsTheGlow() throws {
        let chat = makeChat()
        defer { chat.repository.reset() }

        try update(chat, status: .running, fresh: true, connection: .reconnecting)
        #expect(chat.headerStatus == .syncing)
        #expect(chat.headerStatus?.isGlow == true)
        #expect(chat.headerStatus?.title == "")
        #expect(chat.headerStatus?.detail == "")

        // reconnecting → connected with fresh facts: the sweep must stop.
        try update(chat, status: .running, fresh: true, connection: .connected)
        #expect(chat.headerStatus == nil)
        #expect(chat.headerStatus?.isGlow != true)
        #expect(chat.headerStatus != .syncing)

        // The stop belongs to the transition, not to a one-way latch: a later
        // rebuild shows the sweep again.
        try update(chat, status: .running, fresh: true, connection: .reconnecting)
        #expect(chat.headerStatus == .syncing)
        #expect(chat.headerStatus?.isGlow == true)
    }

    @Test func anActionErrorStillSuppressesTheIndicatorThenRecovers() throws {
        let chat = makeChat()
        defer { chat.repository.reset() }

        try update(chat, fresh: false,
            failure: V2ClientFailure(kind: .invalidResponse, message: "Invalid data"))
        #expect(chat.headerStatus == nil)
        try update(chat, fresh: false)
        #expect(chat.headerStatus == .syncing)
    }

    @Test func terminalOfflineStatesKeepTheirResultCopy() throws {
        let chat = makeChat()
        defer { chat.repository.reset() }

        try update(chat, fresh: false, networkOffline: true)
        #expect(chat.headerStatus == .networkOffline)
        #expect(chat.headerStatus?.isGlow == false)
        #expect(chat.headerStatus?.title == "网络已断开")
        #expect(chat.headerStatus?.detail == "网络已断开，草稿和已加载的消息已保留")

        try update(chat, fresh: false, deviceOffline: true)
        #expect(chat.headerStatus == .deviceOffline)
        #expect(chat.headerStatus?.isGlow == false)
        #expect(chat.headerStatus?.title == "设备离线")
        #expect(chat.headerStatus?.detail == "设备离线，等待重新连接")

        // Offline outranks the not-ready family, with stale or fresh facts
        // alike (unchanged).
        try update(chat, fresh: false, connection: .offline)
        #expect(chat.headerStatus == .networkOffline)
        try update(chat, fresh: true, connection: .offline)
        #expect(chat.headerStatus == .networkOffline)
    }

    @Test func workingWaitingAndStoppingIndicatorsAreUnchanged() throws {
        let chat = makeChat()
        defer { chat.repository.reset() }

        // `headerStatus` never produces `.working`; its face stays as-is.
        #expect(ChatHeaderStatus.working.title == "正在处理任务")
        #expect(ChatHeaderStatus.working.isGlow == false)
        #expect(ChatHeaderStatus.working.isProgress)

        try update(chat, status: .stopping)
        #expect(chat.headerStatus == .stopping)
        #expect(chat.headerStatus?.title == "正在停止…")
        #expect(chat.headerStatus?.isGlow == false)
        #expect(chat.headerStatus?.isProgress == true)

        try update(chat, status: .waitingApproval)
        #expect(chat.headerStatus == .waitingForResponse)
        #expect(chat.headerStatus?.title == "等待回应")
        #expect(chat.headerStatus?.isGlow == false)
        #expect(chat.headerStatus?.isProgress == false)

        try update(chat, status: .blocked, reason: "等待设备上的登录流程")
        #expect(chat.headerStatus == .information("等待设备上的登录流程"))
        #expect(chat.headerStatus?.title == "等待设备上的登录流程")
    }

    private func makeChat() -> SessionChatModel {
        let http = TestHTTPTransport()
        let repo = repository(transport: http)
        return SessionChatModel(session: repo.session(id: "session"), repository: repo,
            attachments: .init(attachmentAPI: V2AttachmentAPI(transport: http)))
    }

    private func update(_ chat: SessionChatModel, status: V2RuntimeStatus = .idle, fresh: Bool = true,
        networkOffline: Bool = false, deviceOffline: Bool = false,
        connection: V2SessionConnectionState = .connected, failure: V2ClientFailure? = nil, reason: String? = nil) throws {
        var raw = try fixtureObject("snapshot")
        var state = raw["state"] as! [String: Any]
        state["status"] = status.rawValue
        state["statusReason"] = reason
        raw["state"] = state
        var meta = raw["session"] as! [String: Any]
        meta["connectorStatus"] = deviceOffline ? "offline" : "online"
        raw["session"] = meta
        var data = V2SessionData(snapshot: try decode(raw))
        data.liveStateIsFresh = fresh
        data.notices = []
        chat.session.update(V2SessionObservation(sessionId: "session", data: data, connection: connection, error: failure),
            network: V2NetworkStatus(availability: networkOffline ? .offline : .online))
    }
}

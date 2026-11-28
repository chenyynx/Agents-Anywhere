import Foundation

nonisolated enum V2RealtimeScope: Hashable {
    case dashboard
    case session(V2SessionID)
    case phone
}

nonisolated struct V2WebSocketTicketRequest: Encodable, Hashable {
    let clientId: String
    let scope: V2WebSocketTicketScope
}

nonisolated struct V2WebSocketTicketScope: Encodable, Hashable {
    let sessionId: V2SessionID?
    let dashboard: Bool
    let phone: Bool

    init(scope: V2RealtimeScope) {
        switch scope {
        case .dashboard:
            sessionId = nil
            dashboard = true
            phone = false
        case let .session(sessionId):
            self.sessionId = sessionId
            dashboard = false
            phone = false
        case .phone:
            sessionId = nil
            dashboard = false
            phone = true
        }
    }
}

nonisolated struct V2WebSocketTicket: Decodable, Hashable {
    let ticket: String
    let expiresAt: String
    let serverTime: String
}

nonisolated struct V2SessionEvent: Decodable, Identifiable, Hashable {
    let protocolVersion: String
    let eventId: String
    let sequence: Int
    let cursor: String
    let type: String
    let sessionId: V2SessionID
    let emittedAt: String
    let payload: JSONValue
    /// Client receipt time, excluded from the wire contract. Used to order refresh barriers.
    var receivedAt: Date = Date()

    enum CodingKeys: String, CodingKey {
        case protocolVersion, eventId, sequence, cursor, type, sessionId, emittedAt, payload
    }

    var id: String { eventId }

    var isLiveProjection: Bool {
        ["session.meta.updated", "runtime.state.updated", "runtime.capability.updated", "runtime.catalog.updated"].contains(type)
    }
}

nonisolated struct V2EventRecoveryResponse: Decodable, Hashable {
    let events: [V2SessionEvent]
    let nextCursor: String
    let snapshotRequired: Bool
    let serverTime: String
}

/// One server-decided local-notification record. The server derives these
/// from the session projection (background work, approvals, unread); the
/// client only renders and dedupes them.
nonisolated struct V2DashboardNotification: Decodable, Hashable, Identifiable {
    let id: String
    let sessionId: String
    let type: String
    let title: String
    let preview: String?
    let summary: String?
    let deepLink: String?
    let createdAt: String?
}

nonisolated struct V2DashboardNotificationsResponse: Decodable, Hashable {
    let notifications: [V2DashboardNotification]
    /// Present on servers that moved the background keep-alive decision here.
    let sessions: [V2SessionMeta]?
    let serverTime: String
}

nonisolated struct V2DashboardSnapshot: Decodable, Hashable {
    let type: String
    let connectors: [V2Connector]
    let projects: [V2Project]
    let sessionPages: V2DashboardSessionPages
    let sessions: [V2SessionMeta]
    /// Optional so a build talking to an older server still decodes.
    let notifications: [V2DashboardNotification]?
    let serverTime: String
}

import Foundation

struct ChatSidebarDevice: Identifiable, Equatable {
    let id: V2ConnectorID
    let name: String
    let presence: V2ConnectorPresence

    init(connector: V2Connector) {
        id = connector.id
        name = connector.name
        presence = connector.status
    }
}

struct ChatSidebarSession: Identifiable, Equatable {
    let id: V2SessionID
    let title: String?
    let connectorId: V2ConnectorID
    let projectId: String?
    let cwd: String?
    let runtime: String
    let runtimeType: String?
    let status: V2RuntimeStatus
    let unread: Bool
    let archived: Bool
    let pinned: Bool
    let presentation: SessionSidebarPresentation
    /// The sidebar's activity time, resolved in the same priority the list
    /// sorts by: the wire's `sortAt` first, then `lastActivityAt`, then the
    /// session's creation time. Raw ISO string; formatted where it is shown.
    let lastActivityAt: String?

    /// The long-press menu's one-line activity time, or nil while the session
    /// carries no timestamp at all.
    var activityTimeText: String? {
        guard let lastActivityAt, let date = ChatTimestamp.parse(lastActivityAt) else {
            return nil
        }
        return "\(String(localized: "Last activity")) \(ChatTimestamp.string(date))"
    }

    init(session: V2SessionMeta) {
        id = session.id
        title = session.title
        connectorId = session.connectorId
        projectId = session.projectId
        cwd = session.cwd
        runtime = session.runtime
        runtimeType = session.runtimeType
        status = session.status
        unread = session.unread
        archived = session.archived
        pinned = session.pinned
        presentation = SessionSidebarPresentation(session)
        lastActivityAt = [session.sortAt, session.lastActivityAt, session.createdAt]
            .compactMap { $0 }
            .first { !$0.isEmpty }
    }
}

struct ChatSidebarAccount: Equatable {
    let displayName: String
    let avatarSource: AccountAvatarImageSource?

    init(me: AuthMe, avatarSource: AccountAvatarImageSource?) {
        displayName = me.accountLabel
        self.avatarSource = avatarSource
    }
}

import Foundation

/// One destination of the bottom tab bar.
///
/// A plain `String`-backed enum so the persisted shell state stays readable
/// and an unknown future tab decodes as a failure (the store then falls back
/// to the default model) instead of silently selecting the wrong pane.
///
/// The old `.devices` tab is gone: the Chat tab owns the device list at its
/// root now (2026-11-28). Snapshots that still say `.devices` are migrated by
/// `V2RestorationStore`.
nonisolated enum ShellTab: String, Codable, Equatable, CaseIterable, Sendable {
    case chat
    case wiki
    case files
    case artifacts
}

/// The conversation at the bottom of the Chat tab's stack.
nonisolated enum ChatTabRoot: Codable, Equatable, Sendable {
    case session(V2SessionID)
    case newSession(workspace: String?)
}

/// The Chat tab's two peer modes. `查看全部` switches to the list mode; it
/// does not push the list over the conversation (that stacked the drawer
/// close and a NavigationStack push into two visible motions).
nonisolated enum ChatTabMode: Codable, Equatable, Sendable {
    case conversation(ChatTabRoot)
    case list
}

/// One page pushed above the list inside the list mode. Every row in the
/// list pushes; the system back button returns to the list.
nonisolated enum ChatTabRoute: Codable, Equatable, Hashable, Sendable {
    case session(V2SessionID)
    case newSession(workspace: String?)
}

/// Which page the Chat tab opens on at launch. Stored outside the pane
/// snapshot: it is a user preference, not navigation state.
nonisolated enum ShellStartPage: String, Codable, CaseIterable, Sendable {
    case auto
    case chat
    case list

    static let storageKey = "aa.shell.startPage"

    static func current(_ defaults: UserDefaults = .standard) -> ShellStartPage {
        ShellStartPage(rawValue: defaults.string(forKey: storageKey) ?? "") ?? .auto
    }

    var title: String {
        switch self {
        case .auto: return String(localized: "自动")
        case .chat: return String(localized: "会话")
        case .list: return String(localized: "列表")
        }
    }
}

/// Pure navigation state for the tab shell: which tab is selected, which of
/// the Chat tab's two modes is visible, and the pages pushed above the list.
///
/// The two modes are peers: `查看全部` switches to the list in place (no
/// NavigationStack push), so only the drawer's close animates. Every row in
/// the list pushes a session/compose page above the list.
nonisolated struct ShellPanesModel: Codable, Equatable, Sendable {
    var selectedTab: ShellTab = .chat
    var chatMode: ChatTabMode = .conversation(.newSession(workspace: nil))
    /// Pushes above the list while `chatMode == .list`; empty is the list root.
    var listPath: [ChatTabRoute] = []
    /// The device whose page the list shows. Nil means "pick the first online
    /// connector".
    var chatDevice: V2ConnectorID?
    /// The last conversation opened. The `chat` start page reopens it.
    var lastSessionID: V2SessionID?

    /// The session whose timeline is actually on screen.
    ///
    /// The list root names no session; a session pushed above the list and a
    /// conversation root do.
    func visibleSessionId(obscured: Bool) -> V2SessionID? {
        guard !obscured, selectedTab == .chat else { return nil }
        switch chatMode {
        case .list:
            guard case let .session(id)? = listPath.last else { return nil }
            return id
        case let .conversation(root):
            guard case let .session(id) = root else { return nil }
            return id
        }
    }

    var isListMode: Bool {
        if case .list = chatMode { return true }
        return false
    }

    /// Sidebar session rows replace the conversation and clear the list
    /// stack, so the reader lands on the conversation (no push).
    mutating func openChatSession(_ id: V2SessionID) {
        selectedTab = .chat
        chatMode = .conversation(.session(id))
        listPath = []
        lastSessionID = id
    }

    /// Sidebar/global compose replaces the conversation.
    mutating func startNewChat(workspace: String? = nil) {
        selectedTab = .chat
        chatMode = .conversation(.newSession(workspace: workspace))
        listPath = []
    }

    /// "查看全部": switch to the list mode. The list root appears in place;
    /// only the drawer's close animates.
    mutating func showList(device: V2ConnectorID? = nil) {
        selectedTab = .chat
        if let device { chatDevice = device }
        chatMode = .list
        listPath = []
    }

    mutating func openDevice(_ id: V2ConnectorID) {
        selectedTab = .chat
        chatDevice = id
        chatMode = .list
        listPath = []
    }

    /// A list row's session: always a push above the list.
    mutating func pushChatSession(_ id: V2SessionID) {
        selectedTab = .chat
        if case .list = chatMode {
            listPath.append(.session(id))
        } else {
            chatMode = .conversation(.session(id))
            listPath = []
        }
        lastSessionID = id
    }

    /// A list row's compose page: always a push above the list.
    mutating func pushNewChat(workspace: String? = nil) {
        selectedTab = .chat
        if case .list = chatMode {
            listPath.append(.newSession(workspace: workspace))
        } else {
            chatMode = .conversation(.newSession(workspace: workspace))
            listPath = []
        }
    }

    /// The created session replaces the compose page it was pushed from; the
    /// back button then returns to the list.
    mutating func finishNewChat(_ id: V2SessionID) {
        lastSessionID = id
        if case .newSession? = listPath.last {
            listPath.removeLast()
            listPath.append(.session(id))
        } else {
            openChatSession(id)
        }
    }

    /// Applies the user's launch preference. `auto` keeps the restored state.
    mutating func applyStartPage(_ page: ShellStartPage) {
        selectedTab = .chat
        switch page {
        case .auto:
            return
        case .list:
            chatMode = .list
            listPath = []
        case .chat:
            if let id = lastSessionID {
                chatMode = .conversation(.session(id))
            } else {
                chatMode = .conversation(.newSession(workspace: nil))
            }
            listPath = []
        }
    }
}

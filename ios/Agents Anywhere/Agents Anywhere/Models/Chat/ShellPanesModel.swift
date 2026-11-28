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
    case artifacts
}

/// The conversation at the bottom of the Chat tab's stack.
nonisolated enum ChatTabRoot: Codable, Equatable, Sendable {
    case session(V2SessionID)
    case newSession(workspace: String?)
}

/// One page pushed above the root conversation. Everything opened from the
/// list is a push; the system back button walks back to the list and then to
/// the conversation.
nonisolated enum ChatTabRoute: Codable, Equatable, Hashable, Sendable {
    case list
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

/// Pure navigation state for the tab shell: which tab is selected, the
/// conversation at the Chat tab's root, and the pages pushed above it.
///
/// The root is always a conversation (a session or the compose page). The
/// list is pushed by the sidebar's "查看全部"; a list row pushes the session
/// or compose page above the list. The sidebar's session rows replace the
/// root instead of pushing.
nonisolated struct ShellPanesModel: Codable, Equatable, Sendable {
    var selectedTab: ShellTab = .chat
    var chatRoot: ChatTabRoot = .newSession(workspace: nil)
    var chatPath: [ChatTabRoute] = []
    /// The device whose page the pushed list shows. Nil means "pick the
    /// first online connector".
    var chatDevice: V2ConnectorID?
    /// The last conversation opened. The `chat` start page reopens it.
    var lastSessionID: V2SessionID?

    /// The session whose timeline is actually on screen.
    ///
    /// With the list or a compose page on top, the root conversation is
    /// covered and names no visible session.
    func visibleSessionId(obscured: Bool) -> V2SessionID? {
        guard !obscured, selectedTab == .chat else { return nil }
        if let last = chatPath.last {
            guard case let .session(id) = last else { return nil }
            return id
        }
        guard case let .session(id) = chatRoot else { return nil }
        return id
    }

    var isListOnTop: Bool {
        guard case .list? = chatPath.last else { return false }
        return true
    }

    /// Sidebar session rows replace the root conversation and clear the
    /// pushed stack, so the reader lands on the conversation (no push).
    mutating func openChatSession(_ id: V2SessionID) {
        selectedTab = .chat
        chatRoot = .session(id)
        chatPath = []
        lastSessionID = id
    }

    /// Sidebar/global compose replaces the root conversation.
    mutating func startNewChat(workspace: String? = nil) {
        selectedTab = .chat
        chatRoot = .newSession(workspace: workspace)
        chatPath = []
    }

    /// "查看全部": push the list above the root. A list already in the stack
    /// is reused (a pushed session above it is popped back to the list).
    mutating func showList(device: V2ConnectorID? = nil) {
        selectedTab = .chat
        if let device { chatDevice = device }
        chatPath = [.list]
    }

    mutating func openDevice(_ id: V2ConnectorID) {
        selectedTab = .chat
        chatDevice = id
        chatPath = [.list]
    }

    /// A list row's session: always a push above the list.
    mutating func pushChatSession(_ id: V2SessionID) {
        selectedTab = .chat
        lastSessionID = id
        if case .list? = chatPath.last {
            chatPath.append(.session(id))
        } else {
            chatRoot = .session(id)
            chatPath = [.list]
        }
    }

    /// A list row's compose page: always a push above the list.
    mutating func pushNewChat(workspace: String? = nil) {
        selectedTab = .chat
        if case .list? = chatPath.last {
            chatPath.append(.newSession(workspace: workspace))
        } else {
            chatRoot = .newSession(workspace: workspace)
            chatPath = [.list]
        }
    }

    /// The created session replaces the compose page it was pushed from;
    /// the back button then returns to the list.
    mutating func finishNewChat(_ id: V2SessionID) {
        lastSessionID = id
        if case .newSession? = chatPath.last {
            chatPath.removeLast()
            chatPath.append(.session(id))
        } else {
            openChatSession(id)
        }
    }

    /// Applies the user's launch preference. `auto` keeps the restored stack.
    mutating func applyStartPage(_ page: ShellStartPage) {
        selectedTab = .chat
        switch page {
        case .auto:
            return
        case .list:
            chatPath = [.list]
        case .chat:
            chatPath = []
            if let id = lastSessionID {
                chatRoot = .session(id)
            }
        }
    }
}

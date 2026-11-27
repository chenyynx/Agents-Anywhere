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

/// One entry above the Chat tab's list root.
///
/// The interaction is the old Devices tab's: the device page is the root,
/// a session is pushed with the system back button. `.device` is kept for
/// snapshots written before the device page became the root.
nonisolated enum ChatTabRoute: Codable, Equatable, Hashable, Sendable {
    case device(V2ConnectorID)
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

/// Pure navigation state for the tab shell: which tab is selected and where
/// the Chat tab currently stands.
///
/// Lives in the model layer (Foundation only) so the rules the shell UI has
/// to honour — one visible session at a time, a device list under a session
/// stack — are unit-testable without SwiftUI. Persistence is handled by
/// `V2RestorationStore.panes(in:)` / `save(panes:in:)`.
nonisolated struct ShellPanesModel: Codable, Equatable, Sendable {
    var selectedTab: ShellTab = .chat
    /// Empty means the device page (list mode) is the visible page.
    var chatPath: [ChatTabRoute] = []
    /// The device whose page is the list root. Nil means "pick the first
    /// online connector" (a restored account may not have loaded any
    /// connectors yet).
    var chatDevice: V2ConnectorID?
    /// The last conversation opened. The `chat` start page reopens it; it is
    /// separate from `chatPath` because the reader may be on the list now.
    var lastSessionID: V2SessionID?

    /// The session whose timeline is actually on screen.
    ///
    /// `obscured` covers the shell being covered by a modal/backgrounding:
    /// a hidden pane must never claim a live-session identity (background
    /// notifications and reconnect handling key off this answer).
    func visibleSessionId(obscured: Bool) -> V2SessionID? {
        guard !obscured, selectedTab == .chat,
              case let .session(id)? = chatPath.last else { return nil }
        return id
    }

    var isListMode: Bool { chatPath.isEmpty }

    /// Opens an existing session: the list stays the stack root and the
    /// session is pushed above it, so the system back button returns to the
    /// list (the old Devices-tab interaction).
    mutating func openChatSession(_ id: V2SessionID) {
        selectedTab = .chat
        chatPath = [.session(id)]
        lastSessionID = id
    }

    /// Opens the compose page above the list root.
    mutating func startNewChat(workspace: String? = nil) {
        selectedTab = .chat
        chatPath = [.newSession(workspace: workspace)]
    }

    /// Pops everything back to the list root.
    mutating func showList(device: V2ConnectorID? = nil) {
        selectedTab = .chat
        if let device { chatDevice = device }
        chatPath = []
    }

    /// Roots the list on a connector. A different device gets a fresh stack
    /// rather than reusing the previous device's drill-down.
    mutating func openDevice(_ id: V2ConnectorID) {
        selectedTab = .chat
        chatDevice = id
        chatPath = []
    }

    mutating func pushChatRoute(_ route: ChatTabRoute) {
        selectedTab = .chat
        if case let .session(id) = route { lastSessionID = id }
        guard chatPath.last != route else { return }
        chatPath.append(route)
    }

    mutating func popChat() {
        guard !chatPath.isEmpty else { return }
        chatPath.removeLast()
    }

    /// Applies the user's launch preference. `auto` keeps whatever the
    /// restoration store produced; the other two override the mode once, at
    /// launch, and never on an in-session tab switch.
    mutating func applyStartPage(_ page: ShellStartPage) {
        switch page {
        case .auto:
            return
        case .list:
            selectedTab = .chat
            chatPath = []
        case .chat:
            selectedTab = .chat
            if let id = lastSessionID {
                chatPath = [.session(id)]
            } else {
                chatPath = []
            }
        }
    }
}

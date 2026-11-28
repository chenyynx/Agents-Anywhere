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

/// What the merged Chat tab shows. The two modes are peers: opening a
/// session replaces the list on screen instead of pushing above it, so there
/// is no back button between them. The only entry from a conversation to the
/// list is the sidebar's "查看全部".
nonisolated enum ChatTabMode: Codable, Equatable, Sendable {
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

/// Pure navigation state for the tab shell: which tab is selected and which
/// of the Chat tab's two modes is visible.
///
/// Lives in the model layer (Foundation only) so the rules the shell UI has
/// to honour — one visible session at a time, a list mode that is not a
/// navigation parent — are unit-testable without SwiftUI. Persistence is
/// handled by `V2RestorationStore.panes(in:)` / `save(panes:in:)`.
nonisolated struct ShellPanesModel: Codable, Equatable, Sendable {
    var selectedTab: ShellTab = .chat
    var chatTab: ChatTabMode = .list
    /// The device whose page the list mode shows. Nil means "pick the first
    /// online connector" (a restored account may not have loaded any
    /// connectors yet).
    var chatDevice: V2ConnectorID?
    /// The last conversation opened. The `chat` start page reopens it; it is
    /// separate from `chatTab` because the reader may be on the list now.
    var lastSessionID: V2SessionID?

    /// The session whose timeline is actually on screen.
    ///
    /// `obscured` covers the shell being covered by a modal/backgrounding:
    /// a hidden pane must never claim a live-session identity (background
    /// notifications and reconnect handling key off this answer).
    func visibleSessionId(obscured: Bool) -> V2SessionID? {
        guard !obscured, selectedTab == .chat,
              case let .session(id) = chatTab else { return nil }
        return id
    }

    var isListMode: Bool {
        if case .list = chatTab { return true }
        return false
    }

    /// Switches to the conversation mode. The list page is replaced, not
    /// left underneath: there is no back button between the two modes.
    mutating func openChatSession(_ id: V2SessionID) {
        selectedTab = .chat
        chatTab = .session(id)
        lastSessionID = id
    }

    mutating func startNewChat(workspace: String? = nil) {
        selectedTab = .chat
        chatTab = .newSession(workspace: workspace)
    }

    /// Switches to the list mode. Reached from the sidebar's "查看全部" or a
    /// device row, never from a navigation back button.
    mutating func showList(device: V2ConnectorID? = nil) {
        selectedTab = .chat
        if let device { chatDevice = device }
        chatTab = .list
    }

    mutating func openDevice(_ id: V2ConnectorID) {
        selectedTab = .chat
        chatDevice = id
        chatTab = .list
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
            chatTab = .list
        case .chat:
            selectedTab = .chat
            if let id = lastSessionID {
                chatTab = .session(id)
            } else {
                chatTab = .list
            }
        }
    }
}

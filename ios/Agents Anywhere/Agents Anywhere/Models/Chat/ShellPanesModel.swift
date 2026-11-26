import Foundation

/// One destination of the bottom tab bar.
///
/// A plain `String`-backed enum so the persisted shell state stays readable
/// and an unknown future tab decodes as a failure (the store then falls back
/// to the default model) instead of silently selecting the wrong pane.
nonisolated enum ShellTab: String, Codable, Equatable, CaseIterable, Sendable {
    case chat
    case devices
    case wiki
    case artifacts
}

/// What the Chat tab shows at its root.
///
/// Chat keeps its own root beside the device stack: switching to Devices and
/// back must return to the same chat (or the compose-a-new-session screen)
/// without replaying navigation.
nonisolated enum ShellChatRoot: Codable, Equatable, Sendable {
    case newSession
    case session(V2SessionID)
}

/// One entry of the Devices tab's navigation stack.
///
/// Resetting the stack on a device is deliberate (the user picked a new
/// device, not a new level under the old one), so the stack only grows and
/// shrinks through `ShellPanesModel`'s mutators.
nonisolated enum ShellDevicesRoute: Codable, Equatable, Hashable, Sendable {
    case device(V2ConnectorID)
    case session(V2SessionID)
}

/// Pure navigation state for the tab shell: which tab is selected, what the
/// Chat tab's root is and where the Devices drill-down currently sits.
///
/// Lives in the model layer (Foundation only) so the rules the shell UI has
/// to honour — one visible session at a time, a device stack independent of
/// the chat root — are unit-testable without SwiftUI. Persistence is handled
/// by `V2RestorationStore.panes(in:)` / `save(panes:in:)`.
nonisolated struct ShellPanesModel: Codable, Equatable, Sendable {
    var selectedTab: ShellTab = .chat
    var chatRoot: ShellChatRoot = .newSession
    /// The device whose page is the Devices tab's root. Nil means "pick the
    /// first online connector" (a restored account may not have loaded any
    /// connectors yet).
    var devicesDevice: V2ConnectorID?
    /// The session drill-down above the device page. `.device` is kept in the
    /// route enum for old snapshots and is lifted into `devicesDevice` on
    /// restore.
    var devicesPath: [ShellDevicesRoute] = []

    /// The session whose timeline is actually on screen.
    ///
    /// `obscured` covers the shell being covered by a modal/backgrounding:
    /// a hidden pane must never claim a live-session identity (background
    /// notifications and reconnect handling key off this answer).
    func visibleSessionId(obscured: Bool) -> V2SessionID? {
        guard !obscured else { return nil }
        switch selectedTab {
        case .chat:
            guard case .session(let id) = chatRoot else { return nil }
            return id
        case .devices:
            guard let last = devicesPath.last, case .session(let id) = last else { return nil }
            return id
        case .wiki, .artifacts:
            return nil
        }
    }

    /// Opens an existing session in the Chat tab. The Devices stack is left
    /// untouched: both tabs may show the same session (each page is mounted
    /// only while its tab is selected).
    mutating func openChatSession(_ id: V2SessionID) {
        selectedTab = .chat
        chatRoot = .session(id)
    }

    /// Returns the Chat tab to the compose-a-new-session screen.
    mutating func startNewChat() {
        selectedTab = .chat
        chatRoot = .newSession
    }

    /// Roots the Devices tab on a connector. The device page itself is the
    /// tab root now; a different device gets a fresh session drill-down rather
    /// than reusing the previous device's stack.
    mutating func openDevice(_ id: V2ConnectorID) {
        selectedTab = .devices
        devicesDevice = id
        devicesPath = []
    }

    /// Snapshots written before the device page became the tab root stored
    /// the device as the first path element. Lift it into `devicesDevice` and
    /// keep the session drill-down above it.
    mutating func normalizeRestoredDeviceRoot() {
        if case let .device(id)? = devicesPath.first {
            if devicesDevice == nil { devicesDevice = id }
            devicesPath.removeFirst()
        }
        devicesPath.removeAll { route in
            if case .device = route { return true }
            return false
        }
    }

    /// Drills from the device into one of its sessions. The Chat tab keeps
    /// whatever it was showing; page mounting, not this value, enforces the
    /// one-live-page-at-a-time rule.
    mutating func pushDeviceSession(_ id: V2SessionID) {
        guard devicesPath.last != .session(id) else { return }
        devicesPath.append(.session(id))
    }

    /// Pops the top of the Devices stack. A pop on an empty stack is a no-op:
    /// a stray back gesture must not trap on `removeLast()`.
    mutating func popDevice() {
        guard !devicesPath.isEmpty else { return }
        devicesPath.removeLast()
    }
}

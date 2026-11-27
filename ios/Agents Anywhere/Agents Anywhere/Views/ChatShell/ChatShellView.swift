import SwiftUI
import UIKit

struct ChatShellView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var sidebar = ChatSidebarState()
    @State private var newSessionPresentationID = UUID()
    @State private var panes = ShellPanesModel()
    @State private var panesScope: V2ClientScope?
    /// The scope whose launch preference was already applied; a size-class
    /// re-entry with the same scope must not re-apply it.
    @State private var startPageScope: V2ClientScope?
    /// Pairing entry shared by the drawer and the list root.
    @State private var showsPairing = false
    /// Owns the chat tab's session model outside the tab page, like the
    /// official SessionRegistry keeps the store alive across tab switches.
    @State private var chatPane = ChatPaneStore()
    @AppStorage("aa.shell.tabs") private var shellTabsEnabled = true

    private var selection: ChatShellSelection {
        get { appState.chatSelection }
        nonmutating set { appState.chatSelection = newValue }
    }

    /// The tab shell replaces the phone drawer only. iPad keeps the native
    /// split layout until the two-column design is scoped.
    private var tabShellActive: Bool {
        shellTabsEnabled && horizontalSizeClass != .regular
    }

    var body: some View {
        let bodyStartedAt = CACurrentMediaTime()
        let content = shellBody()
        let _ = noteBodyBuild(startedAt: bodyStartedAt)
        content
    }

    /// Times the shell's view-tree construction. Every `panes` write
    /// re-evaluates this body, so a slow build here would put a tab switch's
    /// stall on our side of the line instead of on the bar's transition.
    private func noteBodyBuild(startedAt: CFTimeInterval) {
        let ms = (CACurrentMediaTime() - startedAt) * 1000
        guard ms >= 10 else { return }
        ClientDiagnosticsLog.shared.record(
            kind: "shell.body.build",
            detail: ["ms": String(format: "%.1f", ms)],
            dedupe: false)
    }

    @ViewBuilder private func shellBody() -> some View {
        // NavigationSplitView adapts to a single stack in a compact system size
        // class. Use that same system trait for the drawer fallback, never a
        // device model, screen measurement or custom window-width breakpoint.
        let layout = ChatSidebarState.Layout.resolve(
            hasRegularWidth: horizontalSizeClass == .regular
        )
        Group {
            if tabShellActive {
                tabShell(layout)
            } else {
                legacyShell(layout)
            }
        }
        .onChange(of: layout, initial: true) { _, next in sidebar.setLayout(next) }
        .onChange(of: tabShellActive, initial: true) { _, active in
            if active {
                // A size-class return re-enters the tab shell with the same
                // client scope; the saved panes may have gone stale while the
                // legacy shell owned the selection, so force the reload.
                panesScope = nil
                loadPanes(appState.clientScope)
            } else {
                chatPane.retain(legacyChatSessionIDs(appState.chatSelection))
            }
        }
        .onChange(of: appState.clientScope, initial: true) { _, scope in
            loadPanes(scope)
        }
        .onChange(of: appState.chatSelection) { _, next in
            // The pane cache follows `panes`: syncing the Chat root below
            // releases models that are neither the root nor on the device
            // stack.
            syncPanesFromSelection(next)
            if !tabShellActive {
                // The legacy shell has no `panes`; only the selected session
                // stays alive, exactly like the old view-owned model.
                chatPane.retain(legacyChatSessionIDs(next))
            }
        }
        .onChange(of: panes) { _, next in
            recordPanes(next, reason: "change")
            chatPane.retain(liveChatSessionIDs(next))
            persistPanes(next)
        }
        // The pages read `panes.selectedTab` directly — the b1660 write probe
        // showed one write per switch, so nothing needs debouncing — and this
        // line records the same edge the pages saw, to time it against the
        // tap. b1660's 220 ms settle window plus the runloop's delivery put
        // the old commit 400–530 ms after the tap.
        .onChange(of: panes.selectedTab, initial: true) { _, next in
            ClientDiagnosticsLog.shared.record(
                kind: "shell.tabs.active",
                detail: ["tab": next.rawValue],
                dedupe: false)
        }
        .task(id: NewSessionLoadKey(target: appState.nativeChatServices?.newSession.refreshKey,
            presentationID: newSessionPresentationID)) {
            // Warm the next draft even when launch restores a session/device.
            // Remounting the welcome view no longer starts its first data load.
            guard let model = appState.nativeChatServices?.newSession else { return }
            await model.refresh(connectors: appState.connectors)
        }
        .alert(String(localized: "Could not update session"), isPresented: sessionActionErrorBinding) {
            Button(String(localized: "OK"), role: .cancel) {
                appState.dismissSessionActionError()
            }
        } message: {
            Text(appState.sessionActionError ?? "")
        }
        .sheet(item: agentSetupBinding) { connector in
            if let services = appState.nativeChatServices {
                AgentSetupSheet(connector: connector, model: services.agents(on: connector.id)) {
                    services.agentSetup.finish(connector.id)
                    Task { await appState.refreshDashboard() }
                }
            }
        }
        // A second `.sheet` on the same view chain can shadow the agent-setup
        // sheet; host this one on a zero-size background like the composer's
        // pickers.
        .background {
            Color.clear
                .sheet(isPresented: $showsPairing, onDismiss: {
                    appState.nativeChatServices?.agentSetup.pairingFormPresented = false
                }) {
                    PairDeviceSheet()
                }
        }
        .onChange(of: visibleSessionID, initial: true) { _, id in
            appState.setVisibleSession(id)
        }
        .onChange(of: watchedSessionID, initial: true) { _, id in
            appState.setWatchedSession(id)
        }
        .onDisappear {
            appState.setVisibleSession(nil)
            appState.setWatchedSession(nil)
        }
    }

    // MARK: - Shells

    private func tabShell(_ layout: ChatSidebarState.Layout) -> some View {
        SidebarDrawer(
            isOpen: sidebarBinding(for: layout),
            presentation: .drawer,
            configuration: .chat
        ) { _ in
            ChatSidebarHeaderView()
        } sidebar: { safeAreaInsets in
            sidebarContent(safeAreaInsets: safeAreaInsets)
        } content: { _ in
            ShellTabsView(
                panes: $panes,
                chatRoot: chatTabRoot,
                onMenu: toggleSidebar
            )
        }
    }

    private func legacyShell(_ layout: ChatSidebarState.Layout) -> some View {
        SidebarDrawer(
            isOpen: sidebarBinding(for: layout),
            presentation: layout == .regularSplit ? .nativeSidebar : .drawer,
            configuration: .chat
        ) { _ in
            ChatSidebarHeaderView()
        } sidebar: { safeAreaInsets in
            sidebarContent(safeAreaInsets: safeAreaInsets)
        } content: { _ in
            mainContent
                .modifier(ChatDetailNavigation())
        }
    }

    private func sidebarContent(safeAreaInsets: EdgeInsets) -> some View {
        let services = appState.nativeChatServices
        return ChatSidebarView(
            appState: appState,
            agentSetup: services?.agentSetup,
            safeAreaInsets: safeAreaInsets,
            library: appState.activeDashboardLibrary,
            // The merged Chat tab keeps the device list at its root; the
            // drawer's device rows are the fast device switcher.
            showsDevicesSection: true,
            repository: services?.dashboardRepository,
            onNewProjectSession: startProjectSession,
            onRestoreSession: { await appState.setSessionArchived(sessionId: $0, archived: false) },
            account: sidebarAccount,
            devicesTabActive: tabShellActive,
            devicesTabDeviceId: tabShellActive ? panes.chatDevice : nil,
            showsViewAll: tabShellActive && !panes.isListMode,
            onShowAll: showList,
            legacyDeviceId: {
                if case let .device(id) = selection { return id }
                return nil
            }(),
            selectedSessionId: selectedSessionId,
            isLoadingDevices: appState.isDashboardLoading && !appState.hasLoadedConnectors,
            isLoadingSessions: appState.isDashboardLoading && !appState.hasLoadedSessions,
            onNewSession: startNewSession,
            onOpenDevice: openDevice,
            onOpenSession: openSession,
            onRenameSession: renameSession,
            onToggleSessionPinned: setSessionPinned,
            onArchiveSession: archiveSession,
            onCopyDeviceId: copyDeviceId,
            onCopySessionId: copySessionId
        )
    }

    // MARK: - Tab roots

    /// The Chat tab is the old Devices tab's interaction: the device page is
    /// the list root, a session is pushed above it, the system back button
    /// returns to the list. The list/chat mode is derived from `chatPath`.
    private var chatTabRoot: some View {
        NavigationStack(path: $panes.chatPath) {
            Group {
                if let services = appState.nativeChatServices {
                    DevicePageHost(
                        appState: appState, library: appState.activeDashboardLibrary,
                        connectorId: panes.chatDevice ?? defaultDeviceID,
                        showsMenuButton: true,
                        onMenu: toggleSidebar,
                        onOpenDevice: openDevice,
                        onCopyDeviceId: copyDeviceId,
                        onOpenSession: openSession,
                        onPair: startPairing,
                        onNewSession: { path in
                            if let id = panes.chatDevice ?? defaultDeviceID,
                               let model = services.newSession {
                                model.focusDevice(id, workspace: path)
                            }
                            panes.startNewChat(workspace: path)
                        },
                        onNewProjectSession: startProjectSession,
                        onConnectorUpdated: appState.updateConnector,
                        onConnectorDeleted: removeConnector,
                        onSessionsUpdated: appState.updateSessions,
                        onSetSessionsArchived: appState.setSessionsArchived)
                } else {
                    shellPlaceholderPage()
                }
            }
            // Registered outside the services branch: a restored `chatPath`
            // must always find its destinations.
            .navigationDestination(for: ChatTabRoute.self) { route in
                if let services = appState.nativeChatServices {
                    switch route {
                    case let .device(id):
                        DevicePageHost(
                            appState: appState, library: appState.activeDashboardLibrary,
                            connectorId: id, showsMenuButton: false,
                            onMenu: toggleSidebar,
                            onOpenDevice: openDevice,
                            onCopyDeviceId: copyDeviceId,
                            onOpenSession: openSession,
                            onPair: startPairing,
                            onNewSession: { path in
                                if let model = services.newSession {
                                    model.focusDevice(id, workspace: path)
                                }
                                panes.startNewChat(workspace: path)
                            },
                            onNewProjectSession: startProjectSession,
                            onConnectorUpdated: appState.updateConnector,
                            onConnectorDeleted: removeConnector,
                            onSessionsUpdated: appState.updateSessions,
                            onSetSessionsArchived: appState.setSessionsArchived)
                    case let .session(id):
                        SessionPageHost(
                            appState: appState, services: services, chatPane: chatPane,
                            library: appState.activeDashboardLibrary, sessionID: id,
                            paneRole: .chat, showsMenuButton: false,
                            onMenu: toggleSidebar,
                            onTogglePinned: { pinned in
                                setSessionPinned(id, pinned: pinned)
                            })
                    case .newSession:
                        NewSessionPageHost(
                            appState: appState, services: services,
                            library: appState.activeDashboardLibrary,
                            onMenu: toggleSidebar, onOpenDevice: openDevice,
                            onCreated: { session in
                                appState.updateSession(session)
                                // The reader may have left the compose page
                                // while the request was in flight; only
                                // navigate if it still owns the top.
                                if case .newSession? = panes.chatPath.last {
                                    panes.openChatSession(session.id)
                                    selection = .session(session.id)
                                }
                            },
                            onRefresh: { await appState.refreshDashboard(); return appState.connectors })
                            .id(newSessionPresentationID)
                    }
                } else {
                    shellPlaceholderPage()
                }
            }
        }
        // The session page owns its keyboard insets (composer safeAreaBar),
        // exactly like the old Devices stack.
        .ignoresSafeArea(.keyboard)
    }

    /// Fallback device for the tab root: first online, else first.
    private var defaultDeviceID: V2ConnectorID? {
        appState.connectors.first { $0.status == .online }?.id
            ?? appState.connectors.first?.id
    }

    @ViewBuilder private var mainContent: some View {
        if case let .device(connectorId) = selection {
            DevicePageHost(
                appState: appState, library: appState.activeDashboardLibrary,
                connectorId: connectorId, showsMenuButton: true,
                onMenu: toggleSidebar, onOpenDevice: openDevice,
                onCopyDeviceId: copyDeviceId, onOpenSession: openSession,
                onPair: startPairing,
                onNewSession: { path in
                    if let model = appState.nativeChatServices?.newSession {
                        model.focusDevice(connectorId, workspace: path)
                    }
                    startNewSession()
                },
                onNewProjectSession: startProjectSession,
                onConnectorUpdated: appState.updateConnector,
                onConnectorDeleted: removeConnector,
                onSessionsUpdated: appState.updateSessions,
                onSetSessionsArchived: appState.setSessionsArchived)
        } else if let services = appState.nativeChatServices {
            if case let .session(id) = selection {
                SessionPageHost(
                    appState: appState, services: services, chatPane: chatPane,
                    library: appState.activeDashboardLibrary, sessionID: id,
                    paneRole: .chat, showsMenuButton: true,
                    onMenu: toggleSidebar,
                    onTogglePinned: { pinned in setSessionPinned(id, pinned: pinned) })
            } else {
                NewSessionPageHost(
                    appState: appState, services: services,
                    library: appState.activeDashboardLibrary,
                    onMenu: toggleSidebar, onOpenDevice: openDevice,
                    onCreated: { session in
                        appState.updateSession(session)
                        if selection == .newSession { openSession(session.id) }
                    },
                    onRefresh: { await appState.refreshDashboard(); return appState.connectors })
                    .id(newSessionPresentationID)
            }
        } else {
            shellPlaceholderPage()
        }
    }

    /// Pushed pages leave the leading bar slot to the system back button; the
    /// root keeps the drawer hamburger.
    private func shellPlaceholderPage(showsMenuButton: Bool = true) -> some View {
        ChatShellPlaceholderPage(
            isConnecting: appState.isRetryingServerConnection,
            title: selectedContentTitle ?? "",
            onOpenSidebar: openSidebar,
            showsMenuButton: showsMenuButton
        )
    }

    // MARK: - Sidebar inputs

    private func sidebarBinding(for layout: ChatSidebarState.Layout) -> Binding<Bool> {
        Binding(get: { sidebar.isOpen(in: layout) }, set: { isOpen in
            sidebar.setLayout(layout)
            sidebar.isOpen = isOpen
        })
    }

    private var selectedSessionId: V2SessionID? {
        if tabShellActive {
            guard case let .session(id)? = panes.chatPath.last else { return nil }
            return id
        }
        guard case let .session(id) = selection else { return nil }
        return id
    }

    private var selectedContentTitle: String? {
        switch selection {
        case .newSession:
            return nil
        case let .device(id):
            return appState.connectors.first { $0.id == id }?.name
        case let .session(id):
            return appState.sessions.first { $0.id == id }?.title
        }
    }

    private var sessionActionErrorBinding: Binding<Bool> {
        Binding(
            get: { appState.sessionActionError != nil },
            set: { isPresented in
                if !isPresented {
                    appState.dismissSessionActionError()
                }
            }
        )
    }

    private var agentSetupBinding: Binding<V2Connector?> {
        Binding(get: { appState.nativeChatServices?.agentSetup.presentedConnector }, set: { value in
            if value == nil, let setup = appState.nativeChatServices?.agentSetup, let connector = setup.presentedConnector {
                setup.finish(connector.id)
            }
        })
    }

    private var sidebarAccount: ChatSidebarAccount? {
        guard let me = appState.me else { return nil }
        return ChatSidebarAccount(me: me, avatarSource: appState.accountAvatarSource)
    }

    private var visibleSessionID: V2SessionID? {
        guard scenePhase == .active else { return nil }
        if tabShellActive {
            return panes.visibleSessionId(obscured: sidebar.obscuresDetail)
        }
        return sidebar.obscuresDetail ? nil : selectedSessionId
    }

    /// Same page as `visibleSessionID`, but independent of the scene phase:
    /// the background keep-alive must still know which session the reader
    /// left open (including a session above the list root).
    private var watchedSessionID: V2SessionID? {
        tabShellActive ? panes.visibleSessionId(obscured: false) : selectedSessionId
    }

    // MARK: - Pane state

    private func loadPanes(_ scope: V2ClientScope?) {
        guard tabShellActive, let scope, panesScope != scope else { return }
        // The pane snapshot is the tab shell's truth; the legacy selection is
        // only a fallback when no snapshot exists (the store seeds from it).
        // Re-adopting it here would turn a restored list into the last session.
        var loaded = appState.shellPanes(in: scope)
        if startPageScope != scope {
            loaded.applyStartPage(ShellStartPage.current())
            startPageScope = scope
        }
        panes = loaded
        panesScope = scope
    }

    private func syncPanesFromSelection(_ next: ChatShellSelection) {
        guard tabShellActive else { return }
        switch next {
        case .newSession:
            // Deleting a device/archiving a session writes `.newSession`; it
            // pops a visible session back to the list instead of dragging a
            // reader who is already on the list into a compose page.
            if case .session? = panes.chatPath.last { panes.chatPath = [] }
        case let .session(id):
            if panes.chatPath.last != .session(id) {
                panes.openChatSession(id)
            } else if panes.selectedTab != .chat {
                panes.selectedTab = .chat
            }
        case let .device(id):
            if panes.chatDevice != id || !panes.chatPath.isEmpty {
                panes.openDevice(id)
            }
        }
    }

    private func persistPanes(_ next: ShellPanesModel) {
        guard tabShellActive, let scope = panesScope else { return }
        appState.saveShellPanes(next, in: scope)
    }

    /// The pages that may keep a live pane: the Chat tab root and the Device
    /// stack's session. Everything else is released with its observer.
    /// One state line per pane change: tab, Chat root, root device and the
    /// session drill-down. Enough to reconstruct a navigation bug without a
    /// verbal description.
    private func recordPanes(_ next: ShellPanesModel, reason: String) {
        let path = next.chatPath.map { route -> String in
            switch route {
            case let .device(id): return "d:\(id)"
            case let .session(id): return "s:\(id)"
            case .newSession: return "new"
            }
        }.joined(separator: ">")
        ClientDiagnosticsLog.shared.record(
            kind: "shell.tabs.state",
            detail: ["reason": reason,
                     "tab": next.selectedTab.rawValue,
                     "device": next.chatDevice ?? "auto",
                     "path": path,
                     "last": next.lastSessionID ?? "",
                     "visible": next.visibleSessionId(obscured: false) ?? ""],
            dedupe: true)
    }

    private func liveChatSessionIDs(_ panes: ShellPanesModel) -> Set<V2SessionID> {
        var ids: Set<V2SessionID> = []
        for route in panes.chatPath {
            if case let .session(id) = route { ids.insert(id) }
        }
        return ids
    }

    /// The legacy shell has no pane cache: its only live session is the one
    /// the selection shows.
    private func legacyChatSessionIDs(_ selection: ChatShellSelection) -> Set<V2SessionID> {
        if case let .session(id) = selection { return [id] }
        return []
    }

    // MARK: - Navigation actions

    private func startProjectSession(_ id: String) {
        guard let services = appState.nativeChatServices else { return }
        services.newSession.updateProjects(services.dashboardRepository.projects)
        guard services.newSession.selectProject(id) else { return }
        startNewSession()
    }

    private func startNewSession() {
        // Reselecting this destination must also remount its local presentation
        // state, including the welcome reveal. The account still owns the draft.
        newSessionPresentationID = UUID()
        if tabShellActive {
            panes.startNewChat()
        }
        selection = .newSession
        sidebar.selectDestination()
    }

    private func openDevice(_ id: V2ConnectorID) {
        if tabShellActive {
            ClientDiagnosticsLog.shared.record(
                kind: "device.tab.open",
                detail: ["device": id, "previous": panes.chatDevice ?? "auto"])
            panes.openDevice(id)
        } else {
            selection = .device(id)
        }
        sidebar.selectDestination()
    }

    private func openSession(_ id: V2SessionID) {
        if tabShellActive {
            panes.openChatSession(id)
        }
        selection = .session(id)
        sidebar.selectDestination()
    }

    /// The sidebar's "查看全部" entry: pop the Chat tab to its list root.
    private func showList() {
        if tabShellActive {
            panes.showList()
        } else if let id = panes.chatDevice ?? defaultDeviceID {
            selection = .device(id)
        }
        sidebar.selectDestination()
    }

    private func removeConnector(_ id: V2ConnectorID) {
        // Resolve before the removal drops the connector's sessions from
        // `appState.sessions`.
        var clearsVisible = false
        if case let .session(visibleID)? = panes.chatPath.last {
            clearsVisible = appState.sessions.first { $0.id == visibleID }?.connectorId == id
        }
        let clearsLast: Bool = {
            guard let last = panes.lastSessionID else { return false }
            return appState.sessions.first { $0.id == last }?.connectorId == id
        }()
        ClientDiagnosticsLog.shared.record(
            kind: "device.tab.delete",
            detail: ["device": id,
                     "root": panes.chatDevice == id ? "1" : "0",
                     "visible": clearsVisible ? "1" : "0"])
        appState.removeConnector(connectorId: id)
        if tabShellActive {
            if panes.chatDevice == id {
                panes.chatDevice = nil
                panes.chatPath = []
            }
            if clearsLast { panes.lastSessionID = nil }
            if clearsVisible {
                panes.chatPath = []
                panes.lastSessionID = nil
                // The Chat tab's visible page is gone; reset the cross-shell
                // pointer with it. Unrelated state is left alone.
                selection = .newSession
            }
        } else {
            selection = .newSession
        }
    }

    private func renameSession(_ id: V2SessionID, title: String) {
        Task {
            _ = await appState.renameSession(sessionId: id, title: title)
        }
    }

    private func setSessionPinned(_ id: V2SessionID, pinned: Bool) {
        Task {
            _ = await appState.setSessionPinned(sessionId: id, pinned: pinned)
        }
    }

    private func archiveSession(_ id: V2SessionID) {
        Task {
            let shouldArchive = appState.sessions.first { $0.id == id }?.archived != true
            let changed = await appState.setSessionArchived(sessionId: id, archived: shouldArchive)
            guard changed, shouldArchive else { return }
            if tabShellActive {
                // The archived session may be the visible page (the top of
                // the Chat stack). Pop it back to the list and stay on the
                // tab the user is already on.
                if panes.lastSessionID == id { panes.lastSessionID = nil }
                if case let .session(topID)? = panes.chatPath.last, topID == id {
                    panes.chatPath = []
                    selection = .newSession
                }
            } else if selectedSessionId == id {
                selection = .newSession
            }
        }
    }

    private func copyDeviceId(_ id: V2ConnectorID) {
        UIPasteboard.general.string = id
    }

    private func copySessionId(_ id: V2SessionID) {
        UIPasteboard.general.string = id
    }

    private func startPairing() {
        ClientDiagnosticsLog.shared.record(kind: "device.pair.open")
        appState.nativeChatServices?.agentSetup.pairingFormPresented = true
        showsPairing = true
    }

    private func toggleSidebar() {
        sidebar.isOpen.toggle()
    }

    private func openSidebar() {
        sidebar.isOpen = true
    }
}

private struct NewSessionLoadKey: Equatable {
    let target: NewSessionRefreshKey?
    let presentationID: UUID
}

struct ChatShellPlaceholderPage: View {
    let isConnecting: Bool
    let title: String
    let onOpenSidebar: () -> Void
    var showsMenuButton = true

    var body: some View {
        Color(.systemBackground)
            .overlay {
                if isConnecting {
                    Label(String(localized: "正在连接，首次同步后即可保留本地内容"), appSymbol: "network")
                        .font(.footnote).foregroundStyle(.secondary).padding(24)
                }
            }
            .modifier(ChatPageToolbar(title: title, onMenu: onOpenSidebar,
                showsMenuButton: showsMenuButton))
    }
}

#Preview {
    ChatShellView()
        .environment(AppState())
        .preferredColorScheme(.dark)
}

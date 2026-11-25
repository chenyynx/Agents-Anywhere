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
            if active { loadPanes(appState.clientScope) }
        }
        .onChange(of: appState.clientScope, initial: true) { _, scope in
            loadPanes(scope)
        }
        .onChange(of: appState.chatSelection) { _, next in
            // The pane cache follows `panes`: syncing the Chat root below
            // releases models that are neither the root nor on the device
            // stack.
            syncPanesFromSelection(next)
        }
        .onChange(of: panes) { _, next in
            chatPane.retain(liveChatSessionIDs(next))
            persistPanes(next)
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
                devicesRoot: devicesTabRoot,
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
        let sessions = sidebarSessions
        let services = appState.nativeChatServices
        return ChatSidebarView(
            appState: appState,
            agentSetup: services?.agentSetup,
            safeAreaInsets: safeAreaInsets,
            devices: sidebarDevices,
            pinnedSessions: sessions.filter(\.pinned),
            recentSessions: sessions.filter { !$0.pinned },
            repository: services?.dashboardRepository,
            onNewProjectSession: startProjectSession,
            onRestoreSession: { await appState.setSessionArchived(sessionId: $0, archived: false) },
            account: sidebarAccount,
            selectedDeviceId: selectedDeviceId,
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

    @ViewBuilder private var chatTabRoot: some View {
        if let services = appState.nativeChatServices {
            if case let .session(id) = selection {
                sessionPage(id: id, services: services)
            } else {
                newSessionPage(services: services)
            }
        } else {
            shellPlaceholderPage
        }
    }

    private var devicesTabRoot: some View {
        NavigationStack(path: $panes.devicesPath) {
            DevicesListPage(
                devices: sidebarDevices,
                isLoading: appState.isDashboardLoading && !appState.hasLoadedConnectors,
                onMenu: toggleSidebar,
                onOpen: { id in panes.openDevice(id) }
            )
            .navigationDestination(for: ShellDevicesRoute.self) { route in
                switch route {
                case let .device(id): deviceStackPage(id)
                case let .session(id): deviceSessionPage(id)
                }
            }
        }
        // The session page owns its keyboard insets (composer safeAreaBar),
        // exactly like the Chat tab's stack.
        .ignoresSafeArea(.keyboard)
    }

    /// Devices tab: list → device → session. The session page is pushed inside
    /// this tab's stack; tapping a session here must not switch to the Chat tab.
    @ViewBuilder private func deviceStackPage(_ connectorId: V2ConnectorID) -> some View {
        if let connector = appState.connectors.first(where: { $0.id == connectorId }),
           let clients = appState.nativeChatServices,
           let service = appState.deviceManagementService,
           let workspaceFilesService = appState.workspaceFilesService,
           let serverURL = appState.serverURL
        {
            DeviceManagementView(
                connector: connector,
                connectors: appState.connectors,
                allSessions: appState.sessions,
                projects: appState.projects,
                agents: clients.agents(on: connectorId),
                dashboard: clients.dashboardRepository,
                service: service,
                workspaceFilesService: workspaceFilesService,
                serverURL: serverURL,
                onMenu: toggleSidebar,
                showsMenuButton: false,
                onOpenDevice: { panes.openDevice($0) },
                onOpenSession: { panes.pushDeviceSession($0) },
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
                onSetSessionsArchived: appState.setSessionsArchived
            )
            .id(connectorId)
        } else {
            shellPlaceholderPage
        }
    }

    @ViewBuilder private func deviceSessionPage(_ id: V2SessionID) -> some View {
        if let services = appState.nativeChatServices {
            let session = services.sessionRepository.session(id: id)
            let summary = appState.sessions.first { $0.id == id }
            let connectorID = session.metadata?.connectorId ?? summary?.connectorId
            SessionChatView(model: chatPane.pane(for: session, services: services), services: services,
                deviceName: appState.connectors.first { $0.id == connectorID }?.name,
                fallbackTitle: summary?.title,
                fallbackRuntimeName: summary?.runtimeName ?? summary?.runtime,
                onMenu: toggleSidebar,
                showsMenuButton: false,
                onTogglePinned: { pinned in setSessionPinned(id, pinned: pinned) })
                .equatable()
                .id(session.presentationKey)
        } else {
            shellPlaceholderPage
        }
    }

    @ViewBuilder private var mainContent: some View {
        if case let .device(connectorId) = selection {
            devicePage(connectorId: connectorId)
        } else if let services = appState.nativeChatServices {
            if case let .session(id) = selection {
                sessionPage(id: id, services: services)
            } else {
                newSessionPage(services: services)
            }
        } else {
            shellPlaceholderPage
        }
    }

    @ViewBuilder private func devicePage(connectorId: V2ConnectorID) -> some View {
        if let connector = appState.connectors.first(where: { $0.id == connectorId }),
           let clients = appState.nativeChatServices,
           let service = appState.deviceManagementService,
           let workspaceFilesService = appState.workspaceFilesService,
           let serverURL = appState.serverURL
        {
            DeviceManagementView(
                connector: connector,
                connectors: appState.connectors,
                allSessions: appState.sessions,
                projects: appState.projects,
                agents: clients.agents(on: connectorId),
                dashboard: clients.dashboardRepository,
                service: service,
                workspaceFilesService: workspaceFilesService,
                serverURL: serverURL,
                onMenu: toggleSidebar,
                onOpenDevice: openDevice,
                onOpenSession: openSession,
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
                onSetSessionsArchived: appState.setSessionsArchived
            )
            .id(connectorId)
        } else {
            shellPlaceholderPage
        }
    }

    @ViewBuilder private func sessionPage(id: V2SessionID, services: V2ClientServices) -> some View {
        let session = services.sessionRepository.session(id: id)
        let summary = appState.sessions.first { $0.id == id }
        let connectorID = session.metadata?.connectorId ?? summary?.connectorId
        SessionChatView(model: chatPane.pane(for: session, services: services), services: services,
            deviceName: appState.connectors.first { $0.id == connectorID }?.name,
            fallbackTitle: summary?.title,
            fallbackRuntimeName: summary?.runtimeName ?? summary?.runtime,
            onMenu: toggleSidebar,
            onTogglePinned: { pinned in setSessionPinned(id, pinned: pinned) })
            .equatable()
            // The model's identity, not the selection's: binding a
            // local creation renames the session in place, and re-keying
            // here remounted the page — replaying the send's entrance
            // (pp 2026-11-15).
            .id(session.presentationKey)
    }

    @ViewBuilder private func newSessionPage(services: V2ClientServices) -> some View {
        NewSessionView(model: services.newSession, connectors: appState.connectors, sessions: appState.sessions, repository: services.dashboardRepository,
            dashboardLoading: appState.isDashboardLoading,
            dashboardError: appState.connectorsError,
            onMenu: toggleSidebar,
            onOpenDevice: openDevice,
            onCreated: { session in
                appState.updateSession(session)
                if case .newSession = selection { openSession(session.id) }
            },
            onRefresh: { await appState.refreshDashboard(); return appState.connectors })
            .equatable()
            .id(newSessionPresentationID)
    }

    private var shellPlaceholderPage: some View {
        ChatShellPlaceholderPage(
            isConnecting: appState.isRetryingServerConnection,
            title: selectedContentTitle ?? "",
            onOpenSidebar: openSidebar
        )
    }

    // MARK: - Sidebar inputs

    private func sidebarBinding(for layout: ChatSidebarState.Layout) -> Binding<Bool> {
        Binding(get: { sidebar.isOpen(in: layout) }, set: { isOpen in
            sidebar.setLayout(layout)
            sidebar.isOpen = isOpen
        })
    }

    private var selectedDeviceId: V2ConnectorID? {
        if tabShellActive {
            guard panes.selectedTab == .devices,
                  case let .device(id)? = panes.devicesPath.first else { return nil }
            return id
        }
        guard case let .device(id) = selection else { return nil }
        return id
    }

    private var selectedSessionId: V2SessionID? {
        if tabShellActive {
            switch panes.selectedTab {
            case .chat:
                guard case let .session(id) = panes.chatRoot else { return nil }
                return id
            case .devices:
                guard case let .session(id)? = panes.devicesPath.last else { return nil }
                return id
            case .wiki, .artifacts:
                return nil
            }
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

    private var sidebarDevices: [ChatSidebarDevice] {
        appState.connectors.map { connector in
            ChatSidebarDevice(connector: connector)
        }
    }

    private var sidebarAccount: ChatSidebarAccount? {
        guard let me = appState.me else { return nil }
        return ChatSidebarAccount(me: me, avatarSource: appState.accountAvatarSource)
    }

    private var sidebarSessions: [ChatSidebarSession] {
        #if AA_TIMELINE_PROBE
        // Timed because the drawer's deferred `isOpen` write invalidates this
        // body right after its animation; this map/sort is the part of the
        // rebuild that grows with the session count.
        let started = CACurrentMediaTime()
        defer {
            TimelineProbeStore.shared.noteShellSessions(seconds: CACurrentMediaTime() - started)
        }
        #endif
        return appState.sessions
            .filter { !$0.archived }
            .map { session in
                ChatSidebarSession(session: session)
            }
            .sorted { $0.presentation.precedes($1.presentation, id: $0.id, otherID: $1.id) }
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
    /// left open (including a Devices-tab session).
    private var watchedSessionID: V2SessionID? {
        tabShellActive ? panes.visibleSessionId(obscured: false) : selectedSessionId
    }

    // MARK: - Pane state

    private func loadPanes(_ scope: V2ClientScope?) {
        guard tabShellActive, let scope, panesScope != scope else { return }
        var loaded = appState.shellPanes(in: scope)
        // The saved ChatShellSelection is the cross-shell truth: the legacy
        // shell and notifications both write it. Adopt it over a stale panes
        // snapshot, then keep the snapshot in sync.
        switch appState.chatSelection {
        case .newSession:
            loaded.chatRoot = .newSession
        case let .session(id):
            loaded.chatRoot = .session(id)
        case let .device(id):
            if loaded.devicesPath.isEmpty { loaded.openDevice(id) }
        }
        panes = loaded
        panesScope = scope
    }

    private func syncPanesFromSelection(_ next: ChatShellSelection) {
        guard tabShellActive else { return }
        switch next {
        case .newSession:
            if panes.selectedTab != .chat || panes.chatRoot != .newSession {
                panes.startNewChat()
            }
        case let .session(id):
            if panes.chatRoot != .session(id) {
                panes.openChatSession(id)
            } else if panes.selectedTab != .chat {
                panes.selectedTab = .chat
            }
        case let .device(id):
            if panes.selectedTab != .devices || panes.devicesPath.isEmpty {
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
    private func liveChatSessionIDs(_ panes: ShellPanesModel) -> Set<V2SessionID> {
        var ids: Set<V2SessionID> = []
        if case let .session(id) = panes.chatRoot { ids.insert(id) }
        for route in panes.devicesPath {
            if case let .session(id) = route { ids.insert(id) }
        }
        return ids
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

    private func removeConnector(_ id: V2ConnectorID) {
        appState.removeConnector(connectorId: id)
        if tabShellActive {
            let referencesDevice = panes.devicesPath.contains { route in
                if case let .device(deviceID) = route { return deviceID == id }
                return false
            }
            if referencesDevice { panes.devicesPath.removeAll() }
        }
        selection = .newSession
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
            if changed && shouldArchive, selectedSessionId == id {
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

private struct ChatShellPlaceholderPage: View {
    let isConnecting: Bool
    let title: String
    let onOpenSidebar: () -> Void

    var body: some View {
        Color(.systemBackground)
            .overlay {
                if isConnecting {
                    Label(String(localized: "正在连接，首次同步后即可保留本地内容"), appSymbol: "network")
                        .font(.footnote).foregroundStyle(.secondary).padding(24)
                }
            }
            .modifier(ChatPageToolbar(title: title, onMenu: onOpenSidebar))
    }
}

#Preview {
    ChatShellView()
        .environment(AppState())
        .preferredColorScheme(.dark)
}

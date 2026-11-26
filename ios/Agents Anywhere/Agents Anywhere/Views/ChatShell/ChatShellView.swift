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
    /// The Devices tab owns the pairing entry now that the phone drawer no
    /// longer lists devices.
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

    private func shellBody() -> some View {
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
            // The phone tab shell owns devices; the drawer keeps them only
            // for iPad/the legacy shell, which has no Devices tab.
            showsDevicesSection: !tabShellActive,
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
            if let id = chatRootSessionID {
                sessionPage(id: id, services: services)
            } else {
                newSessionPage(services: services)
            }
        } else {
            shellPlaceholderPage()
        }
    }

    /// What the Chat tab renders. `panes` owns the tab shell's navigation;
    /// `selection` is the cross-shell input and only seeds the first frame
    /// before `loadPanes` has run (no restore flash).
    private var chatRootSessionID: V2SessionID? {
        if panesScope == nil, case let .session(id) = selection { return id }
        if case let .session(id) = panes.chatRoot { return id }
        return nil
    }

    private var devicesTabRoot: some View {
        NavigationStack(path: $panes.devicesPath) {
            deviceTabRootPage
                .navigationDestination(for: ShellDevicesRoute.self) { route in
                    switch route {
                    case let .device(id): deviceStackPage(id)   // old snapshots only
                    case let .session(id): deviceSessionPage(id)
                    }
                }
        }
        // The session page owns its keyboard insets (composer safeAreaBar),
        // exactly like the Chat tab's stack.
        .ignoresSafeArea(.keyboard)
    }

    /// The device page is the Devices tab's root (pp 2026-11-26); the session
    /// drill-down pushes above it.
    @ViewBuilder private var deviceTabRootPage: some View {
        if let id = panes.devicesDevice ?? defaultDeviceID {
            deviceStackPage(id, showsMenuButton: true)
        } else if appState.isDashboardLoading && !appState.hasLoadedConnectors {
            shellPlaceholderPage()
        } else {
            noDevicePage
        }
    }

    private var defaultDeviceID: V2ConnectorID? {
        appState.connectors.first { $0.status == .online }?.id
            ?? appState.connectors.first?.id
    }

    /// Nothing to root the tab on: the pairing entry is the only useful action.
    private var noDevicePage: some View {
        VStack(spacing: 12) {
            Text(appState.connectorsError ?? String(localized: "No devices"))
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            if appState.connectorsError != nil {
                Button(String(localized: "重试")) {
                    Task { await appState.refreshDashboard() }
                }
                .font(.footnote.weight(.medium))
            }
            Button(String(localized: "添加设备")) { startPairing() }
                .font(.footnote.weight(.medium))
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: CodePageTheme.pageBackgroundUIColor).ignoresSafeArea())
        .modifier(ChatPageToolbar(title: String(localized: "Devices"), onMenu: toggleSidebar))
    }

    /// Devices tab: the device page is the root (no back button); the session
    /// drill-down pushes inside this tab's stack and must not switch to the
    /// Chat tab.
    @ViewBuilder private func deviceStackPage(_ connectorId: V2ConnectorID,
                                              showsMenuButton: Bool = false) -> some View {
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
                showsMenuButton: showsMenuButton,
                onOpenDevice: { id in
                    ClientDiagnosticsLog.shared.record(
                        kind: "device.tab.open",
                        detail: ["device": id, "previous": panes.devicesDevice ?? "auto"])
                    panes.openDevice(id)
                },
                onCopyDeviceId: copyDeviceId,
                onOpenSession: { id in
                    ClientDiagnosticsLog.shared.record(
                        kind: "device.tab.session",
                        sessionID: id,
                        detail: ["device": panes.devicesDevice ?? "auto"])
                    panes.pushDeviceSession(id)
                },
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
                onSetSessionsArchived: appState.setSessionsArchived
            )
            .id(connectorId)
        } else {
            shellPlaceholderPage(showsMenuButton: showsMenuButton)
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
                paneRole: .devices,
                isActive: panes.selectedTab == .devices,
                onMenu: toggleSidebar,
                showsMenuButton: false,
                onTogglePinned: { pinned in setSessionPinned(id, pinned: pinned) })
                .equatable()
                .id(session.presentationKey)
        } else {
            shellPlaceholderPage(showsMenuButton: false)
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
            shellPlaceholderPage()
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
                onCopyDeviceId: copyDeviceId,
                onOpenSession: openSession,
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
                onSetSessionsArchived: appState.setSessionsArchived
            )
            .id(connectorId)
        } else {
            shellPlaceholderPage()
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
            isActive: !tabShellActive || panes.selectedTab == .chat,
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
                // The page the creation started from may have been left while
                // the request was in flight; only navigate if it still owns
                // the Chat tab (or the legacy selection).
                let stillWanted = tabShellActive ? chatRootSessionID == nil : selection == .newSession
                if stillWanted { openSession(session.id) }
            },
            onRefresh: { await appState.refreshDashboard(); return appState.connectors })
            .equatable()
            .id(newSessionPresentationID)
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

    private var selectedDeviceId: V2ConnectorID? {
        if tabShellActive {
            guard panes.selectedTab == .devices else { return nil }
            return panes.devicesDevice ?? defaultDeviceID
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
            // Keep the saved session drill-down only when it belongs to the
            // same device; the cross-shell selection wins over a stale one.
            if loaded.devicesDevice != id { loaded.openDevice(id) }
        }
        panes = loaded
        panesScope = scope
    }

    private func syncPanesFromSelection(_ next: ChatShellSelection) {
        guard tabShellActive else { return }
        switch next {
        case .newSession:
            // Only the Chat root resets. Deleting a device or archiving a
            // session also writes `.newSession`; those flows must not drag the
            // user out of the Devices tab.
            if panes.chatRoot != .newSession { panes.chatRoot = .newSession }
        case let .session(id):
            if panes.chatRoot != .session(id) {
                panes.openChatSession(id)
            } else if panes.selectedTab != .chat {
                panes.selectedTab = .chat
            }
        case let .device(id):
            if panes.selectedTab != .devices || panes.devicesDevice != id {
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
        let chat: String
        switch next.chatRoot {
        case .newSession: chat = "new"
        case let .session(id): chat = id
        }
        let path = next.devicesPath.map { route -> String in
            switch route {
            case let .device(id): return "d:\(id)"
            case let .session(id): return "s:\(id)"
            }
        }.joined(separator: ">")
        ClientDiagnosticsLog.shared.record(
            kind: "shell.tabs.state",
            detail: ["reason": reason,
                     "tab": next.selectedTab.rawValue,
                     "chat": chat,
                     "device": next.devicesDevice ?? "auto",
                     "path": path,
                     "visible": next.visibleSessionId(obscured: false) ?? ""],
            dedupe: true)
    }

    private func liveChatSessionIDs(_ panes: ShellPanesModel) -> Set<V2SessionID> {
        var ids: Set<V2SessionID> = []
        if case let .session(id) = panes.chatRoot { ids.insert(id) }
        for route in panes.devicesPath {
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
                detail: ["device": id, "previous": panes.devicesDevice ?? "auto"])
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
        // Resolve before the removal drops the connector's sessions from
        // `appState.sessions`.
        var clearsChatRoot = false
        if case let .session(rootID) = panes.chatRoot {
            clearsChatRoot = appState.sessions.first { $0.id == rootID }?.connectorId == id
        }
        ClientDiagnosticsLog.shared.record(
            kind: "device.tab.delete",
            detail: ["device": id,
                     "root": panes.devicesDevice == id ? "1" : "0",
                     "chatRoot": clearsChatRoot ? "1" : "0"])
        appState.removeConnector(connectorId: id)
        if tabShellActive {
            if panes.devicesDevice == id {
                panes.devicesDevice = nil
                panes.devicesPath.removeAll()
            }
            if clearsChatRoot {
                panes.chatRoot = .newSession
                // The Chat root is the one the Chat tab renders; reset the
                // cross-shell pointer with it. Unrelated roots (and a stale
                // device pointer) are left alone so the Devices tab stays put.
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
                // The archived session may be the Chat root, the top of the
                // Devices stack, or both. Remove exactly those references and
                // stay on the tab the user is already on.
                var resetsChatRoot = false
                if case let .session(rootID) = panes.chatRoot, rootID == id {
                    panes.chatRoot = .newSession
                    resetsChatRoot = true
                }
                if case let .session(topID)? = panes.devicesPath.last, topID == id {
                    panes.devicesPath.removeLast()
                }
                if resetsChatRoot {
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

private struct ChatShellPlaceholderPage: View {
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

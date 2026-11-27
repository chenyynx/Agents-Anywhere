import SwiftUI

/// Page-level observers of the dashboard library.
///
/// The shell root must not read session/connector arrays: every dashboard
/// snapshot would re-evaluate the root and the whole persistent tab stack
/// (b1719: each Devices scroll hitch started on a snapshot landing). These
/// hosts read the library (or the legacy AppState projection while the switch
/// is off) inside their own body, so a snapshot re-evaluates only the page
/// that shows the list.

struct SessionPageHost: View {
    let appState: AppState
    let services: V2ClientServices
    let chatPane: ChatPaneStore
    let library: DashboardLibrary?
    let sessionID: V2SessionID
    let paneRole: ChatPaneRole
    let showsMenuButton: Bool
    let onMenu: () -> Void
    let onTogglePinned: (Bool) -> Void

    private var sessions: [V2SessionMeta] { library?.sessions ?? appState.sessions }
    private var connectors: [V2Connector] { library?.connectors ?? appState.connectors }

    var body: some View {
        let session = services.sessionRepository.session(id: sessionID)
        let summary = sessions.first { $0.id == sessionID }
        let connectorID = session.metadata?.connectorId ?? summary?.connectorId
        SessionChatView(model: chatPane.pane(for: session, services: services), services: services,
            deviceName: connectors.first { $0.id == connectorID }?.name,
            fallbackTitle: summary?.title,
            fallbackRuntimeName: summary?.runtimeName ?? summary?.runtime,
            paneRole: paneRole,
            onMenu: onMenu,
            showsMenuButton: showsMenuButton,
            onTogglePinned: onTogglePinned)
            .equatable()
            .id(session.presentationKey)
    }
}

struct NewSessionPageHost: View {
    let appState: AppState
    let services: V2ClientServices
    let library: DashboardLibrary?
    let onMenu: () -> Void
    let onOpenDevice: (V2ConnectorID) -> Void
    let onCreated: (V2SessionMeta) -> Void
    let onRefresh: () async -> [V2Connector]

    private var sessions: [V2SessionMeta] { library?.sessions ?? appState.sessions }
    private var connectors: [V2Connector] { library?.connectors ?? appState.connectors }

    var body: some View {
        NewSessionView(model: services.newSession, connectors: connectors, sessions: sessions,
            repository: services.dashboardRepository, library: library,
            dashboardLoading: appState.isDashboardLoading,
            dashboardError: appState.connectorsError,
            onMenu: onMenu,
            onOpenDevice: onOpenDevice,
            onCreated: onCreated,
            onRefresh: onRefresh)
            .equatable()
    }
}

struct DevicePageHost: View {
    let appState: AppState
    let library: DashboardLibrary?
    /// nil opens the tab root: the first online device, else the first device.
    let connectorId: V2ConnectorID?
    let showsMenuButton: Bool
    let onMenu: () -> Void
    let onOpenDevice: (V2ConnectorID) -> Void
    let onCopyDeviceId: (V2ConnectorID) -> Void
    let onOpenSession: (V2SessionID) -> Void
    let onPair: () -> Void
    let onNewSession: (String?) -> Void
    let onNewProjectSession: (String) -> Void
    let onConnectorUpdated: (V2Connector) -> Void
    let onConnectorDeleted: (V2ConnectorID) -> Void
    let onSessionsUpdated: ([V2SessionMeta]) -> Void
    let onSetSessionsArchived: ([V2SessionID], Bool) async -> Bool

    private var connectors: [V2Connector] { library?.connectors ?? appState.connectors }
    private var sessions: [V2SessionMeta] { library?.sessions ?? appState.sessions }
    private var projects: [V2Project] { library?.projects ?? appState.projects }
    private var targetConnectorID: V2ConnectorID? {
        connectorId
            ?? connectors.first { $0.status == .online }?.id
            ?? connectors.first?.id
    }

    var body: some View {
        if let id = targetConnectorID,
           let connector = connectors.first(where: { $0.id == id }),
           let clients = appState.nativeChatServices,
           let service = appState.deviceManagementService,
           let workspaceFilesService = appState.workspaceFilesService,
           let serverURL = appState.serverURL {
            DeviceManagementView(
                connector: connector,
                connectors: connectors,
                allSessions: sessions,
                projects: projects,
                agents: clients.agents(on: id),
                dashboard: clients.dashboardRepository,
                service: service,
                workspaceFilesService: workspaceFilesService,
                serverURL: serverURL,
                onMenu: onMenu,
                showsMenuButton: showsMenuButton,
                onOpenDevice: onOpenDevice,
                onCopyDeviceId: onCopyDeviceId,
                onOpenSession: onOpenSession,
                onPair: onPair,
                onNewSession: onNewSession,
                onNewProjectSession: onNewProjectSession,
                onConnectorUpdated: onConnectorUpdated,
                onConnectorDeleted: onConnectorDeleted,
                onSessionsUpdated: onSessionsUpdated,
                onSetSessionsArchived: onSetSessionsArchived,
                library: library)
                .id(id)
        } else if targetConnectorID != nil
                    || !appState.hasLoadedConnectors
                    || appState.isDashboardLoading {
            // The connector list has not been published yet (library first
            // read, services still being built, or cold-start cache restore):
            // this is a loading state, not "you have no devices".
            ChatShellPlaceholderPage(
                isConnecting: appState.isRetryingServerConnection,
                title: "",
                onOpenSidebar: onMenu,
                showsMenuButton: showsMenuButton)
        } else {
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
                Button(String(localized: "添加设备")) { onPair() }
                    .font(.footnote.weight(.medium))
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(uiColor: CodePageTheme.pageBackgroundUIColor).ignoresSafeArea())
            .modifier(ChatPageToolbar(
                title: String(localized: "Devices"), onMenu: onMenu,
                showsMenuButton: showsMenuButton))
        }
    }
}

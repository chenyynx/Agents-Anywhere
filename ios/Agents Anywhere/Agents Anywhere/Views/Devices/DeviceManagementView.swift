import SwiftUI
import UIKit

/// Native split views already own their safe area; the phone drawer supplies it.
struct DeviceManagementView: View {
    let connector: V2Connector
    /// Every connector in the account, for the top device row.
    let connectors: [V2Connector]
    let allSessions: [V2SessionMeta]
    let projects: [V2Project]
    let agents: DeviceAgentModel
    let dashboard: V2DashboardRepository
    let service: V2DeviceManagementService
    let workspaceFilesService: V2WorkspaceFilesService
    let serverURL: URL
    let onMenu: () -> Void
    /// A pushed page leaves the leading slot to the system back button (and
    /// its native swipe); the root page keeps the drawer hamburger.
    var showsMenuButton = true
    let onOpenDevice: (V2ConnectorID) -> Void
    /// Long-press on a device card copies that device's ID.
    var onCopyDeviceId: (V2ConnectorID) -> Void = { _ in }
    let onOpenSession: (V2SessionID) -> Void
    /// The account-level pairing entry (the sidebar no longer lists devices
    /// in the tab shell).
    var onPair: () -> Void = {}
    let onNewSession: (String?) -> Void
    let onNewProjectSession: (String) -> Void
    let onConnectorUpdated: (V2Connector) -> Void
    let onConnectorDeleted: (V2ConnectorID) -> Void
    let onSessionsUpdated: ([V2SessionMeta]) -> Void
    let onSetSessionsArchived: ([V2SessionID], Bool) async -> Bool

    @State private var model = DeviceManagementModel()
    @AppStorage(ProjectSidebarPreferences.sessionListKey) private var showsSessionList = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.shellTabBarActive) private var shellTabBarActive
    @State private var toasts = ChatToastStore()
    @State private var isRenaming = false
    @State private var proposedName = ""
    @State private var confirmsRotation = false
    @State private var confirmsDeletion = false
    @State private var confirmsArchiveAll = false
    @State private var credential: V2ConnectorRevokeResponse?
    @State private var selectedWorkspace: V2DeviceWorkspace?
    @State private var choosesDirectory = false
    @State private var pendingDirectory: String?
    @State private var createsProject = false
    @State private var editingProject: V2Project?
    @State private var pendingProject: V2Project?
    @State private var projectActionIsDeletion = false
    @State private var showsAgents = false
    @State private var busy = false
    private var deviceProjects: [V2Project] {
        projects.filter { $0.connectorId == connector.id }.sorted {
            if $0.pinned != $1.pinned { return $0.pinned }
            if $0.lastActivityAt != $1.lastActivityAt { return ($0.lastActivityAt ?? "") > ($1.lastActivityAt ?? "") }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
    private var canManage: Bool { dashboard.canWrite && !model.isDeviceActionRunning && !model.isArchiveActionRunning && !busy }
    private var canReadFiles: Bool { dashboard.canWrite && connector.status == .online }
    /// Official FAB sits ~1.3 pt above the home-indicator safe area (2 pt
    /// here). In the tab shell that safe area is the Liquid Glass bar, so the
    /// FAB keeps the composer's 8 pt gap instead of looking pinned to it.
    private var fabBottomPadding: CGFloat {
        shellTabBarActive ? ShellTabBarMetrics.composerGap : 2
    }
    /// One sort per body evaluation: `deviceProjects` is read by the
    /// workspace choices, the project list and the session list, and each
    /// read used to re-filter and re-sort with `localizedStandardCompare`
    /// (the b1664 probe stack that owned a tab-switch stall).
    private func workspaceChoices(_ projects: [V2Project]) -> [WorkspaceDirectoryChoice] {
        WorkspaceDirectoryChoice.recent(connectorID: connector.id, deviceOS: connector.deviceOs,
            home: nil, projects: projects, sessions: model.sessions)
    }
    var body: some View {
        let sortedProjects = deviceProjects
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    deviceSection
                    agentsSection
                    if showsSessionList {
                        DeviceWorkspaceList(workspaces: workspaceChoices(sortedProjects), canReadFiles: canReadFiles,
                            onBrowse: { choosesDirectory = true }, onOpen: openWorkspace,
                            onNewSession: { onNewSession($0.path) })
                    } else {
                        DeviceProjectList(projects: sortedProjects, canManage: canManage, canReadFiles: canReadFiles,
                            onCreate: { createsProject = true },
                            onOpen: { project in
                                openProjectSessions(project)
                                withAnimation(.snappy) { proxy.scrollTo(DeviceSessionAnchor.id, anchor: .top) }
                            },
                            onNewSession: { onNewProjectSession($0.id) }, onFiles: openProjectFiles,
                            onEdit: { editingProject = $0 },
                            onPin: { project in perform { try await dashboard.updateProject(project.id, pinned: !project.pinned) } },
                            onArchive: { pendingProject = $0; projectActionIsDeletion = false },
                            onDelete: { pendingProject = $0; projectActionIsDeletion = true })
                    }
                    DeviceSessionList(model: model, projects: sortedProjects, deviceName: connector.name,
                        showsProjectNames: !showsSessionList, canManage: canManage,
                        onOpen: selectSession,
                        onArchive: { performArchive([$0.id], archived: !$0.archived) },
                        onArchiveAll: { confirmsArchiveAll = true })
                    .id(DeviceSessionAnchor.id)
                }
                .padding(.bottom, 64)
                // Official Code tab insets cards by 16 pt; the shared default
                // is 24 for the chat column (measured 2026-11-23).
                .modifier(ChatPageContentColumn(horizontalInset: 16))
                .background { ChatPageScrollEdge() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The settings cards are white; without the paper page colour the
        // whole page reads as a flat list on white (pp 2026-11-13).
        .background(Color(uiColor: CodePageTheme.pageBackgroundUIColor)
            .ignoresSafeArea())
        .scrollIndicators(.hidden).scrollEdgeEffectStyle(.soft, for: .all)
        .refreshable { await dashboard.refresh(); await agents.refresh() }
        .task(id: agents.connected) { await agents.refresh() }
        // The device identity is persistent in the nav bar (pp 2026-11-23);
        // it no longer waits for the first scroll.
        .modifier(ChatPageToolbar(title: connector.name,
            subtitle: connectionDescription, onMenu: onMenu, showsMenuButton: showsMenuButton))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(String(localized: "添加设备"), systemImage: "plus") { onPair() }
                    Divider()
                    Button(String(localized: "Copy device ID"), systemImage: "doc.on.doc") { UIPasteboard.general.string = connector.id }
                    Divider()
                    Button(String(localized: "Rename device"), systemImage: "pencil") { proposedName = connector.name; isRenaming = true }.disabled(!canManage)
                    Button(String(localized: "Rotate credential"), systemImage: "key") { confirmsRotation = true }.disabled(!canManage)
                    Button(String(localized: "Delete device"), systemImage: "trash", role: .destructive) { confirmsDeletion = true }.disabled(!canManage)
                } label: {
                    AppSymbol("anthropicon.dotsHorizontal", size: 15)
                }.accessibilityLabel(String(localized: "Device actions"))
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if model.isSelectingSessions {
                DeviceSessionSelectionDock(count: model.selectedSessionIds.count,
                    restores: model.sessionFilter == .archived, isWorking: busy, disabled: !canManage,
                    onCancel: model.stopSelectingSessions,
                    onSubmit: { performArchive(Array(model.selectedSessionIds), archived: model.sessionFilter != .archived) })
            }
        }
        .overlay(alignment: .top) {
            ChatErrorToasts(store: toasts, isRetrying: dashboard.isLoading, onRetry: { _ in await dashboard.refresh() })
                .padding(.top, 8)
        }
        .overlay(alignment: .bottomTrailing) {
            if !model.isSelectingSessions {
                DeviceNewSessionFab { onNewSession(nil) }
                    .padding(.trailing, DevicePageStyle.fabTrailing)
                    .padding(.bottom, fabBottomPadding)
            }
        }
        .onChange(of: allSessions, initial: true) { _, values in model.updateSessions(connectorId: connector.id, allSessions: values) }
        .onChange(of: model.errorMessage, initial: true) { _, error in report(error, source: "device") }
        .onChange(of: dashboard.error, initial: true) { _, error in report(error, source: "sync") }
        .onChange(of: agents.error, initial: true) { _, error in report(error, source: "agents") }
        .sheet(isPresented: $showsAgents) {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        DeviceAgentSection(model: agents)
                    }
                    .padding(.horizontal, SettingsStyle.inset)
                    .padding(.top, 10)
                    .padding(.bottom, 40)
                }
                .scrollIndicators(.hidden)
                .background(SettingsStyle.background(colorScheme).ignoresSafeArea())
                .navigationTitle(connector.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { SheetCloseToolbar { showsAgents = false } }
            }
            .appSheetPresentation(.compact)
        }
        .sheet(isPresented: $createsProject) { ProjectEditorSheet(repository: dashboard, connectorID: connector.id) }
        .sheet(item: $editingProject) { ProjectEditorSheet(repository: dashboard, project: $0) }
        .sheet(item: $selectedWorkspace) {
            WorkspaceFilesSheet(connectorId: connector.id, deviceName: connector.name, workspace: $0,
                service: workspaceFilesService, permitsReading: canReadFiles)
        }
        .sheet(isPresented: $choosesDirectory, onDismiss: startDirectorySession) {
            WorkspaceFilesSheet(connectorId: connector.id, deviceName: connector.name,
                workspace: .init(path: "~", name: "", sessionCount: 0, lastActiveAt: nil),
                service: workspaceFilesService, permitsReading: canReadFiles,
                onSelectDirectory: { path in
                    pendingDirectory = path
                    choosesDirectory = false
                })
        }
        .sheet(item: $credential) { ConnectorCredentialSheet(connector: $0.connector, connectorToken: $0.connectorToken, serverURL: serverURL) }
        .alert(String(localized: "Rename device"), isPresented: $isRenaming) {
            TextField(String(localized: "Device name"), text: $proposedName)
            Button(String(localized: "Cancel"), role: .cancel) {}
            Button(String(localized: "Save")) { Task { await renameDevice() } }
                .disabled(proposedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !canManage)
        }
        .alert(String(localized: "Rotate connector credential?"), isPresented: $confirmsRotation) {
            Button(String(localized: "Cancel"), role: .cancel) {}
            Button(String(localized: "Rotate credential"), role: .destructive) { Task { await rotateCredential() } }
        } message: { Text(String(localized: "The current desktop Connector will disconnect. Replace its saved token with the new credential before reconnecting.")) }
        .alert(String(localized: "Delete this device?"), isPresented: $confirmsDeletion) {
            Button(String(localized: "Cancel"), role: .cancel) {}
            Button(String(localized: "Delete device"), role: .destructive) { Task { await deleteDevice() } }
        } message: { Text(String(localized: "This will permanently remove \(connector.name) and all its associated data. This action cannot be undone.")) }
        .alert(model.sessionFilter == .archived ? String(localized: "Restore these sessions?") : String(localized: "Archive these sessions?"), isPresented: $confirmsArchiveAll) {
            Button(String(localized: "Cancel"), role: .cancel) {}
            Button(model.sessionFilter == .archived ? String(localized: "Restore") : String(localized: "Archive")) { archiveAll() }
        } message: { Text(String(localized: "This applies to all sessions in the selected scope, including those not loaded yet.")) }
        .alert(projectActionIsDeletion ? String(localized: "Delete project?") : String(localized: "Archive project sessions?"), isPresented: Binding(
            get: { pendingProject != nil }, set: { if !$0 { pendingProject = nil } })) {
            Button(String(localized: "Cancel"), role: .cancel) { pendingProject = nil }
            Button(projectActionIsDeletion ? String(localized: "Delete") : String(localized: "Archive"), role: .destructive) {
                guard let project = pendingProject else { return }; pendingProject = nil
                let deletesProject = projectActionIsDeletion
                perform {
                    if deletesProject { try await dashboard.deleteProject(project.id) }
                    else { try await dashboard.archiveProject(project.id, archived: true) }
                }
            }
        } message: {
            Text(projectActionIsDeletion ? String(localized: "Only empty projects can be deleted. Files on the device are kept.") :
                String(localized: "Archive all sessions in \(pendingProject?.name ?? "")? The project will remain available for future sessions."))
        }
    }

    /// The official Code tab's first section: every device in the account as a
    /// card, with the current one outlined. Tapping another card opens it.
    private var deviceSection: some View {
        DeviceSection(String(localized: "设备")) {
            EmptyView()
        } content: {
            ScrollView(.horizontal) {
                HStack(spacing: DevicePageStyle.cardGap) {
                    ForEach(connectors) { item in
                        DeviceIdentityCard(connector: item, isCurrent: item.id == connector.id) {
                            guard item.id != connector.id else { return }
                            onOpenDevice(item.id)
                        }
                        .contextMenu {
                            if item.id != connector.id {
                                Button { onOpenDevice(item.id) } label: {
                                    Label(String(localized: "Open"), menuSymbol: "anthropicon.folderOpen")
                                }
                                Divider()
                            }
                            Button { onCopyDeviceId(item.id) } label: {
                                Label(String(localized: "Copy device ID"), menuSymbol: "anthropicon.copy")
                            }
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.hidden)
            .scrollClipDisabled(true)
        }
    }

    /// Agents are configuration, not the page's browsing task; they keep a
    /// one-line entry and open the full sheet.
    private var agentsSection: some View {
        DeviceSection(String(localized: "Agents")) {
            AgentRediscoveryButton(model: agents)
        } content: {
            DeviceAgentsEntry(model: agents) { showsAgents = true }
        }
    }

    private var connectionDescription: String {
        let status = !dashboard.canWrite ? String(localized: "Showing cached content") :
            connector.status == .online ? String(localized: "Online") : String(localized: "Device offline")
        return [connector.deviceOs, status].compactMap { $0 }.joined(separator: " · ")
    }
    private func report(_ message: String?, source: String) {
        toasts.update(source: source, failure: message.map { .init(kind: .rejected, message: $0) })
    }
    private func openProjectSessions(_ project: V2Project) {
        model.selectProject(project.id); model.setSessionFilter(.active)
    }
    private func openProjectFiles(_ project: V2Project) {
        selectedWorkspace = .init(path: project.workspacePath, name: project.name,
            sessionCount: project.activeSessionCount, lastActiveAt: project.lastActivityAt)
    }
    private func openWorkspace(_ workspace: WorkspaceDirectoryChoice) {
        selectedWorkspace = .init(path: workspace.path, name: workspace.name,
            sessionCount: 0, lastActiveAt: nil)
    }
    private func startDirectorySession() {
        guard let path = pendingDirectory else { return }
        pendingDirectory = nil
        onNewSession(path)
    }
    private func selectSession(_ id: String) {
        if model.isSelectingSessions { model.toggleSessionSelection(id) } else { onOpenSession(id) }
    }
    private func perform(_ operation: @escaping () async throws -> Void) {
        guard canManage else { return }; busy = true
        Task {
            defer { busy = false }
            do { try await operation(); report(nil, source: "action") }
            catch { report(error.localizedDescription, source: "action") }
        }
    }
    private func performArchive(_ ids: [String], archived: Bool) {
        guard !ids.isEmpty, canManage else { return }; busy = true
        Task {
            defer { busy = false }
            if await onSetSessionsArchived(ids, archived) { model.stopSelectingSessions() }
        }
    }
    private func archiveAll() {
        guard canManage else { return }
        if let id = model.projectID {
            let archived = model.sessionFilter != .archived
            perform { try await dashboard.archiveProject(id, archived: archived) }
        } else {
            Task {
                if let sessions = await model.archiveSessions(connectorId: connector.id,
                    archived: model.sessionFilter != .archived, service: service) { onSessionsUpdated(sessions) }
            }
        }
    }
    private func renameDevice() async {
        guard canManage else { return }
        if let updated = await model.renameConnector(connectorId: connector.id, name: proposedName, service: service) { onConnectorUpdated(updated) }
    }
    private func rotateCredential() async {
        guard canManage else { return }
        credential = await model.revokeConnector(connectorId: connector.id, service: service)
        if let credential { onConnectorUpdated(credential.connector) }
    }
    private func deleteDevice() async {
        guard canManage else { return }
        if await model.deleteConnector(connectorId: connector.id, service: service) { onConnectorDeleted(connector.id) }
    }
}

private enum DeviceSessionAnchor { static let id = "device.sessions" }

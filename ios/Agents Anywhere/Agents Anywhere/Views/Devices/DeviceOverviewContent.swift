import SwiftUI
import UIKit

/// Web shows six project cards and a "show all" toggle; a phone column fits four.
private let collapsedDirectoryCount = 4

struct DeviceProjectList: View {
    let projects: [V2Project]
    let canManage: Bool
    let canReadFiles: Bool
    let onCreate: () -> Void
    let onOpen: (V2Project) -> Void
    let onNewSession: (V2Project) -> Void
    let onFiles: (V2Project) -> Void
    let onEdit: (V2Project) -> Void
    let onPin: (V2Project) -> Void
    let onArchive: (V2Project) -> Void
    let onDelete: (V2Project) -> Void
    @State private var expanded = false

    private var visible: [V2Project] {
        expanded ? projects : Array(projects.prefix(collapsedDirectoryCount))
    }

    var body: some View {
        DeviceSection(String(localized: "Projects")) {
            DeviceHeaderIconButton(title: String(localized: "Create project"), symbol: "plus", action: onCreate)
                .disabled(!canManage)
        } content: {
            VStack(alignment: .leading, spacing: DevicePageStyle.cardGap) {
                if projects.isEmpty {
                    DeviceEmptyCard(text: String(localized: "No projects yet"))
                } else {
                    ForEach(visible) { project in
                        DeviceDirectoryCard(name: project.name, path: project.workspacePath,
                            pinned: project.pinned, canOpen: true,
                            openHint: String(localized: "Show project sessions"),
                            onOpen: { onOpen(project) }, onNewSession: { onNewSession(project) })
                        .contextMenu {
                            Button(String(localized: "New session"), systemImage: "square.and.pencil") { onNewSession(project) }
                            Button(String(localized: "Files"), systemImage: "folder") { onFiles(project) }.disabled(!canReadFiles)
                            Divider()
                            Button(String(localized: "Rename project"), systemImage: "pencil") { onEdit(project) }.disabled(!canManage)
                            Button(project.pinned ? String(localized: "Unpin") : String(localized: "Pin"), systemImage: "pin") { onPin(project) }.disabled(!canManage)
                            Button(String(localized: "Copy path"), systemImage: "doc.on.doc") { UIPasteboard.general.string = project.workspacePath }
                            Divider()
                            Button(String(localized: "Archive project sessions"), systemImage: "archivebox") { onArchive(project) }.disabled(!canManage)
                            Button(String(localized: "Delete project"), systemImage: "trash", role: .destructive) { onDelete(project) }
                                .disabled(!canManage || project.sidebarSessionCounts.active + project.sidebarSessionCounts.archived > 0)
                        }
                    }
                    if projects.count > collapsedDirectoryCount {
                        DeviceShowAllButton(expanded: $expanded, count: projects.count - collapsedDirectoryCount)
                    }
                }
            }
        }
    }
}

struct DeviceWorkspaceList: View {
    let workspaces: [WorkspaceDirectoryChoice]
    let canReadFiles: Bool
    let onBrowse: () -> Void
    let onOpen: (WorkspaceDirectoryChoice) -> Void
    let onNewSession: (WorkspaceDirectoryChoice) -> Void
    @State private var expanded = false

    private var visible: [WorkspaceDirectoryChoice] {
        expanded ? workspaces : Array(workspaces.prefix(collapsedDirectoryCount))
    }

    var body: some View {
        DeviceSection(String(localized: "工作目录")) {
            DeviceHeaderIconButton(title: String(localized: "选择工作目录"), symbol: "plus", action: onBrowse)
                .disabled(!canReadFiles)
        } content: {
            VStack(alignment: .leading, spacing: DevicePageStyle.cardGap) {
                if workspaces.isEmpty {
                    DeviceEmptyCard(text: String(localized: "No workspaces yet"))
                } else {
                    ForEach(visible) { workspace in
                        DeviceDirectoryCard(name: workspace.name, path: workspace.path,
                            canOpen: canReadFiles, openHint: String(localized: "Files"),
                            onOpen: { onOpen(workspace) }, onNewSession: { onNewSession(workspace) })
                        .contextMenu {
                            Button(String(localized: "New session"), systemImage: "square.and.pencil") { onNewSession(workspace) }
                            Button(String(localized: "Files"), systemImage: "folder") { onOpen(workspace) }.disabled(!canReadFiles)
                            Button(String(localized: "Copy path"), systemImage: "doc.on.doc") { UIPasteboard.general.string = workspace.path }
                        }
                    }
                    if workspaces.count > collapsedDirectoryCount {
                        DeviceShowAllButton(expanded: $expanded, count: workspaces.count - collapsedDirectoryCount)
                    }
                }
            }
        }
    }
}

/// The "show all N more" text button that sits under a collapsed card list.
struct DeviceShowAllButton: View {
    @Binding var expanded: Bool
    let count: Int
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button {
            withAnimation(.snappy) { expanded.toggle() }
        } label: {
            HStack(spacing: 4) {
                Text(expanded
                    ? String(localized: "Show less")
                    : String(localized: "Show all \(count) more"))
                AppSymbol("chevron.down", size: 12)
                    .rotationEffect(.degrees(expanded ? 180 : 0))
                Spacer(minLength: 0)
            }
            .font(SettingsStyle.text(15))
            .foregroundStyle(SettingsStyle.secondary(colorScheme))
            .padding(.horizontal, 4)
            .frame(minHeight: 32)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

struct DeviceSessionList: View {
    @Bindable var model: DeviceManagementModel
    let projects: [V2Project]
    let deviceName: String
    let showsProjectNames: Bool
    let canManage: Bool
    let onOpen: (String) -> Void
    let onArchive: (V2SessionMeta) -> Void
    let onArchiveAll: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    private var restores: Bool { model.sessionFilter == .archived }
    private var isEmpty: Bool { model.filteredSessions.isEmpty }

    var body: some View {
        DeviceSection(String(localized: "Sessions")) {
            HStack(spacing: 10) {
                scopeMenu
                Menu {
                    Button(model.isSelectingSessions
                        ? String(localized: "Cancel")
                        : String(localized: "Select sessions")) {
                        if model.isSelectingSessions { model.stopSelectingSessions() } else { model.startSelectingSessions() }
                    }
                    .disabled(!canManage || (isEmpty && !model.isSelectingSessions))
                    if !model.isSelectingSessions {
                        Button(restores
                            ? String(localized: "Restore all in scope")
                            : String(localized: "Archive all in scope")) { onArchiveAll() }
                            .disabled(!canManage || isEmpty)
                    }
                } label: {
                    AppSymbol("ellipsis", size: 17)
                        .foregroundStyle(SettingsStyle.ink(colorScheme))
                        .frame(width: 32, height: 32)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "Sessions actions"))
            }
        } content: {
            VStack(alignment: .leading, spacing: DevicePageStyle.cardGap) {
                filters.padding(.horizontal, 2)
                if model.isSelectingSessions {
                    Button(String(localized: "Select up to 200 sessions"), action: model.toggleSelectAll)
                        .font(SettingsStyle.text(15))
                        .buttonStyle(.plain)
                        .foregroundStyle(SettingsStyle.secondary(colorScheme))
                        .frame(minHeight: 32)
                        .padding(.horizontal, 2)
                        .disabled(!canManage)
                }
                if isEmpty {
                    DeviceEmptyCard(text: String(localized: "No sessions here"))
                } else {
                    ForEach(model.filteredSessions) { session in
                        DeviceSessionCard(session: session, deviceName: deviceName,
                            projectName: scopeSubtitle(session),
                            isSelecting: model.isSelectingSessions,
                            selected: model.selectedSessionIds.contains(session.id),
                            canManage: canManage,
                            onTap: { select(session) },
                            onArchive: { onArchive(session) })
                    }
                }
            }
        }
    }

    private var filters: some View {
        DeviceFilterTags(values: V2DeviceSessionFilter.allCases,
            selection: Binding(get: { model.sessionFilter }, set: model.setSessionFilter)) { String(localized: $0.title) }
    }

    /// The official "Alle ⌄" control: the project/workspace scope in the
    /// section header, dark ink rather than a grey chip.
    private var scopeMenu: some View {
        Menu {
            Picker(showsProjectNames ? String(localized: "Project") : String(localized: "工作目录"),
                selection: Binding(get: { model.projectID }, set: model.selectProject)) {
                Text(allScopesTitle).tag(String?.none)
                ForEach(projects) {
                    Text(showsProjectNames ? $0.name : $0.workspacePath).tag(Optional($0.id))
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(scopeTitle)
                    .font(SettingsStyle.text(16, weight: .medium))
                    .foregroundStyle(SettingsStyle.ink(colorScheme))
                    .lineLimit(1)
                AppSymbol("chevron.down", size: 12)
                    .foregroundStyle(SettingsStyle.ink(colorScheme))
            }
            .frame(minHeight: 32)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(showsProjectNames ? String(localized: "Project") : String(localized: "工作目录"))
    }

    private func select(_ session: V2SessionMeta) {
        if model.isSelectingSessions { model.toggleSessionSelection(session.id) } else { onOpen(session.id) }
    }

    private var allScopesTitle: String {
        showsProjectNames ? String(localized: "All projects") : String(localized: "All workspaces")
    }
    private var scopeTitle: String {
        guard let project = projects.first(where: { $0.id == model.projectID }) else { return allScopesTitle }
        return showsProjectNames ? project.name : ProjectWorkspacePath.name(project.workspacePath)
    }
    private func scopeSubtitle(_ session: V2SessionMeta) -> String? {
        let project = projects.first { $0.id == session.projectId }
        if showsProjectNames { return project?.name }
        return (session.cwd ?? project?.workspacePath).map(ProjectWorkspacePath.name)
    }
}

struct DeviceSessionSelectionDock: View {
    let count: Int
    let restores: Bool
    let isWorking: Bool
    let disabled: Bool
    let onCancel: () -> Void
    let onSubmit: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            Text("\(count) selected").font(.subheadline).monospacedDigit()
            Spacer(minLength: 0)
            Button(String(localized: "Cancel"), action: onCancel).disabled(isWorking)
            AppGlassButton(restores ? String(localized: "dashboard.device.unarchiveSelected") : String(localized: "dashboard.device.archiveSelected"), systemImage: restores ? "tray.and.arrow.up" : "archivebox",
                style: .prominent, isLoading: isWorking, disabled: disabled || count == 0, maxWidth: nil, action: onSubmit)
        }
        .padding(14).glassEffect(.regular, in: .rect(cornerRadius: 24))
        .padding(.horizontal, 24).padding(.bottom, 12).frame(maxWidth: 760).frame(maxWidth: .infinity)
    }
}

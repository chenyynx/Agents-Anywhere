import SwiftUI

struct ChatSidebarProjects: View {
    @Environment(\.colorScheme) private var colorScheme

    @Bindable var repository: V2DashboardRepository
    @Binding var showsSessionList: Bool
    let selectedSessionID: String?
    let onShowArchives: () -> Void
    let onNewSession: (String) -> Void
    let onOpenSession: (String) -> Void
    let onRenameSession: (String, String) -> Void
    let onPinSession: (String, Bool) -> Void
    let onArchiveSession: (String) -> Void
    let onCopySession: (String) -> Void
    @State private var filter = V2DeviceSessionFilter.active
    @State private var createsProject = false
    @State private var editing: V2Project?
    @State private var action: ProjectAction?
    @State private var busy: Set<String> = []
    @State private var error: String?
    @State private var expandedSessionLists: Set<String> = []
    /// Sessions shown per expanded project before "show more", matching Web.
    private static let sessionPreview = 8

    private struct ProjectAction: Identifiable {
        let project: V2Project
        let deletes: Bool
        var id: String { project.id }
    }
    var body: some View {
        let projects = ProjectSidebarPresentation.projects(repository.projects, filter: filter, sessions: repository.sessions)
        let unassigned = ProjectSidebarPresentation.unassignedSessions(repository.sessions, projects: repository.projects, filter: filter)
        // Capture the value in this body, then pass it through the lazy builders.
        // Pinning moves a row between sections before the request clears busy;
        // cached row content must receive that final state change explicitly.
        let busyProjects = busy
        LazyVStack(alignment: .leading, spacing: 2) {
            if projects.contains(where: \.pinned) {
                Text(String(localized: "置顶项目"))
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(AppTheme.sidebarRowText(colorScheme))
                    .padding(.horizontal, 10).padding(.top, 16).padding(.bottom, 6)
                projectList(projects.filter(\.pinned), busyProjects: busyProjects)
            }
            HStack {
                Button { repository.sidebarPreferences.projectsExpanded.toggle() } label: {
                    HStack(spacing: 6) {
                        Text(String(localized: "项目"))
                        AppSymbol("chevron.right", size: 12)
                            .rotationEffect(.degrees(repository.sidebarPreferences.projectsExpanded ? 90 : 0))
                    }
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(AppTheme.sidebarRowText(colorScheme))
                    .frame(minHeight: 44).contentShape(.rect)
                }.buttonStyle(.plain)
                Spacer()
                ChatSidebarListMenu(showsSessionList: $showsSessionList, onShowArchives: onShowArchives) {
                    Picker(String(localized: "会话"), selection: $filter) {
                        ForEach(V2DeviceSessionFilter.allCases) { Text($0.title).tag($0) }
                    }
                }
                Button { createsProject = true } label: {
                    Image("aa-IconAdd")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 13, height: 13)
                        .foregroundStyle(AppTheme.sidebarRowText(colorScheme))
                        .frame(width: 44, height: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .disabled(!repository.canWrite)
                .accessibilityLabel(Text(String(localized: "创建项目")))
            }.padding(.horizontal, 10).padding(.top, 16)
            if repository.sidebarPreferences.projectsExpanded {
                projectList(projects.filter { !$0.pinned }, busyProjects: busyProjects)
                if repository.isLoading && repository.projects.isEmpty { ProgressView().padding(12) }
                if repository.hasLoaded && repository.projects.isEmpty {
                    Text(String(localized: "创建一个项目，开始新的任务。"))
                        .font(.footnote).foregroundStyle(.secondary).padding(10)
                }
            }
            if !unassigned.isEmpty {
                Text(String(localized: "未分组会话"))
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(AppTheme.sidebarRowText(colorScheme))
                    .padding(.horizontal, 10).padding(.top, 16).padding(.bottom, 6)
                sessionRows(unassigned, inset: false)
            }
        }
        .sheet(isPresented: $createsProject) {
            ProjectEditorSheet(repository: repository) {
                repository.sidebarPreferences.expandedProjects.insert($0.id)
                repository.sidebarPreferences.projectsExpanded = true
            }
        }
        .sheet(item: $editing) { ProjectEditorSheet(repository: repository, project: $0) }
        .alert(action?.deletes == true ? String(localized: "删除项目？") : String(localized: "归档这个项目的会话？"), isPresented: Binding(
            get: { action != nil }, set: { if !$0 { action = nil } })) {
            Button(String(localized: "取消"), role: .cancel) { action = nil }
            Button(action?.deletes == true ? String(localized: "删除") : String(localized: "归档"), role: .destructive) {
                guard let pending = action else { return }
                action = nil
                perform(pending.project.id) {
                    if pending.deletes { try await repository.deleteProject(pending.project.id) }
                    else { try await repository.archiveProject(pending.project.id, archived: true) }
                }
            }
        } message: {
            Text(action?.deletes == true ? String(localized: "只有没有会话的项目可以删除，设备上的文件会保留。") : String(localized: "Archive all sessions in \(action?.project.name ?? "")? The project will remain available for future sessions."))
        }
        .alert(String(localized: "操作未完成"), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button(String(localized: "好")) { error = nil }
        } message: { Text(error ?? "") }
    }

    private var expanded: Set<String> { repository.sidebarPreferences.expandedProjects }

    private func projectList(_ values: [V2Project], busyProjects: Set<String>) -> some View {
        ForEach(values) { project in
            projectRow(project, isBusy: busyProjects.contains(project.id))
            if expanded.contains(project.id) { projectSessions(project) }
        }
    }

    private func projectRow(_ project: V2Project, isBusy: Bool) -> some View {
        // Same row template as the chat list: 20pt icon at x=27, 15pt title,
        // 48pt row; the trailing action stays a chrome-less 20pt glyph.
        HStack(spacing: 0) {
            Button { toggleProject(project.id) } label: {
                HStack(spacing: 14) {
                    Image(expanded.contains(project.id) ? "aa-IconFolderOpen" : "aa-IconFolder")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 20, height: 20)
                        .foregroundStyle(AppTheme.sidebarRowText(colorScheme))
                    Text(project.name)
                        .font(.system(size: 15, weight: .regular))
                        .foregroundStyle(AppTheme.sidebarTextPrimary(colorScheme))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if isBusy { ProgressView().controlSize(.mini) }
                }
                .padding(.leading, 11)
                .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading).contentShape(.rect)
            }
            .accessibilityHint(expanded.contains(project.id) ? String(localized: "收起项目") : String(localized: "展开项目"))
            Button { onNewSession(project.id) } label: {
                Image("aa-IconAdd")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 13, height: 13)
                    .foregroundStyle(AppTheme.sidebarRowText(colorScheme))
                    .frame(width: 44, height: 44).contentShape(.rect)
            }
            .accessibilityLabel(Text(String(localized: "在 \(project.name) 中新建会话")))
        }
        .buttonStyle(.plain)
        .contentShape(.rect)
        .contextMenu { projectMenu(project, isBusy: isBusy) }
    }

    @ViewBuilder
    private func projectMenu(_ project: V2Project, isBusy: Bool) -> some View {
        let deviceName = repository.connectors.first { $0.id == project.connectorId }?.name ?? String(localized: "设备不可用")
        Section(deviceName) {
            Button { onNewSession(project.id) } label: {
                Label(String(localized: "新建会话"), menuSymbol: "anthropicon.add")
            }
            Button { editing = project } label: {
                Label(String(localized: "编辑项目"), menuSymbol: "anthropicon.edit")
            }
            .disabled(!repository.canWrite || isBusy)
            Button {
                perform(project.id) { try await repository.updateProject(project.id, pinned: !project.pinned) }
            } label: {
                Label(project.pinned ? String(localized: "取消置顶") : String(localized: "置顶"),
                      menuSymbol: "anthropicon.pin")
            }
            .disabled(!repository.canWrite || isBusy)
        }
        Section {
            Button(role: .destructive) { action = .init(project: project, deletes: false) } label: {
                Label(String(localized: "归档项目会话"), menuSymbol: "anthropicon.archive", destructive: true)
            }
            .disabled(!repository.canWrite || isBusy)
            Button(role: .destructive) { action = .init(project: project, deletes: true) } label: {
                Label(String(localized: "删除项目"), menuSymbol: "anthropicon.trash", destructive: true)
            }
            .disabled(!repository.canWrite || isBusy)
        }
    }

    @ViewBuilder
    private func projectSessions(_ project: V2Project) -> some View {
        let sessions = ProjectSidebarPresentation.sessions(repository.sessions, projectID: project.id, filter: filter)
        let showsAll = expandedSessionLists.contains(project.id)
        // Keep the open session visible even when it sorts past the preview.
        let visible = showsAll || sessions.count <= Self.sessionPreview ? sessions
            : sessions.enumerated().filter { $0.offset < Self.sessionPreview || $0.element.id == selectedSessionID }.map(\.element)
        sessionRows(visible, inset: true)
        if sessions.count > Self.sessionPreview {
            Button {
                if showsAll { expandedSessionLists.remove(project.id) } else { expandedSessionLists.insert(project.id) }
            } label: {
                Text(showsAll ? String(localized: "收起") : String(localized: "显示更多（\(sessions.count - visible.count)）"))
                    .font(.footnote).foregroundStyle(.secondary)
                    .padding(.leading, 19)
                    .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading).contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
    }
    private func sessionRows(_ sessions: [V2SessionMeta], inset: Bool) -> some View {
        LazyVStack(alignment: .leading, spacing: 2) {
            ForEach(sessions) { session in
                ChatSidebarSessionRow(session: .init(session: session), isSelected: selectedSessionID == session.id,
                    inset: inset,
                    onOpen: { onOpenSession(session.id) }, onRename: { onRenameSession(session.id, $0) },
                    onTogglePinned: { onPinSession(session.id, !session.pinned) }, onArchive: { onArchiveSession(session.id) },
                    onCopyId: { onCopySession(session.id) })
            }
        }
    }
    private func toggleProject(_ id: String) {
        if expanded.contains(id) { repository.sidebarPreferences.expandedProjects.remove(id) }
        else { repository.sidebarPreferences.expandedProjects.insert(id) }
    }
    private func perform(_ id: String, operation: @escaping () async throws -> Void) {
        guard !busy.contains(id) else { return }
        busy.insert(id)
        Task {
            defer { busy.remove(id) }
            do { try await operation() } catch { self.error = error.localizedDescription }
        }
    }
}

struct ArchivedSessionsSheet: View {
    let repository: V2DashboardRepository
    let onOpen: (String) -> Void
    let onRestore: (String) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var busy: Set<String> = []
    @State private var restoreError = false
    var body: some View {
        NavigationStack {
            List {
                ForEach(ProjectSidebarPresentation.sessions(repository.sessions, projectID: nil, filter: .archived)) { session in
                    HStack {
                        Button { dismiss(); onOpen(session.id) } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(session.title ?? String(localized: "未命名会话")).foregroundStyle(.primary).lineLimit(2)
                                Text(repository.projects.first { $0.id == session.projectId }?.name ?? session.cwd ?? "")
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }.buttonStyle(.plain)
                        Spacer()
                        Button {
                            busy.insert(session.id)
                            Task { let restored = await onRestore(session.id); busy.remove(session.id); restoreError = !restored }
                        } label: {
                            if busy.contains(session.id) { ProgressView() }
                            else { AppSymbol("tray.and.arrow.up") }
                        }.buttonStyle(.borderless).disabled(busy.contains(session.id) || !repository.canWrite)
                            .accessibilityLabel(String(localized: "恢复会话"))
                    }
                }
            }
            .navigationTitle(String(localized: "归档会话")).navigationBarTitleDisplayMode(.inline)
            .toolbar { SheetCloseToolbar { dismiss() } }
            .refreshable { await repository.refresh() }
        }
        .appSheetPresentation(.compact)
        .alert(String(localized: "无法恢复会话，请稍后重试。"), isPresented: $restoreError) { Button(String(localized: "好"), role: .cancel) {} }
    }
}

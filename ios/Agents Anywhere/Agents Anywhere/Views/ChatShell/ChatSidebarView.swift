import QuartzCore
import SwiftUI

struct ChatSidebarView: View {
    /// Passed as plain values: the sidebar must not re-evaluate for every
    /// published AppState change. The session lists are read here instead of
    /// being passed down, so a dashboard snapshot re-evaluates the sidebar —
    /// not the shell root that owns this view.
    let appState: AppState
    let agentSetup: AgentSetupCoordinator?
    let safeAreaInsets: EdgeInsets
    /// The local-database dashboard source; nil falls back to the legacy
    /// AppState projection.
    let library: DashboardLibrary?
    /// The phone tab shell has a Devices tab; the sidebar duplicates it only
    /// where that tab does not exist (iPad / the legacy shell).
    var showsDevicesSection = true
    let repository: V2DashboardRepository?
    let onNewProjectSession: (String) -> Void
    let onRestoreSession: (String) async -> Bool
    let account: ChatSidebarAccount?
    /// The tab shell's device tab, if that is the active shell. The default
    /// device is resolved here, from the library/AppState connectors, so the
    /// shell root does not read the connector list.
    let devicesTabActive: Bool
    let devicesTabDeviceId: V2ConnectorID?
    /// The legacy (drawer) shell's selected device.
    let legacyDeviceId: V2ConnectorID?
    let selectedSessionId: V2SessionID?
    let isLoadingDevices: Bool
    let isLoadingSessions: Bool
    let onNewSession: () -> Void
    let onOpenDevice: (V2ConnectorID) -> Void
    let onOpenSession: (V2SessionID) -> Void
    let onRenameSession: (V2SessionID, String) -> Void
    let onToggleSessionPinned: (V2SessionID, Bool) -> Void
    let onArchiveSession: (V2SessionID) -> Void
    let onCopyDeviceId: (V2ConnectorID) -> Void
    let onCopySessionId: (V2SessionID) -> Void

    @State private var isShowingPairing = false
    @State private var showsArchives = false
    /// "Recent" shows a fixed ten rows (pp 2026-11-26).
    private static let recentPreviewLimit = 10
    @AppStorage(ProjectSidebarPreferences.sessionListKey) private var showsSessionList = false
    /// Flat list only: one line per session, without the project · device line.
    @AppStorage(ProjectSidebarPreferences.compactSessionListKey) private var compactSessionList = false

    /// Official sidebar content inset: 16pt (1.261109 screenshots: the
    /// selection block spans 16..304pt inside a 320pt drawer).
    private static let contentInset: CGFloat = 16

    @Environment(\.colorScheme) private var colorScheme

    private var visibleSessions: [ChatSidebarSession] {
        #if AA_TIMELINE_PROBE
        let started = CACurrentMediaTime()
        defer {
            TimelineProbeStore.shared.noteShellSessions(seconds: CACurrentMediaTime() - started)
        }
        #endif
        let sessions = library?.sessions ?? appState.sessions
        return sessions.filter { !$0.archived }
            .map { ChatSidebarSession(session: $0) }
            .sorted { $0.presentation.precedes($1.presentation, id: $0.id, otherID: $1.id) }
    }
    private var devicesList: [ChatSidebarDevice] {
        (library?.connectors ?? appState.connectors).map { ChatSidebarDevice(connector: $0) }
    }
    private var selectedDeviceId: V2ConnectorID? {
        guard devicesTabActive else { return legacyDeviceId }
        return devicesTabDeviceId
            ?? devicesList.first { $0.presence == .online }?.id
            ?? devicesList.first?.id
    }
    var body: some View {
        // One filter+sort pass per body: reading `visibleSessions` twice would
        // sort the whole list twice on every snapshot.
        let sessions = visibleSessions
        let pinned = sessions.filter(\.pinned)
        let recent = sessions.filter { !$0.pinned }
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                if showsDevicesSection {
                    ChatSidebarDeviceSection(
                        devices: devicesList,
                        selectedDeviceId: selectedDeviceId,
                        isLoading: isLoadingDevices,
                        onOpen: onOpenDevice,
                        onCopyId: onCopyDeviceId,
                        onPair: startPairing
                    )
                }

                if let setup = agentSetup {
                    ForEach(setup.requests) { request in
                        HStack {
                            if request.ready { AppSymbol("checkmark.circle") }
                            else if request.error == nil { ProgressView().controlSize(.small) }
                            VStack(alignment: .leading) {
                                Text(request.connector.name).font(.subheadline)
                                Text(request.ready ? String(localized: "设备已连接") : request.error ?? String(localized: "等待设备连接…"))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            Menu {
                                if request.ready { Button(String(localized: "配置 Agent")) { setup.configure(request.id) } }
                                if request.error != nil { Button(String(localized: "重试")) { setup.retry(request.id) } }
                                Button(request.ready ? String(localized: "稍后配置") : String(localized: "停止等待")) { setup.finish(request.id) }
                            } label: { AppSymbol("anthropicon.dotsHorizontal", size: 15).frame(width: 36, height: 36) }
                        }.padding(.horizontal, 10).padding(.vertical, 8)
                    }
                }

                if !pinned.isEmpty {
                    ChatSidebarSessionSection(
                        title: "Pinned",
                        sessions: pinned,
                        selectedSessionId: selectedSessionId,
                        emptyMessage: "No pinned sessions",
                        context: showsSessionList && !compactSessionList ? { sessionContext($0, after: $1) } : nil,
                        onOpen: onOpenSession,
                        onRename: onRenameSession,
                        onTogglePinned: onToggleSessionPinned,
                        onArchive: onArchiveSession,
                        onCopyId: onCopySessionId
                    )
                }

                if let repository {
                    if showsSessionList {
                        HStack {
                            Text("Recent")
                                .font(.system(size: 13, weight: .regular))
                                .foregroundStyle(AppTheme.sidebarRowText(colorScheme))
                            Spacer()
                            ChatSidebarListMenu(showsSessionList: $showsSessionList,
                                onShowArchives: { showsArchives = true }) {}
                        }
                        // Matched to the official drawer's ink gaps around
                        // this header (3x screenshot: 39.7pt above, 32.3pt
                        // below; we drew 57.7/43.3 because the ⋯ menu's 44pt
                        // tap target centres the title 13pt low).
                        .padding(.horizontal, 10).padding(.top, 2).padding(.bottom, -5)
                        ChatSidebarSessionSection(
                            title: nil,
                            sessions: Array(recent.prefix(Self.recentPreviewLimit)),
                            selectedSessionId: selectedSessionId,
                            isLoading: isLoadingSessions,
                            emptyMessage: "No sessions yet",
                            context: compactSessionList ? nil : { sessionContext($0, after: $1) },
                            onOpen: onOpenSession,
                            onRename: onRenameSession,
                            onTogglePinned: onToggleSessionPinned,
                            onArchive: onArchiveSession,
                            onCopyId: onCopySessionId
                        )
                    } else {
                        ChatSidebarProjects(repository: repository, library: library, showsSessionList: $showsSessionList,
                            selectedSessionID: selectedSessionId, onShowArchives: { showsArchives = true },
                            onNewSession: onNewProjectSession, onOpenSession: onOpenSession,
                            onRenameSession: onRenameSession, onPinSession: onToggleSessionPinned,
                            onArchiveSession: onArchiveSession, onCopySession: onCopySessionId)
                    }
                }

            }
            .padding(.leading, safeAreaInsets.leading + Self.contentInset)
            .padding(.trailing, safeAreaInsets.trailing + Self.contentInset)
            .padding(.top, 10)
            .padding(.bottom, safeAreaInsets.bottom + 82)
        }
        .refreshable { await repository?.refresh() }
        .scrollIndicators(.hidden)
        .scrollEdgeEffectStyle(.soft, for: .bottom)
        .overlay(alignment: .bottom) {
            if let account {
                ChatSidebarBottomControls(
                    appState: appState,
                    account: account,
                    onNewSession: onNewSession
                )
                    .padding(.leading, safeAreaInsets.leading + 28)
                    .padding(.trailing, safeAreaInsets.trailing + 28)
                    .padding(.bottom, 28)
            }
        }
        .sheet(isPresented: $showsArchives) {
            if let repository { ArchivedSessionsSheet(repository: repository, onOpen: onOpenSession, onRestore: onRestoreSession) }
        }
        .sheet(isPresented: $isShowingPairing, onDismiss: {
            agentSetup?.pairingFormPresented = false
        }) {
            PairDeviceSheet()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func startPairing() {
        agentSetup?.pairingFormPresented = true
        isShowingPairing = true
    }

    /// Web's flat-list second line: project first, then the device, which
    /// collapses to `^` when it repeats the row above.
    private func sessionContext(_ session: ChatSidebarSession, after previous: ChatSidebarSession?) -> String? {
        let project = repository?.projects.first { $0.id == session.projectId }?.name
            ?? session.cwd?.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init)
        let device = previous?.connectorId == session.connectorId ? "^"
            : devicesList.first { $0.id == session.connectorId }?.name ?? session.connectorId
        let parts = [project, device].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

struct ChatSidebarListMenu<Filters: View>: View {
    @Environment(\.colorScheme) private var colorScheme

    @Binding var showsSessionList: Bool
    let onShowArchives: () -> Void
    @ViewBuilder var filters: () -> Filters

    var body: some View {
        Menu {
            Picker(String(localized: "侧栏显示"), selection: $showsSessionList) {
                Text(String(localized: "按项目")).tag(false)
                Text(String(localized: "全部会话")).tag(true)
            }
            filters()
            Divider()
            Button(action: onShowArchives) {
                Label(String(localized: "归档会话"), menuSymbol: "anthropicon.archive")
            }
        } label: {
            Image("aa-IconMore")
                .resizable()
                .scaledToFit()
                .frame(width: 13, height: 13)
                .foregroundStyle(AppTheme.sidebarRowText(colorScheme))
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .modifier(ChatSidebarIconControlStyle())
    }
}

/// Give menu triggers and buttons the same native sizing, including when
/// Show Borders is enabled. A frame inside the label adds to system padding.
struct ChatSidebarIconControlStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .buttonBorderShape(.circle)
            .controlSize(.large)
            .frame(width: 44, height: 44)
    }
}

struct ChatSidebarHeaderView: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 12) {
            AAWordmark(fontSize: 24)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)

            // Official sidebar search entry: 44pt system-glass circle, 19pt
            // magnifier. Placeholder action until the search screen lands.
            Button {
            } label: {
                Image("aa-IconSearch")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 19, height: 19)
                    .foregroundStyle(AppTheme.text300(colorScheme))
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: Circle())
            .accessibilityLabel(Text(String(localized: "搜索")))
        }
        .padding(.horizontal, 16)
        .containerCornerOffset(.horizontal, sizeToFit: true)
    }
}

private struct ChatSidebarDeviceSection: View {
    @Environment(\.colorScheme) private var colorScheme

    let devices: [ChatSidebarDevice]
    let selectedDeviceId: V2ConnectorID?
    let isLoading: Bool
    let onOpen: (V2ConnectorID) -> Void
    let onCopyId: (V2ConnectorID) -> Void
    let onPair: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            header

            if isLoading {
                ChatSidebarLoadingRow(title: "Loading devices...")
            } else if devices.isEmpty {
                // Nothing to list: the pairing action keeps the full row so
                // the section does not read as an empty dead end.
                pairRow
            } else {
                ForEach(devices) { device in
                    ChatSidebarDeviceRow(
                        device: device,
                        isSelected: selectedDeviceId == device.id,
                        onOpen: { onOpen(device.id) },
                        onCopyId: { onCopyId(device.id) }
                    )
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(String(localized: "Devices"))
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(AppTheme.sidebarRowText(colorScheme))
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            if !isLoading && !devices.isEmpty {
                // A text link with a caret, like the official drawer's
                // "查看全部 ›" — a bare plus reads as noise once the sidebar
                // has several of them. The official link uses the primary
                // text colour (#131313), darker than the grey section titles
                // (measured 2026-11-20).
                Button(action: onPair) {
                    // No 44pt frame: it inflated the header block and pushed
                    // this section's rhythm off the pinned section's (pp
                    // 2026-11-20). The link spans its text, like the section
                    // labels it sits beside.
                    HStack(spacing: 3) {
                        Text(String(localized: "添加设备"))
                        AppSymbol("anthropicon.caretRight", size: 10)
                    }
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(AppTheme.sidebarTextPrimary(colorScheme))
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "Pair device"))
            }
        }
        .padding(.horizontal, 10)
        // 16, not 20: the official drawer keeps ~39.7pt from the previous row
        // to a section title; 20 drew 44 (pp 2026-11-20).
        .padding(.top, 16)
        // Same trailing gap as ChatSidebarSectionLabel (Pinned/Recent): 0
        // here made the device row sit 6pt further from its header.
        .padding(.bottom, 6)
    }

    private var pairRow: some View {
        Button(action: onPair) {
            HStack(spacing: 14) {
                Image("aa-IconAdd")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 13, height: 13)
                    .foregroundStyle(AppTheme.sidebarRowText(colorScheme))
                Text(String(localized: "Pair device"))
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(AppTheme.sidebarTextPrimary(colorScheme))
                Spacer(minLength: 8)
                AppSymbol("anthropicon.caretRight", size: 10)
                    .foregroundStyle(AppTheme.sidebarRowText(colorScheme))
            }
            .padding(.leading, 11)
            .padding(.trailing, 12)
            .frame(minHeight: 48)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

private struct ChatSidebarSessionSection: View {
    let title: LocalizedStringResource?
    let sessions: [ChatSidebarSession]
    let selectedSessionId: V2SessionID?
    var isLoading = false
    let emptyMessage: LocalizedStringResource
    var context: ((ChatSidebarSession, ChatSidebarSession?) -> String?)? = nil
    let onOpen: (V2SessionID) -> Void
    let onRename: (V2SessionID, String) -> Void
    let onTogglePinned: (V2SessionID, Bool) -> Void
    let onArchive: (V2SessionID) -> Void
    let onCopyId: (V2SessionID) -> Void

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 2) {
            if let title { ChatSidebarSectionLabel(title: title) }

            if isLoading {
                ChatSidebarLoadingRow(title: "Loading sessions...")
            } else if sessions.isEmpty {
                ChatSidebarEmptyRow(title: emptyMessage)
            } else {
                ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                    ChatSidebarSessionRow(
                        session: session,
                        isSelected: selectedSessionId == session.id,
                        context: context?(session, index > 0 ? sessions[index - 1] : nil),
                        showsDivider: context != nil && index < sessions.count - 1,
                        onOpen: { onOpen(session.id) },
                        onRename: { onRename(session.id, $0) },
                        onTogglePinned: { onTogglePinned(session.id, !session.pinned) },
                        onArchive: { onArchive(session.id) },
                        onCopyId: { onCopyId(session.id) }
                    )
                }
            }
        }
    }
}

private struct ChatSidebarSectionLabel: View {
    @Environment(\.colorScheme) private var colorScheme

    let title: LocalizedStringResource

    var body: some View {
        Text(title)
            .font(.system(size: 13, weight: .regular))
            .foregroundStyle(AppTheme.sidebarRowText(colorScheme))
            .padding(.horizontal, 10)
            // Matches the project list's sub-labels and the official drawer's
            // ~39.7pt row-to-title gap (20 drew 44, pp 2026-11-20).
            .padding(.top, 16)
            .padding(.bottom, 6)
    }
}

private struct ChatSidebarDeviceRow: View {
    @Environment(\.colorScheme) private var colorScheme

    let device: ChatSidebarDevice
    let isSelected: Bool
    let onOpen: () -> Void
    let onCopyId: () -> Void

    var body: some View {
        Button(action: onOpen) {
            // Same row template as the chat list: 20pt leading icon at x=27,
            // 15pt title at x=61, 48pt row, inset selection block.
            HStack(spacing: 14) {
                Image("aa-IconComputer")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 20, height: 20)
                    .foregroundStyle(AppTheme.sidebarRowText(colorScheme))
                    .opacity(device.presence == .offline ? 0.45 : 1)

                Text(device.name)
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(AppTheme.sidebarTextPrimary(colorScheme))
                    .opacity(device.presence == .offline ? 0.55 : 1)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 11)
            .padding(.trailing, 12)
            .frame(minHeight: 48)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .fill(AppTheme.sidebarRowSelectionFill(colorScheme))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(action: onOpen) {
                Label(String(localized: "Open"), menuSymbol: "anthropicon.folderOpen")
            }
            Divider()
            Button(action: onCopyId) {
                Label(String(localized: "Copy device ID"), menuSymbol: "anthropicon.copy")
            }
        }
    }
}

struct ChatSidebarSessionRow: View {
    @Environment(\.colorScheme) private var colorScheme

    let session: ChatSidebarSession
    let isSelected: Bool
    var context: String? = nil
    var showsDivider = false
    var inset = false
    let onOpen: () -> Void
    let onRename: (String) -> Void
    let onTogglePinned: () -> Void
    let onArchive: () -> Void
    let onCopyId: () -> Void

    /// Corner radius of the selection block (1.261109 screenshots: 15pt).
    private static let selectionCornerRadius: CGFloat = 15

    @State private var isRenaming = false
    @State private var titleDraft = ""

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 14) {
                    // Official sidebar rows wear the 20pt chat bubble; the
                    // agent identity stays in the accessibility label.
                    Image("aa-IconChat")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 20, height: 20)
                        .foregroundStyle(AppTheme.sidebarRowText(colorScheme))
                        .accessibilityLabel(Text(SessionAgentMark.resolve(runtime: session.runtime, runtimeType: session.runtimeType).label))
                    Text(session.title ?? String(localized: "Untitled session"))
                        .font(.system(size: 15, weight: .regular))
                        .foregroundStyle(AppTheme.sidebarTextPrimary(colorScheme))
                        .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    ChatSidebarSessionIndicator(indicator: session.presentation.indicator)
                }
                if let context {
                    Text(verbatim: context).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // Nested rows shift by at most half of the project's folder icon.
            .padding(.leading, inset ? 24 : 11)
            .padding(.trailing, 12)
            .padding(.vertical, context == nil ? 0 : 8)
            // Official session row: 48pt tall, 50pt pitch with the 2pt stack
            // spacing above; icon leading 27pt = content inset 12 + 15.
            .frame(minHeight: 48)
            // Selection is an inset rounded block: the row already sits inside
            // the sidebar's content inset, so filling the row frame keeps the
            // highlight clear of both edges without any bleed.
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: Self.selectionCornerRadius, style: .continuous)
                        .fill(AppTheme.sidebarRowSelectionFill(colorScheme))
                }
            }
            .overlay(alignment: .bottom) {
                if showsDivider { Divider().padding(.horizontal, 10).offset(y: 2) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            // A read-only row at the top: the long-press answers "when was
            // this session last active" before the actions do anything.
            if let activityTimeText = session.activityTimeText {
                Section {
                    Text(verbatim: activityTimeText)
                }
            }
            Button(action: onOpen) {
                Label(String(localized: "Open"), menuSymbol: "anthropicon.folderOpen")
            }
            Button(action: beginRename) {
                Label(String(localized: "Rename"), menuSymbol: "anthropicon.edit")
            }.disabled(session.id.hasPrefix("local:"))
            Button(action: onTogglePinned) {
                if session.pinned {
                    Label(String(localized: "Unpin"), menuSymbol: "anthropicon.pin")
                } else {
                    Label(String(localized: "Pin"), menuSymbol: "anthropicon.pin")
                }
            }
            .disabled(session.id.hasPrefix("local:"))
            Button(action: onCopyId) {
                Label(String(localized: "Copy session ID"), menuSymbol: "anthropicon.copy")
            }
            Divider()
            // Archive closes the menu in red, the way the official menu ends on
            // its destructive row; Restore is not destructive and stays plain
            // (pp 2026-11-20).
            Button(role: session.archived ? nil : .destructive, action: onArchive) {
                Label(session.archived ? String(localized: "Restore") : String(localized: "Archive"),
                      menuSymbol: "anthropicon.archive",
                      destructive: !session.archived)
            }.disabled(session.id.hasPrefix("local:"))
        }
        .alert(String(localized: "Rename session"), isPresented: $isRenaming) {
            TextField(String(localized: "Session title"), text: $titleDraft)
            Button(String(localized: "Cancel"), role: .cancel) {}
            Button(String(localized: "Save"), action: submitRename)
                .disabled(titleDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func beginRename() {
        titleDraft = session.title ?? ""
        isRenaming = true
    }

    private func submitRename() {
        let title = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        onRename(title)
    }
}

struct ChatSidebarSessionIndicator: View {
    let indicator: SessionSidebarPresentation.Indicator
    var body: some View {
        switch indicator {
        case .waitingApproval:
            Text(String(localized: "等待批准")).font(.system(size: 11, weight: .medium))
                .foregroundStyle(.mint).padding(.horizontal, 8).padding(.vertical, 3)
                .background(.mint.opacity(0.16), in: .capsule)
                .fixedSize().accessibilityLabel(String(localized: "等待批准"))
        case .running:
            // Official open-ring spinner (pp 2026-11-20); the system mini
            // ProgressView drew the iOS petal spinner instead. The official
            // running glyph measures 16 pt of ring (14.7x16.0 on the Code
            // list screenshot), so the ring draws at 16.
            AnthropiconSpinner(size: 16)
                .frame(width: 16, height: 16)
                .accessibilityLabel(String(localized: "运行中"))
        case .unread:
            Circle().fill(.green).frame(width: 8, height: 8).accessibilityLabel(String(localized: "未读"))
        case .none:
            EmptyView()
        }
    }
}

private struct ChatSidebarLoadingRow: View {
    let title: LocalizedStringResource

    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(title)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .frame(minHeight: 38)
    }
}

private struct ChatSidebarEmptyRow: View {
    let title: LocalizedStringResource

    var body: some View {
        Text(title)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .frame(minHeight: 38)
    }
}

private struct ChatSidebarBottomControls: View {
    @Environment(\.colorScheme) private var colorScheme

    let appState: AppState
    let account: ChatSidebarAccount
    let onNewSession: () -> Void

    @State private var isShowingSettings = false

    var body: some View {
        // Official placement: avatar leading, New Chat trailing. Both keep
        // their original materials (glass avatar, liquid-glass button); only
        // the sides are swapped. The capsule tint carries the official
        // black-on-light / white-on-dark values — the glass surface itself
        // stays system-drawn so no double round chrome appears.
        HStack(spacing: 12) {
            Button {
                isShowingSettings = true
            } label: {
                ChatSidebarAvatar(account: account)
                    .frame(width: 49, height: 49)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: Circle())
            .accessibilityLabel(String(localized: "Account"))

            Spacer(minLength: 12)

            Button(action: onNewSession) {
                HStack(spacing: 12.7) {
                    Image("aa-IconAdd")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 13, height: 13)
                    Text(String(localized: "新建会话"))
                        .font(.system(size: 15, weight: .regular))
                }
                .padding(.horizontal, 14)
                .frame(height: 48)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive().tint(AppTheme.sidebarProminentFill(colorScheme)), in: Capsule())
            .foregroundStyle(AppTheme.sidebarProminentLabel(colorScheme))
            .accessibilityLabel(String(localized: "新建会话"))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(isPresented: $isShowingSettings) {
            AccountSettingsSheet(appState: appState)
        }
    }
}

private struct ChatSidebarAvatar: View {
    @Environment(\.colorScheme) private var colorScheme

    let account: ChatSidebarAccount

    var body: some View {
        if account.avatarSource == nil {
            // No photo: the official sidebar keeps the glass circle and puts
            // plain initials inside it (no second filled disc, or the glass
            // button would read as a double circle).
            Text(verbatim: initials)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AppTheme.sidebarTextPrimary(colorScheme))
                // The photo/initials sit inside the 49 pt glass circle; keep
                // the glass size and leave a visible rim around the avatar.
                .frame(width: 34, height: 34)
                .clipShape(Circle())
                .accessibilityLabel(Text(account.displayName))
        } else {
            AccountAvatarView(
                displayName: account.displayName,
                source: account.avatarSource,
                size: 34
            )
        }
    }

    /// First letters of the first two words, e.g. "Jin Bung" -> "JB".
    private var initials: String {
        let words = account.displayName.split(whereSeparator: { $0.isWhitespace })
        let letters = words.prefix(2).compactMap { $0.first }
        if letters.isEmpty { return "?" }
        return String(letters).uppercased()
    }
}

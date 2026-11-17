import SwiftUI
import UIKit

struct NewSessionView: View, Equatable {
    @Bindable var model: NewSessionModel
    let connectors: [V2Connector]
    let sessions: [V2SessionMeta]
    let repository: V2DashboardRepository
    var dashboardLoading = false
    var dashboardError: String?
    let onMenu: () -> Void
    let onOpenDevice: (V2ConnectorID) -> Void
    let onCreated: (V2SessionMeta) -> Void
    let onRefresh: () async -> [V2Connector]
    @State private var showsTarget = false
    @State private var showsWorkspace = false
    @State private var showsFiles = false
    @Environment(AppState.self) private var appState
    @State private var confirmsRetry = false
    /// How much of the page the keyboard covers. Only feeds the optical-centre
    /// bias below — never an animation, so it cannot reintroduce the swing
    /// (pp 2026-11-17).
    @State private var keyboardCoverage: CGFloat = 0
    @State private var composerEditor = ComposerEditorController()
    @State private var showsCommandMenu = false
    @AppStorage(ProjectSidebarPreferences.sessionListKey) private var showsSessionList = false
    @ScaledMetric(relativeTo: .body) private var bodyLineHeight: CGFloat = 22

    /// The collection engine's composer keeps the official Code measurements
    /// in both rendering modes (pp 2026-10-29).
    private var composerProfile: ComposerMetricsProfile {
        .code
    }
    private var controls: ChatControlMetrics {
        .init(bodyLineHeight: bodyLineHeight, profile: composerProfile)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.model === rhs.model && lhs.connectors == rhs.connectors && lhs.sessions == rhs.sessions
            && lhs.dashboardLoading == rhs.dashboardLoading
            && lhs.dashboardError == rhs.dashboardError
    }

    var body: some View {
        GeometryReader { geometry in
            GeometryReader { viewport in
                // Centred in whatever space the keyboard leaves: one layout pass
                // per keyboard frame, with the copy and the avatar riding that
                // same pass. The old transform-based rise retargeted on every
                // frame — it read `rise` off the shrinking viewport — which is
                // what made the page swing while the keyboard moved
                // (pp 2026-11-17).
                let restingHeight = max(0, viewport.size.height - 48)
                // Official vs ours: +10 pt with the keyboard down, +37 with it
                // up (block centre 445.2/300.5 vs 435.5/263.5). The bias grows
                // with the coverage, linearly over a standard keyboard.
                let centerOffset = 10 + min(360, max(0, keyboardCoverage)) / 340 * 27
                ScrollView {
                    NewSessionContentLayout(viewportHeight: restingHeight, centerOffset: centerOffset) {
                        NewSessionWelcomeView(displayName: appState.me?.displayName,
                                              runtime: model.runtime,
                                              workspaceName: workspaceName,
                                              onChooseWorkspace: { showsWorkspace = true })
                        statusContent
                    }
                        .padding(24)
                        .frame(maxWidth: 760)
                        .frame(maxWidth: .infinity)
                        .background { ChatPageScrollEdge() }
                }
                .scrollDismissesKeyboard(.interactively)
                .scrollEdgeEffectStyle(.soft, for: .top)
                .refreshable { await refresh() }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                ChatComposerDock(draft: model.draft, settings: model.settings,
                    maximumEditorHeight: min(160, max(72, geometry.size.height * 0.30)), controls: controls,
                    editor: composerEditor, showsCommandMenu: $showsCommandMenu,
                    canSend: model.canCreate, canAttach: model.canAttach && model.prepared != nil,
                    canSelectModel: model.prepared?.capabilities.allows("catalog.model") == true,
                    canSelectPermission: model.prepared?.capabilities.allows("catalog.permission") == true,
                    isBusy: model.isCreating, isLoadingSettings: model.isPreparing,
                    onSend: { text in if let session = await model.create(text: text) { onCreated(session) } },
                    onApplySettings: { model.saveSelections(); return true },
                    onDraftChange: { model.scheduleDraftSave() })
                }
                .frame(maxWidth: ChatControlMetrics.maximumContentWidth).frame(maxWidth: .infinity)
            }
        }
        // Same page ink as the session transcript, so the welcome page and the
        // chat it opens do not flash between white and #F9F9F7.
        .background(Color(uiColor: CodePageTheme.pageBackgroundUIColor)
            .ignoresSafeArea())
        .modifier(ChatPageToolbar(title: "", onMenu: onMenu))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showsFiles = true } label: { AppSymbol("folder") }
                    .disabled(!canBrowse)
                    .accessibilityLabel(String(localized: "浏览文件"))
                    .accessibilityIdentifier("chat.new.files")
            }
            ToolbarItem(placement: .topBarTrailing) { deviceMenu }
        }
        .sheet(isPresented: $showsTarget) {
            SessionTargetSheet(model: model)
        }
        .sheet(isPresented: $showsWorkspace) {
            ProjectSelectionSheet(model: model, repository: repository)
        }
        .sheet(isPresented: $showsFiles) {
            if let device = model.connector, let service = appState.workspaceFilesService {
                WorkspaceFilesSheet(connectorId: device.id, deviceName: device.name,
                    workspace: .init(path: model.workspace.isEmpty ? "~" : model.workspace,
                                     name: workspaceName, sessionCount: 0, lastActiveAt: nil),
                    service: service)
            }
        }
        .confirmationDialog(String(localized: "创建结果仍未确认，再次创建可能产生重复会话。"), isPresented: $confirmsRetry, titleVisibility: .visible) {
            Button(String(localized: "保留草稿并允许重新创建")) { model.acknowledgeUncertainCreation() }
            Button(String(localized: "取消"), role: .cancel) {}
        }
        // Coverage only shifts the optical centre; the page itself still
        // follows the keyboard through the safe area, so this must stay
        // un-animated.
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
            guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
            keyboardCoverage = max(0, UIScreen.main.bounds.height - frame.minY)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardCoverage = 0
        }
    }

    private var statusContent: some View {
        VStack(alignment: .leading, spacing: 28) {
            connectionStatus
            if model.isCreating {
                Label(String(localized: "正在创建会话…"), appSymbol: "arrow.up.circle")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            if let error = model.error {
                VStack(alignment: .leading, spacing: 12) {
                    Text(error).font(.subheadline).foregroundStyle(.secondary)
                    if model.creationUncertain {
                        Button(String(localized: "查看会话列表"), action: onMenu)
                        Button(String(localized: "已检查，重新创建")) { confirmsRetry = true }
                    } else {
                        Button(String(localized: "重新连接")) { Task { await refresh() } }
                    }
                }
            }
        }
        .multilineTextAlignment(.leading)
    }

    private var deviceMenu: some View {
        // Menu rows use SF Symbols like the rest of the system menu.
        Menu {
            Button(String(localized: "选择设备和 Agent"), systemImage: "cpu") { chooseTarget() }
            Button(String(localized: "选择工作目录"), systemImage: "folder") { showsWorkspace = true }
                .disabled(model.connector == nil)
            if let device = model.connector {
                Divider()
                Button(String(localized: "设备详情"), systemImage: "info.circle") { onOpenDevice(device.id) }
                Button(String(localized: "Copy device ID"), systemImage: "doc.on.doc") { UIPasteboard.general.string = device.id }
            }
        } label: {
            if model.isPreparing { ProgressView().controlSize(.mini) } else { AppSymbol("ellipsis") }
        }
        .disabled(model.isCreating)
        .accessibilityLabel(String(localized: "Device actions"))
        .accessibilityIdentifier("chat.new.target")
    }

    private var canBrowse: Bool {
        model.connector?.status == .online && model.network.availability != .offline && model.isValid && !model.isCreating
            && appState.workspaceFilesService != nil
    }

    private func chooseTarget() {
        model.draft.isFocused = false
        showsTarget = true
    }

    @ViewBuilder private var connectionStatus: some View {
        if model.network.availability == .offline {
            status(String(localized: "手机网络已断开"), detail: String(localized: "草稿和运行目标已保留，网络恢复后会重新检查。"), icon: "wifi.slash")
        } else if dashboardLoading && connectors.isEmpty {
            ProgressView(String(localized: "正在查找设备…"))
        } else if connectors.isEmpty {
            status(String(localized: "还没有可用设备"), detail: dashboardError ?? String(localized: "从侧栏添加设备，连接后即可开始。"), icon: "desktopcomputer")
            Button(String(localized: "打开侧栏"), action: onMenu)
        } else if model.connector?.status != .online {
            status(String(localized: "目标设备离线"), detail: String(localized: "等待它重新连接，或选择其他在线设备。草稿会继续保留。"), icon: "bolt.horizontal.circle")
            Button(String(localized: "选择其他设备")) { showsTarget = true }
        } else if model.workspace.isEmpty, let error = model.homeErrors[model.connectorID] {
            status(String(localized: "无法解析设备家目录"), detail: error, icon: "folder")
            Button(String(localized: "选择工作目录")) { showsWorkspace = true }
        } else if !model.isPreparing && !model.loadingDevices.contains(model.connectorID)
                    && (model.inventories[model.connectorID] != nil || model.inventoryErrors[model.connectorID] != nil)
                    && model.runtime?.isReadyForSession != true {
            status(String(localized: "选择一个已就绪的 Agent"),
                detail: model.inventoryErrors[model.connectorID] ?? String(localized: "可在设备管理中配置或启动实例。"), icon: "sparkle")
            Button(String(localized: "选择 Agent")) { showsTarget = true }
        }
    }

    private var workspaceName: String {
        if !showsSessionList, let project = model.project { return project.name }
        if model.isHome || model.workspace.isEmpty { return String(localized: "Home 目录") }
        return ProjectWorkspacePath.name(model.workspace)
    }

    private func status(_ title: String, detail: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, appSymbol: icon).font(.subheadline.weight(.medium))
            Text(detail).font(.footnote).foregroundStyle(.secondary)
        }
    }
    private func refresh() async {
        let current = await onRefresh()
        await model.refresh(connectors: current)
    }
}

/// Center the welcome and workspace alone. Notices flow below that anchor and
/// extend the scrollable page when needed, rather than recentering the welcome.
private struct NewSessionContentLayout: Layout {
    let viewportHeight: CGFloat
    /// Optical centre, not geometric. Official vs ours: 445.2 vs 435.5 pt with
    /// the keyboard down, 300.5 vs 263.5 with it up — so the bias grows with
    /// the keyboard (10 pt → 37 pt), which is what the caller interpolates
    /// (pp 2026-11-17).
    let centerOffset: CGFloat
    private let spacing: CGFloat = 28

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.replacingUnspecifiedDimensions().width
        let childProposal = ProposedViewSize(width: width, height: nil)
        let welcome = subviews[0].sizeThatFits(childProposal)
        let status = subviews[1].sizeThatFits(childProposal)
        let top = max(0, (viewportHeight - welcome.height) / 2 + centerOffset)
        let statusHeight = status.height > 0 ? spacing + status.height : 0
        return CGSize(width: width, height: max(viewportHeight, top + welcome.height + statusHeight))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let childProposal = ProposedViewSize(width: bounds.width, height: nil)
        let welcome = subviews[0].sizeThatFits(childProposal)
        let top = max(0, (viewportHeight - welcome.height) / 2 + centerOffset)
        subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.minY + top), anchor: .topLeading, proposal: childProposal)
        subviews[1].place(at: CGPoint(x: bounds.minX, y: bounds.minY + top + welcome.height + spacing),
            anchor: .topLeading, proposal: childProposal)
    }
}

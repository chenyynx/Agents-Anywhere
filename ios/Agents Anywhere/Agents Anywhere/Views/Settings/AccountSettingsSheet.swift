import SwiftUI

struct AccountSettingsSheet: View {
    let appState: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(AppAppearance.storageKey) private var appearanceValue = AppAppearance.system.rawValue
    @AppStorage(AppAccent.storageKey) private var accentValue = AppAccent.storageDefault.rawValue
    @AppStorage(ProjectSidebarPreferences.sessionListKey) private var showsSessionList = false
    @AppStorage(ProjectSidebarPreferences.compactSessionListKey) private var compactSessionList = false
    @AppStorage(TimelineRenderModeSwitch.key)
    private var renderModeRaw = TimelineRenderMode.steps.rawValue
    @AppStorage(LocalCachePolicy.key)
    private var cacheLimitRaw = LocalCacheLimit.defaultValue.rawValue
    @AppStorage(ComposerDeliverySetting.storageKey)
    private var deliveryRaw = ComposerDeliverySetting.defaultValue.rawValue
    @AppStorage(ComposerCommandsSetting.storageKey)
    private var commandsHidden = false
    @AppStorage(ShellStartPage.storageKey)
    private var startPageRaw = ShellStartPage.auto.rawValue
    private var renderMode: TimelineRenderMode {
        TimelineRenderMode(rawValue: renderModeRaw) ?? .steps
    }
    private var delivery: ComposerDelivery {
        ComposerDeliverySetting.resolve(deliveryRaw)
    }
    @State private var confirmsSignOut = false
    @State private var signOutError: String?
    @State private var toasts = ChatToastStore()
    @State private var drafts = AccountSettingsDrafts()
    @State private var confirmsDiscard = false
#if AA_TIMELINE_PROBE
    @State private var diagnosticsPresented = false
#endif

    var body: some View {
        NavigationStack {
            SettingsScreen(title: String(localized: "Settings"),
                           close: close, closeDisabled: isWorking) {
                if let me = appState.me {
                    accountCard(me)
                    accountSection(me)
                }
                connectionSection
                generalSection
                displaySection
                composerSection
                notificationsSection
                sessionListSection
                storageSection
                supportSection
                signOutSection
#if AA_TIMELINE_PROBE
                developerSection
#endif
                Text("Agents Anywhere · \(SettingsAboutView.version) (\(buildLabel))")
                    .font(.footnote)
                    .foregroundStyle(SettingsStyle.secondary(colorScheme))
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)
            }
            .refreshable { _ = await appState.refreshAccount() }
            .alert(String(localized: "Sign out?"), isPresented: $confirmsSignOut) {
                Button(String(localized: "Cancel"), role: .cancel) {}
                Button(String(localized: "Sign out"), role: .destructive, action: signOut)
            } message: {
                Text(String(localized: "Your saved credentials will be removed from this device. You will need to sign in again to reconnect."))
            }
            .alert(String(localized: "Could not sign out"), isPresented: Binding(get: { signOutError != nil }, set: { if !$0 { signOutError = nil } })) {
                Button(String(localized: "OK"), role: .cancel) { signOutError = nil }
            } message: { Text(signOutError ?? "") }
        }
        .overlay(alignment: .top) { ChatErrorToasts(store: toasts, isRetrying: false, onRetry: { _ in }) }
        .onChange(of: appState.accountError) { _, error in
            guard let error else { return }
            toasts.update(source: "account", failure: .init(kind: .rejected, message: error))
            appState.dismissAccountError()
        }
        // Native sheet presentation can create a new hosting boundary on Mac.
        // Use the caller's store here and provide it to every settings subpage.
        .environment(appState)
        .appSheetPresentation(.expanded)
        .interactiveDismissDisabled(drafts.hasChanges || isWorking)
        .confirmDiscardChanges($confirmsDiscard) { dismiss() }
#if AA_TIMELINE_PROBE
        .sheet(isPresented: $diagnosticsPresented) { DiagnosticsPanel() }
#endif
    }

    // MARK: - Sections

    private func accountCard(_ me: AuthMe) -> some View {
        let role = me.role == .admin
            ? String(localized: "Administrator")
            : String(localized: "Member")
        let detail = [me.email, role].compactMap { $0 }.joined(separator: " · ")
        return HStack(spacing: 14) {
            AccountAvatarView(displayName: me.accountLabel,
                              source: appState.accountAvatarSource, size: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text(me.accountLabel)
                    .font(SettingsStyle.text(16, weight: .semibold))
                    .foregroundStyle(SettingsStyle.ink(colorScheme))
                Text(detail)
                    .font(SettingsStyle.text(15))
                    .foregroundStyle(SettingsStyle.secondary(colorScheme))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, SettingsStyle.rowPadding)
        .padding(.vertical, 14)
        .background(SettingsStyle.card(colorScheme),
                    in: RoundedRectangle(cornerRadius: SettingsStyle.cardRadius, style: .continuous))
    }

    private func accountSection(_ me: AuthMe) -> some View {
        SettingsSection(String(localized: "Account")) {
            SettingsNavigationRow(icon: "anthropicon.id",
                                  title: String(localized: "Nickname"),
                                  value: me.displayName,
                                  destination: AccountIdentitySettingsView(mode: .nickname, draft: $drafts.nickname))
            SettingsRowDivider()
            SettingsNavigationRow(icon: "anthropicon.email",
                                  title: String(localized: "Email"),
                                  value: me.email,
                                  destination: AccountIdentitySettingsView(mode: .email, draft: $drafts.email))
            SettingsRowDivider()
            SettingsNavigationRow(icon: "anthropicon.userCircle",
                                  title: String(localized: "Profile photo"),
                                  destination: AvatarSettingsView(draft: $drafts.avatar))
            SettingsRowDivider()
            SettingsNavigationRow(icon: "anthropicon.key",
                                  title: String(localized: "Password"),
                                  destination: PasswordSettingsView(draft: $drafts.password))
        }
    }

    private var generalSection: some View {
        SettingsSection(String(localized: "通用")) {
            SettingsMenuRow(
                icon: "anthropicon.sidebar",
                title: String(localized: "起始页面"),
                subtitle: String(localized: "启动时打开列表还是上一次的会话"),
                value: (ShellStartPage(rawValue: startPageRaw) ?? .auto).title,
                options: ShellStartPage.allCases.map { page in
                    SettingsMenuOption(id: page.rawValue, title: page.title,
                                       symbol: symbol(for: page))
                },
                selection: $startPageRaw)
        }
    }

    private func symbol(for page: ShellStartPage) -> String {
        switch page {
        case .auto: return "anthropicon.sidebar"
        case .chat: return "anthropicon.chat"
        case .list: return "anthropicon.listBullet"
        }
    }

    private var displaySection: some View {
        SettingsSection(String(localized: "Appearance & display")) {
            SettingsNavigationRow(icon: "anthropicon.moon",
                                  title: String(localized: "Appearance"),
                                  value: String(localized: (AppAppearance(rawValue: appearanceValue) ?? .system).title),
                                  destination: AppearanceSettingsView())
            SettingsRowDivider()
            SettingsNavigationRow(icon: "anthropicon.image",
                                  title: String(localized: "应用图标"),
                                  destination: AppIconSettingsView())
            SettingsRowDivider()
            SettingsNavigationRow(icon: "anthropicon.palette",
                                  title: String(localized: "Accent color"),
                                  value: String(localized: AppAccent.resolve(accentValue).title),
                                  destination: AccentSettingsView())
            SettingsRowDivider()
            SettingsNavigationRow(icon: "anthropicon.globe",
                                  title: String(localized: "Language"),
                                  value: SettingsLanguageView.currentLanguage,
                                  destination: SettingsLanguageView())
        }
    }

    private var composerSection: some View {
        SettingsSection(String(localized: "编写器")) {
            // Both choices are short enough for the official inline menu row
            // (value + up/down chevron), so neither opens a second-level page
            // (pp 2026-11-18).
            SettingsMenuRow(icon: "anthropicon.edit",
                            title: String(localized: "后续消息处理方式"),
                            value: delivery.title,
                            options: ComposerDelivery.allCases.map {
                                SettingsMenuOption(id: $0.rawValue,
                                                   title: $0.title, symbol: $0.menuSymbol)
                            },
                            selection: $deliveryRaw)
            SettingsRowDivider()
            SettingsMenuRow(icon: "anthropicon.download",
                            title: String(localized: "工具渲染方式"),
                            value: renderMode.title,
                            options: TimelineRenderMode.allCases.map {
                                SettingsMenuOption(id: $0.rawValue,
                                                   title: $0.title, symbol: $0.menuSymbol)
                            },
                            selection: $renderModeRaw)
            SettingsRowDivider()
            // Off by default: the key follows the runtime's slash-command
            // capability; on, it is hidden everywhere (pp 2026-11-20).
            SettingsToggleRow(icon: "anthropicon.scroll",
                              title: String(localized: "隐藏指令图标"),
                              isOn: $commandsHidden)
            SettingsRowDivider()
            // One page: a shrunk real chat page plus the three ink wells
            // (pp 2026-11-22).
            SettingsNavigationRow(icon: "anthropicon.palette",
                                  title: String(localized: "链接与代码配色"),
                                  destination: CodeLinkColorSettingsView())
        }
    }

    private var notificationsSection: some View {
        SettingsSection(String(localized: "Notifications")) {
            SettingsNavigationRow(icon: "text.bubble",
                                  title: String(localized: "Notifications"),
                                  destination: NotificationSettingsView())
        }
    }

    private var sessionListSection: some View {
        SettingsSection(String(localized: "Session list")) {
            SettingsToggleRow(icon: "anthropicon.folder",
                              title: String(localized: "Project mode"),
                              isOn: Binding(get: { !showsSessionList }, set: { showsSessionList = !$0 }))
            SettingsRowDivider()
            SettingsToggleRow(icon: "anthropicon.sidebar",
                              title: String(localized: "Single-line sessions"),
                              isOn: $compactSessionList,
                              isEnabled: showsSessionList)
        }
    }

    private var storageSection: some View {
        SettingsSection(String(localized: "Storage & diagnostics")) {
            SettingsNavigationRow(icon: "anthropicon.archive",
                                  title: String(localized: "Cache"),
                                  value: (LocalCacheLimit(rawValue: cacheLimitRaw) ?? .defaultValue).title,
                                  destination: CacheSettingsView())
            SettingsRowDivider()
            SettingsNavigationRow(icon: "anthropicon.research",
                                  title: String(localized: "Diagnostics log"),
                                  showsStatusDot: true,
                                  destination: DiagnosticsLogSettingsView())
        }
    }

    private var connectionSection: some View {
        SettingsSection(String(localized: "Connection")) {
            SettingsNavigationRow(icon: "anthropicon.connectors",
                                  title: String(localized: "Connectors"),
                                  destination: ConnectorsSettingsView())
            SettingsRowDivider()
            SettingsNavigationRow(icon: "anthropicon.cloud",
                                  title: String(localized: "Server"),
                                  value: appState.serverURL?.host,
                                  destination: SettingsServerView())
        }
    }

    private var supportSection: some View {
        SettingsSection(String(localized: "About & support")) {
            SettingsNavigationRow(icon: "anthropicon.lockShield",
                                  title: String(localized: "privacyPolicy.title"),
                                  destination: PrivacyPolicyContent())
            SettingsRowDivider()
            SettingsNavigationRow(icon: "anthropicon.info",
                                  title: String(localized: "About"),
                                  value: SettingsAboutView.version,
                                  destination: SettingsAboutView())
        }
    }

    private var signOutSection: some View {
        SettingsSection {
            Button {
                confirmsSignOut = true
            } label: {
                HStack(spacing: SettingsStyle.iconGap) {
                    AppSymbol("anthropicon.arrowOutSquare", size: 18)
                        .frame(width: SettingsStyle.iconFrame)
                    Text(String(localized: "Sign out"))
                        .font(SettingsStyle.text(16))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.red)
                .padding(.horizontal, SettingsStyle.rowPadding)
                .padding(.vertical, 12)
                .frame(minHeight: SettingsStyle.rowMinHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(appState.isAccountWorking)
        }
    }

#if AA_TIMELINE_PROBE
    private var developerSection: some View {
        SettingsSection(String(localized: "开发者")) {
            SettingsDisclosureRow(icon: "anthropicon.settings",
                                  title: String(localized: "诊断与日志"),
                                  value: buildLabel) {
                diagnosticsPresented = true
            }
        }
    }
#endif

    private var buildLabel: String {
        "b\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?")"
    }

    private var isWorking: Bool { appState.isAccountWorking || drafts.isWorking }

    private func close() {
        guard !isWorking else { return }
        if drafts.hasChanges { confirmsDiscard = true } else { dismiss() }
    }

    private func signOut() {
        do { try appState.signOutAndDeleteCredentials(); dismiss() }
        catch { signOutError = error.localizedDescription }
    }
}

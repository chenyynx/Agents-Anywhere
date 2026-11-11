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
    private var renderModeRaw = TimelineRenderMode.code.rawValue
    @AppStorage(LocalCachePolicy.key)
    private var cacheLimitRaw = LocalCacheLimit.defaultValue.rawValue
    private var renderMode: TimelineRenderMode {
        TimelineRenderMode(rawValue: renderModeRaw) ?? .code
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
                appSection
                connectionSection
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
            SettingsNavigationRow(icon: "person.text.rectangle",
                                  title: String(localized: "Nickname"),
                                  value: me.displayName,
                                  destination: AccountIdentitySettingsView(mode: .nickname, draft: $drafts.nickname))
            SettingsRowDivider()
            SettingsNavigationRow(icon: "envelope",
                                  title: String(localized: "Email"),
                                  value: me.email,
                                  destination: AccountIdentitySettingsView(mode: .email, draft: $drafts.email))
            SettingsRowDivider()
            SettingsNavigationRow(icon: "person.crop.circle",
                                  title: String(localized: "Profile photo"),
                                  destination: AvatarSettingsView(draft: $drafts.avatar))
            SettingsRowDivider()
            SettingsNavigationRow(icon: "key",
                                  title: String(localized: "Password"),
                                  destination: PasswordSettingsView(draft: $drafts.password))
        }
    }

    private var appSection: some View {
        SettingsSection(String(localized: "App")) {
            SettingsNavigationRow(icon: "circle.lefthalf.filled",
                                  title: String(localized: "Appearance"),
                                  value: String(localized: (AppAppearance(rawValue: appearanceValue) ?? .system).title),
                                  destination: AppearanceSettingsView())
            SettingsRowDivider()
            SettingsNavigationRow(icon: "image",
                                  title: String(localized: "应用图标"),
                                  destination: AppIconSettingsView())
            SettingsRowDivider()
            SettingsNavigationRow(icon: "paintpalette",
                                  title: String(localized: "Accent color"),
                                  value: String(localized: AppAccent.resolve(accentValue).title),
                                  destination: AccentSettingsView())
            SettingsRowDivider()
            SettingsNavigationRow(icon: "globe",
                                  title: String(localized: "Language"),
                                  value: SettingsLanguageView.currentLanguage,
                                  destination: SettingsLanguageView())
            SettingsRowDivider()
            SettingsNavigationRow(icon: "archivebox",
                                  title: String(localized: "Cache"),
                                  value: (LocalCacheLimit(rawValue: cacheLimitRaw) ?? .defaultValue).title,
                                  destination: CacheSettingsView())
            SettingsRowDivider()
            SettingsNavigationRow(icon: "arrow.down.document",
                                  title: String(localized: "步骤展示"),
                                  value: renderMode.title,
                                  destination: TimelineRenderModeSettingsView())
            SettingsRowDivider()
            SettingsNavigationRow(icon: "doc.text.magnifyingglass",
                                  title: String(localized: "Diagnostics log"),
                                  showsStatusDot: true,
                                  destination: DiagnosticsLogSettingsView())
            SettingsRowDivider()
            SettingsToggleRow(icon: "folder",
                              title: String(localized: "Project mode"),
                              isOn: Binding(get: { !showsSessionList }, set: { showsSessionList = !$0 }))
            SettingsRowDivider()
            SettingsToggleRow(icon: "sidebar.left",
                              title: String(localized: "Single-line sessions"),
                              isOn: $compactSessionList,
                              isEnabled: showsSessionList)
        }
    }

    private var connectionSection: some View {
        SettingsSection(String(localized: "Workspace")) {
            SettingsNavigationRow(icon: "server.rack",
                                  title: String(localized: "Server"),
                                  value: appState.serverURL?.host,
                                  destination: SettingsServerView())
        }
    }

    private var supportSection: some View {
        SettingsSection {
            SettingsNavigationRow(icon: "hand.raised",
                                  title: String(localized: "privacyPolicy.title"),
                                  destination: PrivacyPolicyContent())
            SettingsRowDivider()
            SettingsNavigationRow(icon: "info.circle",
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
                    AppSymbol("rectangle.portrait.and.arrow.forward", size: 18)
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
            SettingsDisclosureRow(icon: "gearshape",
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

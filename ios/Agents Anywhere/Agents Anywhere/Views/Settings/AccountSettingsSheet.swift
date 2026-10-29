import SwiftUI

struct AccountSettingsSheet: View {
    let appState: AppState
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppAppearance.storageKey) private var appearanceValue = AppAppearance.system.rawValue
    @AppStorage(AppAccent.storageKey) private var accentValue = AppAccent.default.rawValue
    @AppStorage(ProjectSidebarPreferences.sessionListKey) private var showsSessionList = false
    @AppStorage(ProjectSidebarPreferences.compactSessionListKey) private var compactSessionList = false
    @AppStorage(TimelineRenderModeSwitch.key)
    private var renderModeRaw = TimelineRenderMode.code.rawValue
    @State private var timelineLastActive: Date?

    private var renderMode: TimelineRenderMode {
        TimelineRenderMode(rawValue: renderModeRaw) ?? .code
    }
    @State private var confirmsSignOut = false
    @State private var signOutError: String?
    @State private var toasts = ChatToastStore()
    @State private var drafts = AccountSettingsDrafts()
    @State private var confirmsDiscard = false

    var body: some View {
        NavigationStack {
            List {
                if let me = appState.me {
                    Section {
                        HStack(spacing: 16) {
                            AccountAvatarView(displayName: me.accountLabel, source: appState.accountAvatarSource, size: 60)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(me.accountLabel).font(.title3.weight(.semibold))
                                if let email = me.email { Text(email).font(.subheadline).foregroundStyle(.secondary) }
                                Text(me.role == .admin ? String(localized: "Administrator") : String(localized: "Member"))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }.padding(.vertical, 12)
                    }.listRowSeparator(.hidden)

                    Section(String(localized: "Account")) {
                        NavigationLink { AccountIdentitySettingsView(mode: .nickname, draft: $drafts.nickname) } label: {
                            SettingsRow(title: String(localized: "Nickname"), symbol: "person.text.rectangle", value: me.displayName)
                        }
                        NavigationLink { AccountIdentitySettingsView(mode: .email, draft: $drafts.email) } label: {
                            SettingsRow(title: String(localized: "Email"), symbol: "envelope", value: me.email)
                        }
                        NavigationLink { AvatarSettingsView(draft: $drafts.avatar) } label: {
                            SettingsRow(title: String(localized: "Profile photo"), symbol: "person.crop.circle")
                        }
                        NavigationLink { PasswordSettingsView(draft: $drafts.password) } label: {
                            SettingsRow(title: String(localized: "Password"), symbol: "key")
                        }
                    }
                }

                Section(String(localized: "App")) {
                    NavigationLink { AppearanceSettingsView() } label: {
                        SettingsRow(title: String(localized: "Appearance"), symbol: "circle.lefthalf.filled",
                            value: String(localized: (AppAppearance(rawValue: appearanceValue) ?? .system).title))
                    }
                    NavigationLink { AccentSettingsView() } label: {
                        SettingsRow(title: String(localized: "Accent color"), symbol: "paintpalette",
                            value: String(localized: AppAccent.resolve(accentValue).title))
                    }
                    NavigationLink { SettingsLanguageView() } label: {
                        SettingsRow(title: String(localized: "Language"), symbol: "globe", value: SettingsLanguageView.currentLanguage)
                    }
                    Toggle(isOn: Binding(
                        get: { !showsSessionList },
                        set: { showsSessionList = !$0 }
                    )) {
                        Label(String(localized: "Project mode"), appSymbol: "folder")
                            .labelStyle(.titleAndIcon)
                    }.tint(.green)
                    Toggle(isOn: $compactSessionList) {
                        Label(String(localized: "Single-line sessions"), appSymbol: "sidebar.left")
                            .labelStyle(.titleAndIcon)
                    }
                    .tint(.green)
                    .disabled(!showsSessionList)
                }
                Section {
                    NavigationLink {
                        TimelineRenderModeSettingsView()
                    } label: {
                        HStack {
                            Label(String(localized: "渲染方式"), appSymbol: "rectangle.stack")
                                .labelStyle(.titleAndIcon)
                            Spacer()
                            Text(renderMode.title)
                                .foregroundStyle(.secondary)
                        }
                    }
                } footer: {
                    if let timelineLastActive {
                        Text(renderMode.detail + "\n"
                            + String(localized: "上次生效：\(timelineLastActive.formatted(date: .abbreviated, time: .shortened))"))
                    } else {
                        Text(renderMode.detail)
                    }
                }
                Section(String(localized: "Workspace")) {
                    NavigationLink { SettingsServerView() } label: {
                        SettingsRow(title: String(localized: "Server"), symbol: "server.rack", value: appState.serverURL?.host)
                    }
                }
                Section {
                    NavigationLink {
                        PrivacyPolicyContent().settingsPage(String(localized: "privacyPolicy.title"))
                    } label: {
                        SettingsRow(title: String(localized: "privacyPolicy.title"), symbol: "hand.raised")
                    }
                    NavigationLink { SettingsAboutView() } label: {
                        SettingsRow(title: String(localized: "About"), symbol: "info.circle")
                    }
                }
                Section {
                    Button(role: .destructive) { confirmsSignOut = true } label: {
                        SettingsRow(title: String(localized: "Sign out"), symbol: "rectangle.portrait.and.arrow.forward")
                            .foregroundStyle(.red)
                    }.disabled(appState.isAccountWorking)
                } footer: {
                    Text("Agents Anywhere · \(SettingsAboutView.version)")
                        .font(.footnote).frame(maxWidth: .infinity).padding(.top, 16)
                }
            }
            .listStyle(.insetGrouped)
            .onAppear { refreshTimelineMarker() }
            .onChange(of: renderModeRaw) { _, _ in
                // A mode change must not inherit the previous run's timestamp:
                // clear it so the next session proves this mode ran.
                UserDefaults.standard.removeObject(forKey: TimelineCollectionSwitch.lastActiveKey)
                timelineLastActive = nil
            }
            .navigationTitle(String(localized: "Settings")).navigationBarTitleDisplayMode(.inline)
            .toolbar { SheetCloseToolbar(disabled: isWorking, action: close) }
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
        .environment(\.closeSettings, close)
        // Native sheet presentation can create a new hosting boundary on Mac.
        // Use the caller's store here and provide it to every settings subpage.
        .environment(appState)
        .appSheetPresentation(.expanded)
        .interactiveDismissDisabled(drafts.hasChanges || isWorking)
        .confirmDiscardChanges($confirmsDiscard) { dismiss() }
    }

    private var isWorking: Bool { appState.isAccountWorking || drafts.isWorking }

    /// The controller stamps this on first appearance. Showing the timestamp
    /// (not just the switch value) is the C4 step-0 proof that a session really
    /// rendered through the collection container.
    private func refreshTimelineMarker() {
        timelineLastActive = UserDefaults.standard.object(forKey: TimelineCollectionSwitch.lastActiveKey) as? Date
    }

    private func close() {
        guard !isWorking else { return }
        if drafts.hasChanges { confirmsDiscard = true } else { dismiss() }
    }

    private func signOut() {
        do { try appState.signOutAndDeleteCredentials(); dismiss() }
        catch { signOutError = error.localizedDescription }
    }
}

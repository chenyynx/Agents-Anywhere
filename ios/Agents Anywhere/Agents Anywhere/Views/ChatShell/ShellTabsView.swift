import SwiftUI

/// The four-tab shell. The system `TabView` supplies the Liquid Glass tab bar;
/// every tab owns its navigation stack so switching tabs keeps that tab's path.
/// Composer and timeline stay inside their pages — no global bottom accessory.
struct ShellTabsView<ChatRoot: View, DevicesRoot: View>: View {
    @Binding var panes: ShellPanesModel
    let chatRoot: ChatRoot
    let devicesRoot: DevicesRoot
    let onMenu: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    /// The legacy detail wrapper tinted the whole page with the primary
    /// control ink. The tab shell must do the same inside each tab, or a
    /// non-default accent recolours the chat's spinners and menus.
    private var contentTint: Color {
        AppTheme.primaryControlBackground(colorScheme)
    }

    /// Official `HeldTab`/`TabPageEmptyPlacement`: when the same session is
    /// open in both tabs, the hidden copy is parked. Two live pages share one
    /// composer draft and one timeline model — they fight over focus and both
    /// freeze (device report 2026-11-26). Non-duplicate pages stay held so
    /// their scroll/state survives a tab switch.
    private var hiddenTabPlacement: some View {
        Color.clear
    }

    private var chatSession: V2SessionID? {
        if case let .session(id) = panes.chatRoot { return id }
        return nil
    }

    private var deviceSession: V2SessionID? {
        if case let .session(id)? = panes.devicesPath.last { return id }
        return nil
    }

    private var duplicateSessionAcrossTabs: Bool {
        chatSession != nil && chatSession == deviceSession
    }

    private var parksChatTab: Bool {
        panes.selectedTab != .chat && duplicateSessionAcrossTabs
    }

    private var parksDevicesTab: Bool {
        panes.selectedTab != .devices && duplicateSessionAcrossTabs
    }

    var body: some View {
        TabView(selection: $panes.selectedTab) {
            Tab(value: ShellTab.chat) {
                if parksChatTab {
                    hiddenTabPlacement
                } else {
                    NavigationStack { chatRoot }
                        // The session page owns its keyboard insets (composer
                        // is a safeAreaBar); the shell must not move the page.
                        .ignoresSafeArea(.keyboard)
                        .tint(contentTint)
                }
            } label: {
                ShellTabLabel(title: "Chats", image: "anthropicon.chat")
            }
            Tab(value: ShellTab.devices) {
                if parksDevicesTab {
                    hiddenTabPlacement
                } else {
                    // The shell supplies the Devices NavigationStack (it owns
                    // the path and the push destinations).
                    devicesRoot
                        .tint(contentTint)
                }
            } label: {
                ShellTabLabel(title: "Devices", image: "anthropicon.laptop.tab")
            }
            Tab(value: ShellTab.wiki) {
                NavigationStack {
                    PlaceholderTabPage(
                        title: String(localized: "Wiki"),
                        icon: "anthropicon.library",
                        onMenu: onMenu
                    )
                }
            } label: {
                ShellTabLabel(title: "Wiki", image: "anthropicon.library")
            }
            Tab(value: ShellTab.artifacts) {
                NavigationStack {
                    PlaceholderTabPage(
                        title: String(localized: "Artifacts"),
                        icon: "anthropicon.artifacts",
                        onMenu: onMenu
                    )
                }
            } label: {
                ShellTabLabel(title: "Artifacts", image: "anthropicon.artifacts")
            }
        }
        .environment(\.shellTabBarActive, true)
        .onChange(of: duplicateSessionAcrossTabs, initial: true) { _, duplicate in
            guard duplicate, let session = chatSession else { return }
            ClientDiagnosticsLog.shared.record(
                kind: "shell.tabs.duplicate",
                sessionID: session,
                detail: ["tab": panes.selectedTab.rawValue,
                         "parkedChat": parksChatTab ? "1" : "0",
                         "parkedDevices": parksDevicesTab ? "1" : "0"])
        }
    }
}

/// Official tab labels draw the artwork at 20 pt (the sidebar session row's
/// size); the system tab item otherwise renders the asset at its intrinsic
/// size, which made the icons visibly smaller than the official bar.
private struct ShellTabLabel: View {
    let title: LocalizedStringKey
    let image: String

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(image)
                .resizable()
                .scaledToFit()
                .frame(width: 20, height: 20)
        }
    }
}

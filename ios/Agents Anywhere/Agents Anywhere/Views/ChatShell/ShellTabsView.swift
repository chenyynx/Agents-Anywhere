import SwiftUI

/// The four-tab shell. The system `TabView` supplies the Liquid Glass tab bar;
/// every tab owns its navigation stack so switching tabs keeps that tab's path.
/// Composer and timeline stay inside their pages — no global bottom accessory.
struct ShellTabsView<ChatRoot: View, DevicesRoot: View>: View {
    @Binding var panes: ShellPanesModel
    let chatRoot: ChatRoot
    let devicesRoot: DevicesRoot
    let onMenu: () -> Void

    var body: some View {
        TabView(selection: $panes.selectedTab) {
            Tab(value: ShellTab.chat) {
                NavigationStack { chatRoot }
                    // The session page owns its keyboard insets (composer is a
                    // safeAreaBar); the shell must not move the whole page.
                    .ignoresSafeArea(.keyboard)
            } label: {
                ShellTabLabel(title: "Chats", image: "anthropicon.chat")
            }
            Tab(value: ShellTab.devices) {
                NavigationStack { devicesRoot }
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

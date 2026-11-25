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
            Tab("Chats", image: "anthropicon.chat", value: ShellTab.chat) {
                NavigationStack { chatRoot }
                    // The session page owns its keyboard insets (composer is a
                    // safeAreaBar); the shell must not move the whole page.
                    .ignoresSafeArea(.keyboard)
            }
            Tab("Devices", image: "anthropicon.laptop", value: ShellTab.devices) {
                NavigationStack { devicesRoot }
            }
            Tab("Wiki", image: "anthropicon.library", value: ShellTab.wiki) {
                NavigationStack {
                    PlaceholderTabPage(
                        title: String(localized: "Wiki"),
                        icon: "anthropicon.library",
                        onMenu: onMenu
                    )
                }
            }
            Tab("Artifacts", image: "anthropicon.artifacts", value: ShellTab.artifacts) {
                NavigationStack {
                    PlaceholderTabPage(
                        title: String(localized: "Artifacts"),
                        icon: "anthropicon.artifacts",
                        onMenu: onMenu
                    )
                }
            }
        }
    }
}

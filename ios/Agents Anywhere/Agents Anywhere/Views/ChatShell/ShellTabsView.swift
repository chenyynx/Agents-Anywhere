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
    @State private var transitionTask: Task<Void, Never>?
    /// True from a tab tap until the switch settles. Pages park data applies
    /// for this window: a timeline refresh landing inside the system tab
    /// transition stacked on it and turned the fixed ~150–200 ms switch into
    /// 300–570 ms (b1668 log — the big stalls all coincided with recovery or
    /// whole-window refresh bursts).
    @State private var tabTransitioning = false
    /// Covers the page change with a picture of the outgoing page (the
    /// official `TabPageMover` shape; see `TabPageTransition`).
    @State private var pageTransition = TabPageTransition()

    /// The legacy detail wrapper tinted the whole page with the primary
    /// control ink. The tab shell must do the same inside each tab, or a
    /// non-default accent recolours the chat's spinners and menus.
    private var contentTint: Color {
        AppTheme.primaryControlBackground(colorScheme)
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

    /// Logs every write the tab bar makes to the selection, including the
    /// transient ones a settled `onChange` cannot see.
    private var selectionBinding: Binding<ShellTab> {
        Binding(get: { panes.selectedTab }, set: { next in
            guard next != panes.selectedTab else { return }
            ClientDiagnosticsLog.shared.record(
                kind: "shell.tabs.write",
                detail: ["to": next.rawValue],
                dedupe: false)
            // The frame window starts at the tap, not at the first SwiftUI
            // update: a main thread that blocks in the bar's own handler is
            // exactly what `shell.tabs.frame` must be able to see.
            TabSwitchProbe.shared.begin(tab: next.rawValue)
            // The official shape: the outgoing page stays on screen as a
            // picture, the swap itself carries no implicit animation, and the
            // picture is animated out once the destination is in place.
            pageTransition.beginChange()
            UIView.performWithoutAnimation {
                withTransaction(Transaction(animation: nil)) {
                    panes.selectedTab = next
                }
            }
        })
    }

    var body: some View {
        TabView(selection: selectionBinding) {
            Tab(value: ShellTab.chat) {
                NavigationStack { chatRoot }
                    // The session page owns its keyboard insets (composer is a
                    // safeAreaBar); the shell must not move the page.
                    .ignoresSafeArea(.keyboard)
                    .tint(contentTint)
            } label: {
                ShellTabLabel(title: "Chats", image: "anthropicon.chat")
            }
            Tab(value: ShellTab.devices) {
                // The shell supplies the Devices NavigationStack (it owns the
                // path and the push destinations).
                devicesRoot
                    .tint(contentTint)
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
        .background(alignment: .topLeading) {
            TabPageTransitionHost(driver: pageTransition)
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)
        }
        .environment(\.shellTabBarActive, true)
        .environment(\.shellTabTransitioning, tabTransitioning)
        .onChange(of: duplicateSessionAcrossTabs, initial: true) { _, duplicate in
            guard duplicate, let session = chatSession else { return }
            ClientDiagnosticsLog.shared.record(
                kind: "shell.tabs.duplicate",
                sessionID: session,
                detail: ["tab": panes.selectedTab.rawValue])
        }
        // Brackets the bar's switch animation so page work can be deferred
        // while the transition is in flight, and so a transient selection
        // write can be told apart from a settled tab.
        .onChange(of: panes.selectedTab) { old, next in
            // The selection has been committed: the destination page is
            // mounted, so the cover can finish its fade (the official's
            // "settle on picture, then show the page" order).
            pageTransition.revealWhenSettled()
            ClientDiagnosticsLog.shared.record(
                kind: "shell.tabs.transition",
                detail: ["phase": "start",
                         "from": old.rawValue,
                         "to": next.rawValue],
                dedupe: false)
            tabTransitioning = true
            transitionTask?.cancel()
            transitionTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
                tabTransitioning = false
                ClientDiagnosticsLog.shared.record(
                    kind: "shell.tabs.transition",
                    detail: ["phase": "settle",
                             "to": panes.selectedTab.rawValue],
                    dedupe: false)
            }
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

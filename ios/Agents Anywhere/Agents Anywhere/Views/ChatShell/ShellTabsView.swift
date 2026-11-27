import QuartzCore
import SwiftUI
import UIKit

/// The four-tab shell.
///
/// The pages are **persistent**: every tab that has been opened stays mounted
/// in one stack, and a switch only changes which page is visible. The previous
/// shape hosted them in a SwiftUI `TabView`, whose `UITabBarController`
/// detaches the hidden page; the destination then had to be laid out, drawn
/// and rasterised again on every switch. b1695 measured that cost where it
/// does not live: the main thread idles in the runloop for the whole
/// 200–575 ms freeze while frames stop arriving, and the cost scales with the
/// page's content (chat 575 ms, placeholder tabs 80 ms).
///
/// The bar is a plain `UITabBar` (see `ShellTabBar`), so the Liquid Glass look
/// stays the system's; only page hosting moved out of the controller.
struct ShellTabsView<ChatRoot: View, DevicesRoot: View>: View {
    @Binding var panes: ShellPanesModel
    let chatRoot: ChatRoot
    let devicesRoot: DevicesRoot
    let onMenu: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var transitionTask: Task<Void, Never>?
    /// True from a tab tap until the switch settles. Pages park data applies
    /// for this window: a timeline refresh landing inside a switch stacked on
    /// it and turned a clean switch into 300–570 ms (b1668 log).
    @State private var tabTransitioning = false
    /// Tabs opened at least once. A page is built on its first visit and never
    /// removed afterwards — unmounting is exactly what forces the system to
    /// rasterise it again (see the type comment). This keeps the launch path
    /// lazy: only the restored tab builds at startup.
    @State private var visited: Set<ShellTab> = [.chat]

    /// The legacy detail wrapper tinted the whole page with the primary
    /// control ink. The tab shell must do the same inside each tab, or a
    /// non-default accent recolours the chat's spinners and menus.
    private var contentTint: Color {
        AppTheme.primaryControlBackground(colorScheme)
    }

    /// The window's home-indicator inset. The shell sits inside the drawer,
    /// whose `.ignoresSafeArea()` hides this from SwiftUI's environment.
    private var homeIndicatorInset: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: { $0.isKeyWindow })?
            .safeAreaInsets.bottom ?? 0
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

    var body: some View {
        ZStack {
            ForEach(ShellTab.allCases, id: \.self) { tab in
                if visited.contains(tab) {
                    page(tab)
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // The drawer this shell lives in ignores the system safe area, so
            // the home-indicator inset no longer reaches the pages by itself
            // (the old system tab bar delivered it through its controller).
            // Rebuild it explicitly: bar items on top, a transparent
            // home-indicator strip below — the pages then see
            // 49 + home-indicator, exactly what the system bar provided, and
            // the composer sits above the bar instead of underneath it
            // (b1696 device report: the composer was hidden behind the bar).
            VStack(spacing: 0) {
                ShellTabBar(selection: panes.selectedTab, onSelect: select)
                    .frame(height: ShellTabBarMetrics.contentHeight)
                Color.clear
                    .frame(height: homeIndicatorInset)
            }
            // The bar stays put when the keyboard rises; the pages own their
            // keyboard insets.
            .ignoresSafeArea(.keyboard)
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
        .onChange(of: panes.selectedTab, initial: true) { _, next in
            // A restored (or programmatic) selection mounts its page too.
            if !visited.contains(next) { visited.insert(next) }
        }
        // Brackets the switch so page work can be deferred while it is in
        // flight, and so a transient selection write can be told apart from a
        // settled tab.
        .onChange(of: panes.selectedTab) { old, next in
            TabSwitchProbe.shared.mark("onchange", extra: ["from": old.rawValue])
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

    /// One persistent page. Only the selected one is visible; the others stay
    /// mounted at zero opacity (never removed, which is the whole point).
    @ViewBuilder private func page(_ tab: ShellTab) -> some View {
        let visible = panes.selectedTab == tab
        pageContent(tab)
            .environment(\.composerFocusEnabled, visible)
            .environment(\.shellTabVisible, visible)
            .opacity(visible ? 1 : 0)
            .allowsHitTesting(visible)
            .accessibilityHidden(!visible)
            .zIndex(visible ? 1 : 0)
    }

    @ViewBuilder private func pageContent(_ tab: ShellTab) -> some View {
        switch tab {
        case .chat:
            NavigationStack { chatRoot }
                // The session page owns its keyboard insets (composer is a
                // safeAreaBar); the shell must not move the page.
                .ignoresSafeArea(.keyboard)
                .tint(contentTint)
        case .devices:
            // The shell supplies the Devices NavigationStack (it owns the
            // path and the push destinations).
            devicesRoot
                .tint(contentTint)
        case .wiki:
            NavigationStack {
                PlaceholderTabPage(
                    title: String(localized: "Wiki"),
                    icon: "anthropicon.library",
                    onMenu: onMenu
                )
            }
        case .artifacts:
            NavigationStack {
                PlaceholderTabPage(
                    title: String(localized: "Artifacts"),
                    icon: "anthropicon.artifacts",
                    onMenu: onMenu
                )
            }
        }
    }

    /// The bar's selection. No system transition runs — the controller that
    /// owned one is gone — so the write is a plain state change; the probe
    /// still brackets it so `shell.tabs.frame` keeps measuring the switch.
    private func select(_ next: ShellTab) {
        guard next != panes.selectedTab else { return }
        ClientDiagnosticsLog.shared.record(
            kind: "shell.tabs.write",
            detail: ["to": next.rawValue],
            dedupe: false)
        TabSwitchProbe.shared.begin(tab: next.rawValue)
        if !visited.contains(next) { visited.insert(next) }
        UIView.performWithoutAnimation {
            withTransaction(Transaction(animation: nil)) {
                panes.selectedTab = next
            }
        }
        TabSwitchProbe.shared.mark("written")
    }
}

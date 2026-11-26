import Combine
import SwiftUI
import UIKit

/// The four-tab shell. The system `TabView` hosts the pages (so each tab keeps
/// its navigation stack and its mounted page), but its bar is hidden: the
/// shell draws the bar itself (`DrawnShellTabBar`, the official
/// `ClaudeMinimalTabBar` design) because the system bar's Liquid Glass
/// selection transition blocked the main thread for 200–400 ms on every switch
/// (b1661 log, even between two placeholder tabs). Composer and timeline stay
/// inside their pages — no global bottom accessory.
struct ShellTabsView<ChatRoot: View, DevicesRoot: View>: View {
    @Binding var panes: ShellPanesModel
    let chatRoot: ChatRoot
    let devicesRoot: DevicesRoot
    let onMenu: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var transitionTask: Task<Void, Never>?
    /// Draw the bar ourselves (official design). The diagnostics settings
    /// toggle flips this to fall back to the system bar without a rebuild.
    @AppStorage(ShellTabBarMetrics.drawnBarDefaultsKey) private var drawnTabBar = true
    /// The drawn bar goes away while the keyboard is up, like the system bar.
    /// The pages own the keyboard inset; the bar only stops occupying its
    /// footprint so the composer can sit on the keyboard.
    @State private var keyboardOnScreen = false

    private var tabBarVisibility: Visibility {
        drawnTabBar ? .hidden : .visible
    }

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
            ClientDiagnosticsLog.shared.record(
                kind: "shell.tabs.write",
                detail: ["to": next.rawValue],
                dedupe: false)
            // The frame window starts at the tap, not at the first SwiftUI
            // update: a main thread that blocks in the bar's own handler is
            // exactly what `shell.tabs.frame` must be able to see.
            TabSwitchProbe.shared.begin(tab: next.rawValue)
            panes.selectedTab = next
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
                    .toolbar(tabBarVisibility, for: .tabBar)
            } label: {
                ShellTabLabel(title: "Chats", image: "anthropicon.chat")
            }
            Tab(value: ShellTab.devices) {
                // The shell supplies the Devices NavigationStack (it owns the
                // path and the push destinations).
                devicesRoot
                    .tint(contentTint)
                    .toolbar(tabBarVisibility, for: .tabBar)
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
                .toolbar(tabBarVisibility, for: .tabBar)
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
                .toolbar(tabBarVisibility, for: .tabBar)
            } label: {
                ShellTabLabel(title: "Artifacts", image: "anthropicon.artifacts")
            }
        }
        .environment(\.shellTabBarActive, true)
        // `.toolbar(.hidden, for: .tabBar)` covers the tab roots; a page the
        // Devices stack pushes can re-show the system bar, so the responder
        // chain hider re-asserts on every pane change.
        .background {
            SystemTabBarHider(enabled: drawnTabBar, panes: panes)
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
        }
        // The drawn bar takes the system bar's safe-area footprint: pages lay
        // out above it exactly as they did above the system bar, and the bar
        // itself floats in the vacated space (the page still draws behind it).
        // With the keyboard up it goes away — the composer sits on the
        // keyboard, like it did under the system bar.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if drawnTabBar, !keyboardOnScreen {
                DrawnShellTabBar(selection: panes.selectedTab) { tab in
                    selectionBinding.wrappedValue = tab
                }
                .padding(.horizontal, ShellTabBarMetrics.drawnBarSideInset)
                .padding(.bottom, ShellTabBarMetrics.drawnBarBottomGap)
            }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: UIResponder.keyboardWillShowNotification)) { note in
            withAnimation(.easeOut(duration: Self.keyboardDuration(note))) {
                keyboardOnScreen = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: UIResponder.keyboardWillHideNotification)) { note in
            withAnimation(.easeOut(duration: Self.keyboardDuration(note))) {
                keyboardOnScreen = false
            }
        }
        .onChange(of: drawnTabBar, initial: true) { _, enabled in
            ClientDiagnosticsLog.shared.record(
                kind: "shell.tabbar.drawn",
                detail: ["enabled": enabled ? "1" : "0",
                         "inset": String(Int(ShellTabBarMetrics.drawnBarInset))],
                dedupe: true)
        }
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
            ClientDiagnosticsLog.shared.record(
                kind: "shell.tabs.transition",
                detail: ["phase": "start",
                         "from": old.rawValue,
                         "to": next.rawValue],
                dedupe: false)
            transitionTask?.cancel()
            transitionTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
                ClientDiagnosticsLog.shared.record(
                    kind: "shell.tabs.transition",
                    detail: ["phase": "settle",
                             "to": panes.selectedTab.rawValue],
                    dedupe: false)
            }
        }
    }
}

extension ShellTabsView {
    /// Follow the keyboard's own animation so the bar's footprint leaves in
    /// step with the composer moving onto the keyboard.
    private static func keyboardDuration(_ note: Notification) -> Double {
        (note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
    }
}

/// Hides the system tab bar while the shell draws its own (official
/// `setTabBarHidden:animated:`). SwiftUI's `.toolbar(.hidden, for: .tabBar)`
/// covers the tab roots; this backstop catches a pushed page re-showing the
/// bar, and re-asserts on every pane change.
private struct SystemTabBarHider: UIViewRepresentable {
    let enabled: Bool
    /// Only exists to re-run `updateUIView` when the panes move (a device
    /// drill-down, a tab change). The hider itself reads nothing from it.
    let panes: ShellPanesModel

    func makeUIView(context: Context) -> HidingView {
        let view = HidingView()
        view.isUserInteractionEnabled = false
        view.enabled = enabled
        return view
    }

    func updateUIView(_ uiView: HidingView, context: Context) {
        uiView.enabled = enabled
        uiView.hideSystemTabBar()
    }

    final class HidingView: UIView {
        var enabled = true

        override func didMoveToWindow() {
            super.didMoveToWindow()
            hideSystemTabBar()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            hideSystemTabBar()
        }

        /// Mirrors the toggle: hidden while the shell draws its own bar,
        /// visible again on the fallback. Idempotent, so re-asserting on every
        /// layout cannot fight SwiftUI's own toolbar updates.
        func hideSystemTabBar() {
            var responder: UIResponder? = self
            while let current = responder {
                if let controller = current as? UIViewController {
                    var candidate: UIViewController? = controller
                    while let level = candidate {
                        if let tabs = level as? UITabBarController {
                            if tabs.tabBar.isHidden != enabled { tabs.tabBar.isHidden = enabled }
                            return
                        }
                        candidate = level.parent
                    }
                }
                responder = current.next
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

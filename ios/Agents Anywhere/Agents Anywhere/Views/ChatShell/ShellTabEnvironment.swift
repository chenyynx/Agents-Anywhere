import SwiftUI

/// Metrics the tab shell imposes on the pages it hosts.
nonisolated enum ShellTabBarMetrics {
    /// The official app leaves 8.3 pt between a page's composer capsule and
    /// the Liquid Glass tab bar (109 build, 1179×2556 @3x screenshot).
    static let composerGap: CGFloat = 8

    // MARK: - Drawn bar (official `ClaudeMinimalTabBar`, CANONICAL/29)
    //
    // The system tab bar's Liquid Glass selection transition blocked the main
    // thread for 200–400 ms on every switch in the b1661 device log — even
    // between two placeholder tabs — and cannot be made cheaper from SwiftUI.
    // The shell draws its own bar instead, with the system's glass material
    // and its own (millisecond) selected-pill movement.

    /// Capsule height, icons + labels + padding included.
    static let drawnBarHeight: CGFloat = 64
    /// Side margin of the floating capsule.
    static let drawnBarSideInset: CGFloat = 16
    /// Gap between the capsule and the home indicator.
    static let drawnBarBottomGap: CGFloat = 8
    /// What the bar adds to a page's bottom safe area (capsule + gap) — the
    /// same space the system bar used to take above the home indicator.
    static var drawnBarInset: CGFloat { drawnBarHeight + drawnBarBottomGap }
    /// Fall back to the system bar without a rebuild (diagnostics settings).
    static let drawnBarDefaultsKey = "aa.shell.tabs.drawnBar"
}

private struct ShellTabBarActiveKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True inside the bottom-tab shell. Pages use it for the extra composer
    /// gap; the legacy drawer shell leaves it false.
    var shellTabBarActive: Bool {
        get { self[ShellTabBarActiveKey.self] }
        set { self[ShellTabBarActiveKey.self] = newValue }
    }
}

private struct ComposerFocusEnabledKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// False on a mounted tab page that is not visible. Two pages of the same
    /// session share one draft and one `isFocused`; only the visible page may
    /// mirror focus, or both editors fight for first responder and the
    /// keyboard drops.
    var composerFocusEnabled: Bool {
        get { self[ComposerFocusEnabledKey.self] }
        set { self[ComposerFocusEnabledKey.self] = newValue }
    }
}

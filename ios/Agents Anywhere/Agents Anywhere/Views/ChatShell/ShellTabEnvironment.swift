import SwiftUI

/// User-facing switches of the tab shell.
nonisolated enum ShellTabPreferences {
    /// UserDefaults key (Bool, default true): a hidden tab page parks its
    /// timeline's snapshot applies. The backlog lands in one apply after the
    /// switch settles; turning this off restores live background updates.
    static let hiddenPauseKey = SessionTimelinePreferences.hiddenPauseKey
}

/// Metrics the tab shell imposes on the pages it hosts.
nonisolated enum ShellTabBarMetrics {
    /// The official app leaves 8.3 pt between a page's composer capsule and
    /// the Liquid Glass tab bar (109 build, 1179×2556 @3x screenshot).
    static let composerGap: CGFloat = 8
    /// The item row of the system tab bar. The bar is laid out explicitly now
    /// (the drawer the shell lives in ignores the system safe area, so the
    /// safe-area inset no longer arrives by itself); 49 pt is the bar's
    /// standard content height on iPhone.
    static let contentHeight: CGFloat = 49
}

private struct ShellTabTransitioningKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True from a tab tap until the switch settles (~350 ms). Pages park
    /// data applies for this window: a timeline refresh landing inside the
    /// system tab transition stacked on top of it and turned the fixed
    /// ~150–200 ms switch into 300–570 ms (b1668 log: the big stalls all
    /// coincided with recovery/refresh bursts). The parking mechanism is the
    /// drawer transition's; the content lands right after the switch.
    var shellTabTransitioning: Bool {
        get { self[ShellTabTransitioningKey.self] }
        set { self[ShellTabTransitioningKey.self] = newValue }
    }
}

private struct ShellTabBarActiveKey: EnvironmentKey {
    static let defaultValue = false
}

private struct ShellTabVisibleKey: EnvironmentKey {
    /// True outside the tab shell (the legacy drawer never hides a mounted
    /// page), so a page's lifecycle falls back to onAppear/onDisappear.
    static let defaultValue = true
}

extension EnvironmentValues {
    /// Whether this tab page is the visible one. The tab shell keeps every
    /// visited page mounted and only flips visibility, so a page's "left the
    /// screen" work (drop the keyboard, leave the page registry) arrives here
    /// instead of through `onDisappear`, which no longer fires on a switch.
    var shellTabVisible: Bool {
        get { self[ShellTabVisibleKey.self] }
        set { self[ShellTabVisibleKey.self] = newValue }
    }
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

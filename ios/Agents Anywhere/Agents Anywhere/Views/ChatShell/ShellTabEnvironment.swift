import SwiftUI

/// Metrics the tab shell imposes on the pages it hosts.
nonisolated enum ShellTabBarMetrics {
    /// The official app leaves 8.3 pt between a page's composer capsule and
    /// the Liquid Glass tab bar (109 build, 1179×2556 @3x screenshot).
    static let composerGap: CGFloat = 8
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

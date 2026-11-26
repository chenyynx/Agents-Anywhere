import QuartzCore
import SwiftUI
import UIKit

/// Drives a tab change the way the official shell does (1.261123.51,
/// `TabPageMover`/`MinimalTabBar`): take the system `UITabBarController`
/// behind SwiftUI's `TabView` and set `selectedIndex` inside
/// `performWithoutAnimation`, instead of letting the TabView run its default
/// transition.
///
/// The b1686 probe showed the switch's ~200 ms are spent with the main thread
/// **idle** in the runloop (`mach_msg2_trap`, 86–98 % of samples): the app is
/// waiting on the system's switch, not computing. The official bypasses that
/// by driving the controller itself.
@MainActor
final class TabSwitchDriver {
    private weak var host: UIView?

    func attach(host: UIView) {
        self.host = host
    }

    /// Drive the system controller directly. Returns true when it was found
    /// and the index applied; the SwiftUI selection write still follows, so
    /// the TabView's own state lands on the same tab.
    @discardableResult
    func select(index: Int, to tab: String) -> Bool {
        let started = CACurrentMediaTime()
        guard let host else {
            report(reason: "host", tab: tab, started: started, tabs: nil, root: nil, count: nil)
            return false
        }
        guard let window = host.window else {
            report(reason: "window", tab: tab, started: started, tabs: nil, root: nil, count: nil)
            return false
        }
        guard let root = window.rootViewController else {
            report(reason: "root", tab: tab, started: started, tabs: nil, root: nil, count: nil)
            return false
        }
        guard let tabs = Self.tabController(in: root, window: window) else {
            report(reason: "tabs", tab: tab, started: started, tabs: nil,
                   root: root, count: root.children.count)
            return false
        }
        let count = tabs.viewControllers?.count ?? 0
        guard index >= 0, index < count else {
            report(reason: "index", tab: tab, started: started, tabs: tabs, root: root, count: count)
            return false
        }
        UIView.performWithoutAnimation {
            tabs.selectedIndex = index
        }
        report(reason: "ok", tab: tab, started: started, tabs: tabs, root: root, count: count)
        return true
    }

    private func report(reason: String, tab: String, started: CFTimeInterval,
                        tabs: UITabBarController?,
                        root: UIViewController?, count: Int?) {
        var detail = ["to": tab,
                      "direct": reason == "ok" ? "1" : "0",
                      "reason": reason,
                      "ms": String(Int((CACurrentMediaTime() - started) * 1000))]
        if let root { detail["root"] = String(describing: type(of: root)) }
        if let tabs {
            detail["tabs"] = String(describing: type(of: tabs))
            detail["count"] = String(tabs.viewControllers?.count ?? 0)
        } else if let count {
            detail["children"] = String(count)
        }
        ClientDiagnosticsLog.shared.record(
            kind: "shell.tabs.switch",
            detail: detail,
            dedupe: false)
    }

    private static func tabController(in root: UIViewController,
                                      window: UIWindow) -> UITabBarController? {
        if let tabs = root as? UITabBarController { return tabs }
        for child in root.children {
            if let tabs = tabController(in: child, window: window) { return tabs }
        }
        if let presented = root.presentedViewController,
           let tabs = tabController(in: presented, window: window) {
            return tabs
        }
        // Fallback: a container whose view is in the tree without being a
        // registered child still shows up through its view's responder chain.
        var responder: UIResponder? = window.next
        while let next = responder {
            if let tabs = next as? UITabBarController { return tabs }
            responder = next.next
        }
        return scanViews(window)
    }

    private static func scanViews(_ view: UIView) -> UITabBarController? {
        var responder: UIResponder? = view.next
        while let next = responder {
            if let tabs = next as? UITabBarController { return tabs }
            responder = next.next
        }
        for sub in view.subviews {
            if let tabs = scanViews(sub) { return tabs }
        }
        return nil
    }
}

/// Hosts the driver inside the tab shell so it can reach the system
/// `UITabBarController` SwiftUI's `TabView` is backed by.
struct TabSwitchDriverHost: UIViewRepresentable {
    let driver: TabSwitchDriver

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        driver.attach(host: view)
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        driver.attach(host: view)
    }
}

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
    func select(index: Int) -> Bool {
        guard let host, let tabs = Self.tabController(from: host) else { return false }
        guard index >= 0, index < (tabs.viewControllers?.count ?? 0) else { return false }
        UIView.performWithoutAnimation {
            tabs.selectedIndex = index
        }
        return true
    }

    private static func tabController(from view: UIView) -> UITabBarController? {
        var responder: UIResponder? = view.next
        while let next = responder {
            if let tabs = next as? UITabBarController { return tabs }
            responder = next.next
        }
        guard let root = view.window?.rootViewController else { return nil }
        return findTabController(in: root)
    }

    private static func findTabController(in controller: UIViewController) -> UITabBarController? {
        if let tabs = controller as? UITabBarController { return tabs }
        for child in controller.children {
            if let tabs = findTabController(in: child) { return tabs }
        }
        if let presented = controller.presentedViewController,
           let tabs = findTabController(in: presented) {
            return tabs
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

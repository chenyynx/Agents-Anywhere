import QuartzCore
import SwiftUI
import UIKit

/// A cover-based tab transition, modelled on the official tab shell
/// (`ClaudeMinimalTabBar.TabPageMover`, 1.261123.51; see
/// `/home/ubuntu/aa-test/claude-ios-re/CANONICAL/29-tab-shell-261123.md` §13).
///
/// The official never lets the live page take part in the visible change:
/// `PagePicture` is a group of real page views, the page swap itself runs
/// inside `performWithoutAnimation:`, and a `PageCover` is animated out with
/// `+[UIView animateWithDuration:delay:options:animations:completion:]` using
/// a 0.15 s duration (double constant at 0x104d4e360). Because Core Animation
/// runs the cover on the render server, the main thread may keep laying the
/// destination page out underneath without dropping the cover's frames.
///
/// This is the SwiftUI-side equivalent: snapshot the outgoing page before the
/// selection changes, cover the page area (below the system tab bar, so the
/// bar still animates), then fade the cover once the destination has been
/// committed and laid out. The page body itself is not asked to render the
/// switch.
@MainActor
final class TabPageTransition {
    /// The official's animateWithDuration duration (0x104d4e360 = 0.15).
    static let revealSeconds: TimeInterval = 0.15

    private weak var host: UIView?
    private var cover: UIView?
    private var beganAt: CFTimeInterval = 0

    func attach(host: UIView) {
        self.host = host
    }

    /// Install the outgoing page's picture. Called before the selection write,
    /// so the cover shows the page the reader is leaving.
    func beginChange() {
        guard let host else { return }
        guard let tabs = Self.tabController(from: host) else {
            ClientDiagnosticsLog.shared.record(
                kind: "shell.tabs.cover",
                detail: ["phase": "begin", "tabs": "0"],
                dedupe: false)
            return
        }
        // A second tap before the first reveal finished: drop the old cover.
        cover?.removeFromSuperview()
        cover = nil

        guard let pageView = tabs.selectedViewController?.view else { return }
        let cover = UIView(frame: tabs.view.bounds)
        cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        cover.isUserInteractionEnabled = false
        cover.backgroundColor = pageView.backgroundColor ?? .systemBackground
        let picture = pageView.snapshotView(afterScreenUpdates: false)
        if let picture {
            picture.frame = cover.bounds
            picture.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            cover.addSubview(picture)
        }
        // Below the system tab bar: the bar keeps its own selection animation
        // while the page area is covered.
        let bar = tabs.tabBar
        let barBelow = bar.superview === tabs.view && !bar.isHidden
        if barBelow {
            tabs.view.insertSubview(cover, belowSubview: bar)
        } else {
            tabs.view.addSubview(cover)
        }
        self.cover = cover
        beganAt = CACurrentMediaTime()
        ClientDiagnosticsLog.shared.record(
            kind: "shell.tabs.cover",
            detail: ["phase": "begin",
                     "tabs": "1",
                     "picture": picture == nil ? "0" : "1",
                     "barBelow": barBelow ? "1" : "0"],
            dedupe: false)
    }

    /// Reveal the destination once SwiftUI has committed the switch. The
    /// layout pass is forced while the cover is still up, so the fade never
    /// exposes a half-laid-out page (the official's `isPageInPlace` gate).
    func revealWhenSettled() {
        guard let host, let cover else { return }
        let tabs = Self.tabController(from: host)
        DispatchQueue.main.async { [weak self, weak cover] in
            guard let self, let cover, self.cover === cover else { return }
            tabs?.view.layoutIfNeeded()
            ClientDiagnosticsLog.shared.record(
                kind: "shell.tabs.cover",
                detail: ["phase": "reveal",
                         "ms": String(Int((CACurrentMediaTime() - self.beganAt) * 1000))],
                dedupe: false)
            UIView.animate(withDuration: Self.revealSeconds,
                           delay: 0,
                           options: [.curveEaseInOut, .beginFromCurrentState]) {
                cover.alpha = 0
            } completion: { _ in
                cover.removeFromSuperview()
                if self.cover === cover { self.cover = nil }
            }
        }
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

/// Hosts the transition driver inside the tab shell so it can reach the system
/// `UITabBarController` SwiftUI's `TabView` is backed by.
struct TabPageTransitionHost: UIViewRepresentable {
    let driver: TabPageTransition

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

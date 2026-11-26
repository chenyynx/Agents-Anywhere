import QuartzCore
import SwiftUI
import UIKit

/// A cover-based tab transition, modelled on the official tab shell
/// (`ClaudeMinimalTabBar.TabPageMover`, 1.261123.51; see
/// `/home/ubuntu/aa-test/claude-ios-re/CANONICAL/29-tab-shell-261123.md` §13).
///
/// The official never lets the live page take part in the visible change:
/// `PagePicture` is a group of real page views, and the page swap itself runs
/// inside `performWithoutAnimation:` (0x103b841b8). The cover exists to hold
/// the previous picture while the destination is put in place; the result the
/// user sees is an instant tab change, not a fade — pp 2026-11-27: 「官方没有
/// 这种动画」.
///
/// (There *is* a 0.15 s `+[UIView animateWithDuration:...]` in the cover code
/// (duration constant 0x104d4e360), but what it animates is not yet proven —
/// the cover path moves frames/centers (`setCenter:`/`setFrame:` users
/// 0x103af541c / 0x103aee5c8) and never calls `setAlpha:`. Do not read it as
/// a page fade.)
///
/// This is the SwiftUI-side equivalent: snapshot the outgoing page before the
/// selection changes, cover the page area (below the system tab bar, so the
/// bar stays live), let the swap happen underneath without animation, then
/// remove the cover once the destination has been committed and laid out.
@MainActor
final class TabPageTransition {

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
        // The cover must never hide the tab bar (pp 2026-11-27): the bar keeps
        // responding and animating while the page area is covered. Insert
        // below the bar's top-level container when that container is a direct
        // subview of the tab controller's view; if SwiftUI hosts the bar
        // somewhere else, clip the cover to the page area above the bar
        // instead of falling back to covering everything.
        let bar = tabs.tabBar
        var anchor: UIView? = bar
        while let superview = anchor?.superview, superview !== tabs.view {
            anchor = superview
        }
        let barBelow = anchor?.superview === tabs.view && !bar.isHidden
        if barBelow, let anchor {
            cover.frame = tabs.view.bounds
            tabs.view.insertSubview(cover, belowSubview: anchor)
        } else {
            let barFrame = bar.convert(bar.bounds, to: tabs.view)
            let height = max(0, min(tabs.view.bounds.height, barFrame.minY))
            cover.frame = CGRect(x: 0, y: 0,
                                 width: tabs.view.bounds.width, height: height)
            tabs.view.addSubview(cover)
        }
        self.cover = cover
        beganAt = CACurrentMediaTime()
        ClientDiagnosticsLog.shared.record(
            kind: "shell.tabs.cover",
            detail: ["phase": "begin",
                     "tabs": "1",
                     "picture": picture == nil ? "0" : "1",
                     "barBelow": barBelow ? "1" : "0",
                     "clipped": barBelow ? "0" : "1"],
            dedupe: false)
    }

    /// Reveal the destination once SwiftUI has committed the switch. The
    /// layout pass is forced while the cover is still up, so the cut never
    /// exposes a half-laid-out page (the official's `isPageInPlace` gate).
    /// The cover is removed without animation: the official's tab change is
    /// an instant cut, not a cross-fade.
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
            cover.removeFromSuperview()
            if self.cover === cover { self.cover = nil }
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

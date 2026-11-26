import QuartzCore
import SwiftUI
import UIKit

/// A cover-based tab transition, modelled on the official tab shell
/// (`ClaudeMinimalTabBar.TabPageMover`, 1.261123.51; see
/// `/home/ubuntu/aa-test/claude-ios-re/CANONICAL/29-tab-shell-261123.md` §13).
///
/// What the official does that matters here:
/// * pages are kept alive by the system `UITabBarController`;
/// * the page swap itself runs inside `performWithoutAnimation:`;
/// * `TabPageMover` keeps one `PagePicture` per tab (`kept: [Int: PagePicture]`)
///   and `PageChangeCover(old:showsNew:ground:)` decides which picture the
///   user sees during the change. `showsNew` is why a rapid switch does not
///   leave the outgoing page on screen (pp 2026-11-27: 「快速切页能看到残留」).
///
/// This is the SwiftUI-side equivalent: capture the page being left, hold the
/// **destination's** picture over the page area (below the tab bar) when one
/// is known, swap the selection without animation, and remove the cover as an
/// instant cut once the destination is the selected page and has laid out.
@MainActor
final class TabPageTransition {
    private weak var host: UIView?
    private var cover: UIView?
    private var coverTarget = 0
    private var beganAt: CFTimeInterval = 0
    /// One picture per tab, captured when leaving it. The official keeps the
    /// same table (`TabPageMover.kept`); it is what lets the cover show the
    /// destination immediately instead of the page being left.
    private var pictures: [Int: UIView] = [:]

    func attach(host: UIView) {
        self.host = host
    }

    /// Install the cover before the selection write: the destination's kept
    /// picture when available, otherwise the outgoing page's picture.
    func beginChange(to index: Int) {
        guard let host else { return }
        guard let tabs = Self.tabController(from: host) else {
            ClientDiagnosticsLog.shared.record(
                kind: "shell.tabs.cover",
                detail: ["phase": "begin", "tabs": "0"],
                dedupe: false)
            return
        }
        cover?.removeFromSuperview()
        cover = nil
        let from = tabs.selectedIndex
        if let pageView = tabs.selectedViewController?.view,
           let kept = pageView.snapshotView(afterScreenUpdates: false) {
            pictures[from] = kept
        }

        var source = "none"
        var content: UIView?
        if index != from, let kept = pictures.removeValue(forKey: index) {
            content = kept
            source = "kept"
        } else if let pageView = tabs.selectedViewController?.view,
                  let snap = pageView.snapshotView(afterScreenUpdates: false) {
            content = snap
            source = "outgoing"
        }

        let cover = UIView(frame: tabs.view.bounds)
        cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        cover.isUserInteractionEnabled = false
        cover.backgroundColor = (tabs.selectedViewController?.view.backgroundColor) ?? .systemBackground
        if let content {
            content.frame = cover.bounds
            content.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            cover.addSubview(content)
        }

        // Never hide the tab bar: insert below its top-level container, or
        // clip to the page area above it when the bar is not a direct
        // subview of the tab controller's view.
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
        coverTarget = index
        beganAt = CACurrentMediaTime()
        ClientDiagnosticsLog.shared.record(
            kind: "shell.tabs.cover",
            detail: ["phase": "begin",
                     "tabs": "1",
                     "from": String(from),
                     "to": String(index),
                     "picture": content == nil ? "0" : "1",
                     "source": source,
                     "barBelow": barBelow ? "1" : "0",
                     "clipped": barBelow ? "0" : "1"],
            dedupe: false)
    }

    /// Reveal the destination once the selection has committed to it and its
    /// page has laid out. Bounded retry stands in for the official's
    /// `awaitedIndex`/`longWait`: a rapid switch keeps the newer cover.
    func revealWhenSettled() {
        guard let host, let cover else { return }
        let tabs = Self.tabController(from: host)
        scheduleReveal(cover: cover, target: coverTarget, tabs: tabs, attempt: 0)
    }

    private func scheduleReveal(cover: UIView, target: Int,
                                tabs: UITabBarController?, attempt: Int) {
        let delay: TimeInterval = attempt == 0 ? 0 : 0.016
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak cover, weak tabs] in
            guard let self, let cover, self.cover === cover else { return }
            if let selected = tabs?.selectedIndex, selected != target, attempt < 20 {
                self.scheduleReveal(cover: cover, target: target, tabs: tabs, attempt: attempt + 1)
                return
            }
            tabs?.view.layoutIfNeeded()
            ClientDiagnosticsLog.shared.record(
                kind: "shell.tabs.cover",
                detail: ["phase": "reveal",
                         "to": String(target),
                         "attempts": String(attempt),
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

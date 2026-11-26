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
    /// One kept picture per tab: the page's snapshot taken when the reader
    /// left it (the official's `TabPageMover.kept: [Int: PagePicture]`).
    private struct Picture {
        let view: UIView
        let at: CFTimeInterval
    }

    private static let pictureFreshSeconds: TimeInterval = 20

    private weak var host: UIView?
    private var pictures: [Int: Picture] = [:]
    private var cover: UIView?
    private var coverSource = "none"
    private var coverBegan: CFTimeInterval = 0
    private var revealLink: CADisplayLink?
    private var revealTicker: DisplayTicker?
    private var revealTicks = 0
    private var revealFallback: DispatchWorkItem?

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
        // SwiftUI's TabView is backed by a private `UIKitTabBarController`
        // that uses the iOS 18+ `UITab` API: its `viewControllers` is empty
        // (b1690 log: count=0), so drive `tabs`/`selectedTab` instead.
        let items = tabs.tabs
        if !items.isEmpty {
            guard index >= 0, index < items.count else {
                report(reason: "index", tab: tab, started: started,
                       tabs: tabs, root: root, count: items.count)
                return false
            }
            // Hold the destination's kept picture (or the outgoing page, as
            // a fallback) while the switch's first frame is being produced;
            // the b1691 logs show that first frame can take 200–400 ms with
            // the whole screen (tab bar included) frozen.
            installCover(tabs: tabs, to: index)
            UIView.performWithoutAnimation {
                tabs.selectedTab = items[index]
            }
            scheduleReveal()
            report(reason: "ok", tab: tab, started: started,
                   tabs: tabs, root: root, count: items.count)
            return true
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
            detail["count"] = String(tabs.tabs.count)
            detail["vcs"] = String(tabs.viewControllers?.count ?? 0)
        } else if let count {
            detail["children"] = String(count)
        }
        ClientDiagnosticsLog.shared.record(
            kind: "shell.tabs.switch",
            detail: detail,
            dedupe: false)
    }

    // MARK: - Kept pictures and cover

    private func pageView(of tabs: UITabBarController) -> UIView? {
        tabs.selectedViewController?.view ?? tabs.selectedTab?.viewController?.view
    }

    private func installCover(tabs: UITabBarController, to index: Int) {
        cover?.removeFromSuperview()
        cover = nil
        revealLink?.invalidate()
        revealLink = nil
        revealTicker = nil
        revealFallback?.cancel()
        revealFallback = nil

        let now = CACurrentMediaTime()
        let from = tabs.tabs.firstIndex { $0 === tabs.selectedTab }
        // Keep the picture of the page being left: the next switch back shows
        // it at once (the official's `kept: [Int: PagePicture]`).
        if let from, let view = pageView(of: tabs),
           let snap = view.snapshotView(afterScreenUpdates: false) {
            pictures[from] = Picture(view: snap, at: now)
        }

        var content: UIView?
        var source = "none"
        if index != from, let kept = pictures.removeValue(forKey: index),
           now - kept.at <= Self.pictureFreshSeconds {
            content = kept.view
            source = "kept"
        } else if let view = pageView(of: tabs),
                  let snap = view.snapshotView(afterScreenUpdates: false) {
            content = snap
            source = "outgoing"
        }

        let cover = UIView(frame: tabs.view.bounds)
        cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        cover.isUserInteractionEnabled = false
        cover.backgroundColor = pageView(of: tabs)?.backgroundColor ?? .systemBackground
        if let content {
            content.frame = cover.bounds
            content.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            cover.addSubview(content)
        }
        // Never hide the tab bar: insert below its top-level container, or
        // clip to the area above it when the bar is not a direct subview.
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
        coverSource = source
        coverBegan = now
        ClientDiagnosticsLog.shared.record(
            kind: "shell.tabs.cover",
            detail: ["phase": "begin",
                     "source": source,
                     "picture": content == nil ? "0" : "1",
                     "barBelow": barBelow ? "1" : "0"],
            dedupe: false)
    }

    /// Reveal on the second display tick after the switch: the ticks stop
    /// while frames are stalled, so this is "the destination's first frame
    /// has landed" (the official's `isPageInPlace`), not a fixed timer.
    private func scheduleReveal() {
        guard cover != nil else { return }
        revealTicks = 0
        let ticker = DisplayTicker()
        ticker.onTick = { [weak self] in self?.revealTick() }
        let link = CADisplayLink(target: ticker, selector: #selector(DisplayTicker.tick))
        link.add(to: .main, forMode: .common)
        revealLink = link
        revealTicker = ticker
        let fallback = DispatchWorkItem { [weak self] in self?.reveal(why: "timeout") }
        revealFallback = fallback
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: fallback)
    }

    private func revealTick() {
        revealTicks += 1
        if revealTicks >= 2 { reveal(why: "frame") }
    }

    private func reveal(why: String) {
        revealLink?.invalidate()
        revealLink = nil
        revealTicker = nil
        revealFallback?.cancel()
        revealFallback = nil
        guard let cover else { return }
        cover.removeFromSuperview()
        self.cover = nil
        ClientDiagnosticsLog.shared.record(
            kind: "shell.tabs.cover",
            detail: ["phase": "reveal",
                     "source": coverSource,
                     "why": why,
                     "ticks": String(revealTicks),
                     "ms": String(Int((CACurrentMediaTime() - coverBegan) * 1000))],
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

/// CADisplayLink target helper (the link needs an ObjC selector target).
private final class DisplayTicker: NSObject {
    var onTick: (() -> Void)?
    @objc func tick() { onTick?() }
}

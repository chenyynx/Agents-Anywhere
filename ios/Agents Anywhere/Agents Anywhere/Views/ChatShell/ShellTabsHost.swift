import SwiftUI
import UIKit

/// Hosts the shell's persistent pages and its bottom bar in one real view
/// controller.
///
/// SwiftUI's `.safeAreaInset` does **not** reach a `NavigationStack`'s
/// content: the stack runs in its own hosting controller and takes its safe
/// area from UIKit. b1697 proved it on device — an 83 pt SwiftUI inset (bar +
/// home indicator) still left the composer sitting under the bar. The system
/// tab bar used to deliver that inset through `UITabBarController`; this
/// container does the same thing: the hosted pages get
/// `additionalSafeAreaInsets.bottom = 49`, so they see the bar's height plus
/// the home indicator exactly like before the persistent-page rewrite.
struct ShellTabsHost<Content: View>: UIViewControllerRepresentable {
    let content: Content
    let selection: ShellTab
    let onSelect: (ShellTab) -> Void

    func makeUIViewController(context: Context) -> ShellTabsHostController<Content> {
        let controller = ShellTabsHostController(content: content)
        controller.onSelect = onSelect
        controller.setSelection(selection)
        return controller
    }

    func updateUIViewController(_ controller: ShellTabsHostController<Content>,
                                context: Context) {
        controller.onSelect = onSelect
        controller.setContent(content)
        controller.setSelection(selection)
    }
}

final class ShellTabsHostController<Content: View>: UIViewController, UITabBarDelegate {
    private let hosting: UIHostingController<Content>
    private let bar = UITabBar(frame: .zero)
    private var barHeight: NSLayoutConstraint?
    var onSelect: ((ShellTab) -> Void)?

    init(content: Content) {
        hosting = UIHostingController(rootView: content)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        addChild(hosting)
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        hosting.view.backgroundColor = .clear
        view.addSubview(hosting.view)
        NSLayoutConstraint.activate([
            hosting.view.topAnchor.constraint(equalTo: view.topAnchor),
            hosting.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        hosting.didMove(toParent: self)
        // The pages clear the bar exactly like they cleared the system tab
        // bar: its height on top of the window's own bottom inset.
        hosting.additionalSafeAreaInsets = UIEdgeInsets(
            top: 0, left: 0,
            bottom: ShellTabBarMetrics.contentHeight, right: 0)

        bar.delegate = self
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.items = ShellTab.allCases.map { tab in
            UITabBarItem(
                title: tab.barTitle,
                image: UIImage(named: tab.barImage)?
                    .withRenderingMode(.alwaysTemplate),
                tag: ShellTab.allCases.firstIndex(of: tab) ?? 0)
        }
        view.addSubview(bar)
        // The bar spans the screen bottom like the system one: its items
        // occupy the top 49 pt and its own safe area covers the home
        // indicator. Pinning it above the home indicator instead clipped the
        // items — a bare `UITabBar` lays its content out against its own
        // safe area (b1698 device screenshot: icons and labels cut in half).
        let height = bar.heightAnchor.constraint(
            equalToConstant: ShellTabBarMetrics.contentHeight)
        barHeight = height
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            height,
        ])
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // The window's inset (not the view's, which the keyboard can change).
        let bottomInset = view.window?.safeAreaInsets.bottom ?? 0
        barHeight?.constant = ShellTabBarMetrics.contentHeight + bottomInset
    }

    func setContent(_ content: Content) {
        hosting.rootView = content
    }

    func setSelection(_ tab: ShellTab) {
        let index = ShellTab.allCases.firstIndex(of: tab) ?? 0
        guard let items = bar.items, index < items.count else { return }
        if bar.selectedItem !== items[index] {
            bar.selectedItem = items[index]
        }
    }

    func tabBar(_ tabBar: UITabBar, didSelect item: UITabBarItem) {
        let tabs = ShellTab.allCases
        guard item.tag >= 0, item.tag < tabs.count else { return }
        onSelect?(tabs[item.tag])
    }
}

extension ShellTab {
    /// The same artwork and copy the `TabView` items used (the `Tab` labels
    /// drew the asset at 20 pt; the bar sizes item images itself).
    var barImage: String {
        switch self {
        case .chat: return "anthropicon.chat"
        case .devices: return "anthropicon.laptop.tab"
        case .wiki: return "anthropicon.library"
        case .artifacts: return "anthropicon.artifacts"
        }
    }

    var barTitle: String {
        switch self {
        case .chat: return String(localized: "Chats")
        case .devices: return String(localized: "Devices")
        case .wiki: return String(localized: "Wiki")
        case .artifacts: return String(localized: "Artifacts")
        }
    }
}

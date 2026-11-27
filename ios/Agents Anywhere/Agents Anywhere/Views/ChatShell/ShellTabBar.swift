import SwiftUI
import UIKit

/// The bottom bar of the tab shell.
///
/// It is a plain `UITabBar`, not a `UITabBarController`: the controller owns
/// page hosting, and its page swapping is exactly what made every switch
/// re-lay-out and re-rasterise the destination (b1695: the main thread idles
/// in the runloop for the whole 200–575 ms freeze while frames stop arriving).
/// Keeping the system bar keeps the Liquid Glass look the shell had with
/// `TabView`.
struct ShellTabBar: UIViewRepresentable {
    let selection: ShellTab
    let onSelect: (ShellTab) -> Void

    func makeUIView(context: Context) -> UITabBar {
        let bar = UITabBar(frame: .zero)
        bar.delegate = context.coordinator
        bar.items = ShellTab.allCases.map { tab in
            UITabBarItem(
                title: tab.barTitle,
                image: UIImage(named: tab.barImage)?
                    .withRenderingMode(.alwaysTemplate),
                tag: Self.index(of: tab))
        }
        bar.selectedItem = bar.items?[Self.index(of: selection)]
        return bar
    }

    func updateUIView(_ bar: UITabBar, context: Context) {
        context.coordinator.onSelect = onSelect
        let index = Self.index(of: selection)
        guard let items = bar.items, index < items.count else { return }
        if bar.selectedItem !== items[index] {
            bar.selectedItem = items[index]
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onSelect: onSelect)
    }

    private static func index(of tab: ShellTab) -> Int {
        ShellTab.allCases.firstIndex(of: tab) ?? 0
    }

    final class Coordinator: NSObject, UITabBarDelegate {
        var onSelect: (ShellTab) -> Void

        init(onSelect: @escaping (ShellTab) -> Void) {
            self.onSelect = onSelect
        }

        func tabBar(_ tabBar: UITabBar, didSelect item: UITabBarItem) {
            let tabs = ShellTab.allCases
            guard item.tag >= 0, item.tag < tabs.count else { return }
            onSelect(tabs[item.tag])
        }
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

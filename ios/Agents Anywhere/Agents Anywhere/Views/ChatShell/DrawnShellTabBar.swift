import SwiftUI

/// The shell's own bottom tab bar.
///
/// The official app hides the system tab bar and draws its own
/// (`ClaudeMinimalTabBar` / `DrawnTabBar`, CANONICAL/29). The system bar's
/// Liquid Glass selection transition blocked the main thread for 200–400 ms on
/// every switch in the b1661 device log — even between two placeholder tabs —
/// and SwiftUI cannot make that transition cheaper. This bar keeps the
/// system's glass material and owns only four fixed items and the selected
/// pill's movement: milliseconds of layout, not a view-controller transition.
struct DrawnShellTabBar: View {
    let selection: ShellTab
    let onSelect: (ShellTab) -> Void

    @AppStorage(AppAccent.storageKey) private var accentValue = AppAccent.storageDefault.rawValue
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var pillNamespace

    private var accent: Color {
        AppTheme.accentTextColor(AppAccent.resolve(accentValue), colorScheme)
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(ShellTab.allCases, id: \.self) { tab in
                item(tab)
            }
        }
        .padding(.horizontal, 6)
        .frame(height: ShellTabBarMetrics.drawnBarHeight)
        .glassEffect(.regular, in: .capsule)
        // Only the pill moves; the animation is local to this bar so it never
        // rides the page switch.
        .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.86),
                   value: selection)
    }

    private func item(_ tab: ShellTab) -> some View {
        let selected = tab == selection
        return Button {
            guard !selected else { return }
            onSelect(tab)
        } label: {
            VStack(spacing: 3) {
                Image(tab.drawnImageName)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 20, height: 20)
                Text(tab.drawnTitleText)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .frame(height: ShellTabBarMetrics.drawnBarHeight)
            .contentShape(Rectangle())
            .background {
                if selected {
                    Capsule()
                        .fill(accent.opacity(colorScheme == .dark ? 0.20 : 0.12))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 8)
                        .matchedGeometryEffect(id: "drawnTabPill", in: pillNamespace)
                }
            }
            .foregroundStyle(selected ? accent : Color.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(tab.drawnTitleText))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

extension ShellTab {
    /// The official bar's labels (`ShellTabLabel` uses the same words).
    var drawnTitleText: String {
        switch self {
        case .chat: return String(localized: "Chats")
        case .devices: return String(localized: "Devices")
        case .wiki: return String(localized: "Wiki")
        case .artifacts: return String(localized: "Artifacts")
        }
    }

    var drawnImageName: String {
        switch self {
        case .chat: return "anthropicon.chat"
        case .devices: return "anthropicon.laptop.tab"
        case .wiki: return "anthropicon.library"
        case .artifacts: return "anthropicon.artifacts"
        }
    }
}

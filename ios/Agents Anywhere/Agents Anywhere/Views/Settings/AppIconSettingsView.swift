import SwiftUI
import UIKit

/// 应用图标：moonveil 九色 logo。陶土橙是默认（asset catalog 主图标），
/// 其余颜色是 alternate icon —— 工程已开
/// `ASSETCATALOG_COMPILER_INCLUDE_ALL_APPICON_ASSETS`，目录里的 appiconset
/// 会自动登记成备选图标，选中后立即换到主屏幕。
struct AppIconSettingsView: View {
    @AppStorage(AppIconChoice.storageKey) private var iconID = AppIconChoice.terracotta.rawValue
    @Environment(\.colorScheme) private var colorScheme
    @State private var error: String?

    var body: some View {
        SettingsScreen(title: String(localized: "应用图标")) {
            SettingsSection(footer: String(localized: "图标会立即更换到主屏幕，陶土橙是默认图标。")) {
                ForEach(Array(AppIconChoice.allCases.enumerated()), id: \.element) { index, choice in
                    if index > 0 {
                        SettingsRowDivider()
                    }
                    row(choice)
                }
            }
            if let error {
                SettingsSection {
                    SettingsRowContainer {
                        Text(error)
                            .font(SettingsStyle.text(15))
                            .foregroundStyle(SettingsStyle.secondary(colorScheme))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    private func row(_ choice: AppIconChoice) -> some View {
        Button {
            select(choice)
        } label: {
            HStack(spacing: 14) {
                Image(choice.previewAsset)
                    .resizable()
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(SettingsStyle.hairline(colorScheme), lineWidth: 0.5)
                    }
                Text(choice.title)
                    .font(SettingsStyle.text(16))
                    .foregroundStyle(SettingsStyle.ink(colorScheme))
                Spacer(minLength: 8)
                if iconID == choice.rawValue {
                    Image(systemName: "checkmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(SettingsStyle.controlTint(colorScheme))
                }
            }
            .padding(.horizontal, SettingsStyle.rowPadding)
            .padding(.vertical, 10)
            .frame(minHeight: 60)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(iconID == choice.rawValue ? .isSelected : [])
    }

    private func select(_ choice: AppIconChoice) {
        guard choice.rawValue != iconID else { return }
        guard UIApplication.shared.supportsAlternateIcons else { return }
        let previous = iconID
        iconID = choice.rawValue
        error = nil
        UIApplication.shared.setAlternateIconName(choice.alternateName) { failure in
            guard let failure else { return }
            DispatchQueue.main.async {
                iconID = previous
                error = String(localized: "无法更换应用图标：\(failure.localizedDescription)")
            }
        }
    }
}

/// The nine moonveil colourways, in the order the logo drafts list them.
enum AppIconChoice: String, CaseIterable {
    static let storageKey = "agentsAnywhere.appIcon"

    case terracotta, red, ink, navy, teal, gold, violet, green, rose

    /// nil selects the asset-catalog primary icon.
    var alternateName: String? {
        self == .terracotta ? nil : "AppIcon-\(suffix)"
    }

    var previewAsset: String { "aa-AppIcon-\(suffix)" }

    private var suffix: String { rawValue.capitalized }

    var title: LocalizedStringResource {
        switch self {
        case .terracotta: "陶土橙"
        case .red: "月红"
        case .ink: "墨色"
        case .navy: "夜蓝"
        case .teal: "青色"
        case .gold: "金色"
        case .violet: "紫色"
        case .green: "绿色"
        case .rose: "粉色"
        }
    }
}

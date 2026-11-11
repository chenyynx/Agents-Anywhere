import SwiftUI

struct AccentSettingsView: View {
    @AppStorage(AppAccent.storageKey) private var accentValue = AppAccent.storageDefault.rawValue
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        SettingsScreen(title: String(localized: "Accent color")) {
            SettingsSection {
                ForEach(Array(AppAccent.allCases.enumerated()), id: \.element.id) { index, accent in
                    if index > 0 {
                        SettingsRowDivider()
                    }
                    SettingsSelectRow(
                        leadingColor: AppTheme.accentBackground(accent, colorScheme),
                        title: String(localized: accent.title),
                        isSelected: accentValue == accent.rawValue
                    ) {
                        accentValue = accent.rawValue
                    }
                }
            }
        }
    }
}

import SwiftUI

struct AccentSettingsView: View {
    @AppStorage(AppAccent.storageKey) private var accentValue = AppAccent.default.rawValue
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        List {
            Section {
                ForEach(AppAccent.allCases) { accent in
                    Button { accentValue = accent.rawValue } label: {
                        HStack(spacing: 14) {
                            Circle().fill(AppTheme.accentBackground(accent, colorScheme)).frame(width: 24, height: 24)
                            Text(accent.title).foregroundStyle(.primary)
                            Spacer()
                            if accentValue == accent.rawValue { AppSymbol("checkmark") }
                        }.padding(.vertical, 6)
                    }
                    .accessibilityAddTraits(accentValue == accent.rawValue ? .isSelected : [])
                }
            }
        }.settingsPage(String(localized: "Accent color"))
    }
}

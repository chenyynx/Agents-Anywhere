import SwiftUI

/// 外观: the official three preview tiles (light / dark / follow system),
/// each a miniature window with the terracotta dot; the selected tile takes
/// the blue ring and its label turns blue.
struct AppearanceSettingsView: View {
    @AppStorage(AppAppearance.storageKey) private var appearanceValue = AppAppearance.system.rawValue
    @Environment(\.colorScheme) private var colorScheme

    /// Official order: light, dark, system.
    private var options: [AppAppearance] { [.light, .dark, .system] }

    var body: some View {
        SettingsScreen(title: String(localized: "Appearance")) {
            SettingsSection {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(options) { appearance in
                        let isSelected = appearanceValue == appearance.rawValue
                        Button {
                            appearanceValue = appearance.rawValue
                        } label: {
                            VStack(spacing: 8) {
                                AppearancePreviewTile(appearance: appearance, isSelected: isSelected)
                                Text(appearance.title)
                                    .font(SettingsStyle.text(13))
                                    .foregroundStyle(isSelected
                                                     ? SettingsStyle.controlTint(colorScheme)
                                                     : SettingsStyle.secondary(colorScheme))
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                    }
                }
                .padding(14)
            }
        }
    }
}

private struct AppearancePreviewTile: View {
    let appearance: AppAppearance
    let isSelected: Bool
    @Environment(\.colorScheme) private var colorScheme

    private var darkFill: Color { Color(red: 22.0 / 255.0, green: 22.0 / 255.0, blue: 21.0 / 255.0) }

    var body: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.white)
            .overlay {
                if appearance == .dark {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(darkFill)
                } else if appearance == .system {
                    DiagonalHalf().fill(darkFill)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
            .overlay {
                VStack(alignment: .leading, spacing: 6) {
                    Capsule().fill(lineColor).frame(width: 34, height: 5)
                    Capsule().fill(lineColor).frame(width: 22, height: 5)
                    Spacer(minLength: 0)
                    HStack {
                        Spacer(minLength: 0)
                        Circle().fill(AppTheme.claudeTerracotta).frame(width: 12, height: 12)
                    }
                }
                .padding(10)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isSelected ? SettingsStyle.controlTint(colorScheme) : Color.black.opacity(0.08),
                                  lineWidth: isSelected ? 2 : 0.5)
            }
            .frame(height: 108)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// Lines read on the tile's own preview, not the app's current scheme.
    private var lineColor: Color {
        appearance == .light || appearance == .system
            ? Color.black.opacity(0.14)
            : Color.white.opacity(0.20)
    }
}

/// The lower-right half of the tile, used by the "follow system" preview.
private struct DiagonalHalf: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

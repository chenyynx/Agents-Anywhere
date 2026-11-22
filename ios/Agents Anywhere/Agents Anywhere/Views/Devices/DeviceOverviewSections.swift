import SwiftUI

/// Section chrome for the card device page: a 15 pt grey header with its
/// actions on the trailing edge, then the section's cards. Geometry and
/// colours come from the official Code tab capture (see `DevicePageStyle`).
struct DeviceSection<Actions: View, Content: View>: View {
    let title: String
    @ViewBuilder var actions: () -> Actions
    @ViewBuilder var content: () -> Content
    @Environment(\.colorScheme) private var colorScheme

    init(_ title: String, @ViewBuilder actions: @escaping () -> Actions = { EmptyView() },
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.actions = actions
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(title)
                    .font(SettingsStyle.text(15))
                    .foregroundStyle(DevicePageStyle.secondary(colorScheme))
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                actions()
            }
            .frame(minHeight: 30)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A grouped white surface for the Agents section. The browsing lists use one
/// card per row (`DeviceDirectoryCard` / `DeviceSessionCard`); this container
/// keeps the dense settings-style row stack for the configuration sheet.
struct DeviceCard<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .deviceCardChrome()
    }
}

/// Hairline aligned with the title column, the same rule the settings rows use.
struct DeviceRowDivider: View {
    var leading: CGFloat = SettingsStyle.dividerLeading

    var body: some View {
        SettingsRowDivider(leading: leading)
    }
}

/// Muted text used for loading and empty lists.
struct DeviceEmptyText: View {
    let text: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Text(text)
            .font(SettingsStyle.text(15))
            .foregroundStyle(SettingsStyle.secondary(colorScheme))
            .padding(.horizontal, SettingsStyle.rowPadding)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// An empty list as one card, matching the browsing cards around it.
struct DeviceEmptyCard: View {
    let text: String

    var body: some View {
        DeviceCard { DeviceEmptyText(text: text) }
    }
}

/// Round section-header action ("create project", "rediscover agents").
struct DeviceHeaderIconButton: View {
    let title: String
    let symbol: String
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            AppSymbol(symbol, size: 17)
                .foregroundStyle(SettingsStyle.icon(colorScheme))
                .frame(width: 32, height: 32)
                .contentShape(.rect)
        }
        .buttonStyle(.plain).accessibilityLabel(title)
    }
}

/// Single-select tags (Active / Archived / All). Selected tags carry the app
/// tint instead of a filled grey capsule.
struct DeviceFilterTags<Value: Hashable & Identifiable>: View {
    let values: [Value]
    @Binding var selection: Value
    let title: (Value) -> String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 6) {
            ForEach(values) { value in
                let selected = value == selection
                Button { selection = value } label: {
                    Text(title(value))
                        .font(SettingsStyle.text(13, weight: selected ? .semibold : .regular))
                        // A filter name never wraps or squeezes: at 13 pt the
                        // narrow chip was breaking 「已归档」 onto two lines
                        // (pp 2026-11-13). The row's ViewThatFits fallback moves
                        // the scope menu instead of shrinking the tags.
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .foregroundStyle(selected
                            ? SettingsStyle.controlTint(colorScheme)
                            : SettingsStyle.secondary(colorScheme))
                        .padding(.horizontal, 12)
                        .frame(minHeight: 32)
                        .background {
                            if selected {
                                Capsule().fill(SettingsStyle.controlTint(colorScheme).opacity(0.12))
                            }
                        }
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }
}

enum DeviceStatusTone {
    case ok, progress, warning, error, neutral

    var color: Color {
        switch self {
        case .ok: .green
        case .progress: .blue
        case .warning: .orange
        case .error: .red
        case .neutral: .secondary.opacity(0.4)
        }
    }
}

struct DeviceStatusDot: View {
    let tone: DeviceStatusTone
    var isLoading = false

    var body: some View {
        ZStack {
            if isLoading { ProgressView().controlSize(.mini) }
            else { Circle().fill(tone.color).frame(width: 8, height: 8) }
        }
        .frame(width: 14, height: 14)
        .accessibilityHidden(true)
    }
}

/// The row body every device list shares: optional leading glyph, title and
/// subtitle, then trailing controls.
struct DeviceRowLabel: View {
    var title: String
    var subtitle: String?
    var subtitleIsError = false
    @Environment(\.colorScheme) private var colorScheme

    init(title: String, subtitle: String? = nil, subtitleIsError: Bool = false) {
        self.title = title
        self.subtitle = subtitle
        self.subtitleIsError = subtitleIsError
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(SettingsStyle.text(16))
                .foregroundStyle(SettingsStyle.ink(colorScheme))
                .lineLimit(1)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(SettingsStyle.text(15))
                    .foregroundStyle(subtitleIsError
                        ? AnyShapeStyle(.red)
                        : AnyShapeStyle(SettingsStyle.secondary(colorScheme)))
                    .lineLimit(1)
            }
        }
    }
}

/// One settings-style row shell used by the Agents card.
struct DeviceCardRow<Content: View>: View {
    var minHeight: CGFloat = SettingsStyle.rowMinHeight
    var verticalPadding: CGFloat = 8
    @ViewBuilder var content: () -> Content
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: SettingsStyle.iconGap) {
            content()
        }
        .padding(.horizontal, SettingsStyle.rowPadding)
        .padding(.vertical, verticalPadding)
        .frame(minHeight: minHeight)
        .foregroundStyle(SettingsStyle.ink(colorScheme))
    }
}

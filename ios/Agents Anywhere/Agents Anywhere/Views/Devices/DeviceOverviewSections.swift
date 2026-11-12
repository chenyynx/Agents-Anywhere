import SwiftUI

/// Device page sections now speak the same language as Settings: a 14 pt grey
/// header with its actions on the right, then one white card (28 pt radius)
/// whose rows use the settings row geometry (16 pt inset, 50 pt minimum,
/// hairlines from the title column). The previous page followed Web/Android
/// with uppercase labels and rows floating directly on the background.
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
                    .font(SettingsStyle.text(14))
                    .foregroundStyle(SettingsStyle.header(colorScheme))
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                actions()
            }
            .padding(.horizontal, 2)
            .frame(minHeight: 30)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The settings card: white surface, 28 pt continuous radius, rows stacked
/// without their own backgrounds.
struct DeviceCard<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SettingsStyle.card(colorScheme),
                    in: RoundedRectangle(cornerRadius: SettingsStyle.cardRadius,
                                         style: .continuous))
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
    var body: some View {
        Text(text)
            .font(SettingsStyle.text(15))
            .foregroundStyle(SettingsStyle.secondary(colorScheme))
            .padding(.horizontal, SettingsStyle.rowPadding)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @Environment(\.colorScheme) private var colorScheme
}

/// Compact text action for section headers ("Select", "Archive all").
struct DevicePillButton: View {
    let title: String
    var isLoading = false
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(SettingsStyle.text(13, weight: .medium))
                .lineLimit(1)
                .opacity(isLoading ? 0 : 1)
                .overlay { if isLoading { ProgressView().controlSize(.mini) } }
                .foregroundStyle(SettingsStyle.controlTint(colorScheme))
                .frame(minHeight: 30)
                .contentShape(.rect)
                .opacity(isEnabled ? 1 : 0.4)
        }
        .buttonStyle(.plain)
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

/// One settings-style row shell used by the device page's cards.
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

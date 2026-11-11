import SwiftUI

/// Geometry and chrome for the settings screens, measured from the official
/// app's 3x screenshots (2026-11-11): paper page (#F9F9F7), white cards inset
/// 16 pt with a 28 pt radius, 50 pt rows whose hairlines start at the title
/// column (53 pt), 17 pt labels and a 15 pt section header.
nonisolated enum SettingsStyle {
    static let inset: CGFloat = 16
    static let cardRadius: CGFloat = 28
    static let rowMinHeight: CGFloat = 50
    static let rowPadding: CGFloat = 16
    static let iconFrame: CGFloat = 24
    static let iconGap: CGFloat = 13
    /// Hairlines start where the row text starts (16 + 24 + 13).
    static let dividerLeading: CGFloat = 53
    static let dividerTrailing: CGFloat = 14
    static let sectionGap: CGFloat = 24
    static let headerGap: CGFloat = 8

    /// The official UI face (the same one the Code page uses). CJK falls back
    /// to the system face at the same point size, which is why the sampled
    /// sizes below read smaller than the SF-numbers they replace.
    static let fontName = "AnthropicSansMobileVariable-TextRegular"

    static func text(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .custom(fontName, size: size, relativeTo: .body).weight(weight)
    }

    static func background(_ scheme: ColorScheme) -> Color {
        AppTheme.composerSheetBackground(scheme)
    }

    static func card(_ scheme: ColorScheme) -> Color {
        AppTheme.composerTileBackground(scheme)
    }

    static func ink(_ scheme: ColorScheme) -> Color {
        AppTheme.composerControlGlyph(scheme)
    }

    static func secondary(_ scheme: ColorScheme) -> Color {
        AppTheme.secondaryText(scheme)
    }

    /// The small grey section header above each card.
    static func header(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.44) : Color.black.opacity(0.38)
    }

    static func icon(_ scheme: ColorScheme) -> Color {
        AppTheme.composerRowIcon(scheme)
    }

    /// Official hairline in the settings cards: #E6E6E6 light.
    static func hairline(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.white.opacity(0.12)
            : Color(red: 230.0 / 255.0, green: 230.0 / 255.0, blue: 230.0 / 255.0)
    }

    static func controlTint(_ scheme: ColorScheme) -> Color {
        AppTheme.pickerCheckmark(scheme)
    }
}

/// The scrolling page behind every settings screen: paper background, inline
/// title, and (on the root) the circular close key.
struct SettingsScreen<Content: View>: View {
    let title: String
    var close: (() -> Void)?
    var closeDisabled = false
    private let content: Content
    @Environment(\.colorScheme) private var colorScheme

    init(title: String, close: (() -> Void)? = nil, closeDisabled: Bool = false,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.close = close
        self.closeDisabled = closeDisabled
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SettingsStyle.sectionGap) {
                content
            }
            .padding(.horizontal, SettingsStyle.inset)
            .padding(.top, 10)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
        .background(SettingsStyle.background(colorScheme).ignoresSafeArea())
        .toolbarBackground(SettingsStyle.background(colorScheme), for: .navigationBar)
        .toolbarBackgroundVisibility(.visible, for: .navigationBar)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let close {
                SheetCloseToolbar(disabled: closeDisabled, action: close)
            }
        }
    }
}

/// A titled white card. Rows live inside with `SettingsRowDivider` between
/// them; the optional footer sits 8 pt under the card like the official
/// settings explanations.
struct SettingsSection<Content: View>: View {
    var header: String?
    var footer: String?
    private let content: Content
    @Environment(\.colorScheme) private var colorScheme

    init(_ header: String? = nil, footer: String? = nil,
         @ViewBuilder content: () -> Content) {
        self.header = header
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsStyle.headerGap) {
            if let header {
                Text(header)
                    .font(SettingsStyle.text(14))
                    .foregroundStyle(SettingsStyle.header(colorScheme))
                    .padding(.leading, 2)
            }
            VStack(spacing: 0) {
                content
            }
            .background(SettingsStyle.card(colorScheme),
                        in: RoundedRectangle(cornerRadius: SettingsStyle.cardRadius, style: .continuous))
            if let footer {
                Text(footer)
                    .font(SettingsStyle.text(12))
                    .foregroundStyle(SettingsStyle.secondary(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
                    .padding(.top, 2)
            }
        }
    }
}

/// The visual body shared by tap and navigation rows.
struct SettingsRowLabelContent: View {
    let icon: String
    let title: String
    var subtitle: String?
    var value: String?
    var showsChevron = true
    var showsStatusDot = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: SettingsStyle.iconGap) {
            AppSymbol(icon, size: 17)
                .frame(width: SettingsStyle.iconFrame)
                .foregroundStyle(SettingsStyle.icon(colorScheme))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(SettingsStyle.text(16))
                    .foregroundStyle(SettingsStyle.ink(colorScheme))
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(SettingsStyle.text(15))
                        .foregroundStyle(SettingsStyle.secondary(colorScheme))
                }
            }
            Spacer(minLength: 8)
            if let value, !value.isEmpty {
                Text(value)
                    .font(SettingsStyle.text(16))
                    .foregroundStyle(SettingsStyle.secondary(colorScheme))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if showsStatusDot {
                DiagnosticsStatusDot()
            }
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(SettingsStyle.secondary(colorScheme).opacity(0.8))
            }
        }
        .padding(.horizontal, SettingsStyle.rowPadding)
        .padding(.vertical, 12)
        .frame(minHeight: SettingsStyle.rowMinHeight)
        .contentShape(Rectangle())
    }
}

/// One tappable row: icon, 17 pt title (+ optional 15 pt subtitle), optional
/// trailing value, optional status dot, chevron.
struct SettingsDisclosureRow: View {
    let icon: String
    let title: String
    var subtitle: String?
    var value: String?
    var showsChevron = true
    var isEnabled = true
    var showsStatusDot = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            SettingsRowLabelContent(icon: icon, title: title, subtitle: subtitle,
                                    value: value, showsChevron: showsChevron,
                                    showsStatusDot: showsStatusDot)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
    }
}

/// A push row with the same body; the label keeps the system link behaviour.
struct SettingsNavigationRow<Destination: View>: View {
    let icon: String
    let title: String
    var subtitle: String?
    var value: String?
    var showsStatusDot = false
    let destination: Destination

    var body: some View {
        NavigationLink {
            destination
        } label: {
            SettingsRowLabelContent(icon: icon, title: title, subtitle: subtitle,
                                    value: value, showsStatusDot: showsStatusDot)
        }
        .buttonStyle(.plain)
    }
}

/// A switch row with the same icon/title geometry as the disclosure rows.
struct SettingsToggleRow: View {
    let icon: String
    let title: String
    var subtitle: String?
    @Binding var isOn: Bool
    var isEnabled = true
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: SettingsStyle.iconGap) {
                AppSymbol(icon, size: 17)
                    .frame(width: SettingsStyle.iconFrame)
                    .foregroundStyle(SettingsStyle.icon(colorScheme))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(SettingsStyle.text(16))
                        .foregroundStyle(SettingsStyle.ink(colorScheme))
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(SettingsStyle.text(15))
                            .foregroundStyle(SettingsStyle.secondary(colorScheme))
                    }
                }
            }
        }
        .toggleStyle(.switch)
        .tint(SettingsStyle.controlTint(colorScheme))
        .padding(.horizontal, SettingsStyle.rowPadding)
        .padding(.vertical, 8)
        .frame(minHeight: SettingsStyle.rowMinHeight)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
    }
}

/// An option row for pickers (appearance, accent, cache limits…): optional
/// leading colour dot or icon, title + subtitle, checkmark when selected.
struct SettingsSelectRow: View {
    var icon: String?
    var leadingColor: Color?
    let title: String
    var subtitle: String?
    var isSelected = false
    var isEnabled = true
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            HStack(spacing: SettingsStyle.iconGap) {
                if let leadingColor {
                    Circle()
                        .fill(leadingColor)
                        .frame(width: 22, height: 22)
                        .frame(width: SettingsStyle.iconFrame)
                } else if let icon {
                    AppSymbol(icon, size: 17)
                        .frame(width: SettingsStyle.iconFrame)
                        .foregroundStyle(SettingsStyle.icon(colorScheme))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(SettingsStyle.text(16))
                        .foregroundStyle(SettingsStyle.ink(colorScheme))
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(SettingsStyle.text(15))
                            .foregroundStyle(SettingsStyle.secondary(colorScheme))
                    }
                }
                Spacer(minLength: 8)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(SettingsStyle.controlTint(colorScheme))
                }
            }
            .padding(.horizontal, SettingsStyle.rowPadding)
            .padding(.vertical, 12)
            .frame(minHeight: SettingsStyle.rowMinHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A custom-content row (text fields, progress, previews) with the same
/// horizontal padding and minimum height.
struct SettingsRowContainer<Content: View>: View {
    var minHeight: CGFloat = SettingsStyle.rowMinHeight
    var verticalPadding: CGFloat = 12
    private let content: Content

    init(minHeight: CGFloat = SettingsStyle.rowMinHeight, verticalPadding: CGFloat = 12,
         @ViewBuilder content: () -> Content) {
        self.minHeight = minHeight
        self.verticalPadding = verticalPadding
        self.content = content()
    }

    var body: some View {
        content
            .padding(.horizontal, SettingsStyle.rowPadding)
            .padding(.vertical, verticalPadding)
            .frame(minHeight: minHeight)
    }
}

/// The hairline between rows; leading aligns with the title column.
struct SettingsRowDivider: View {
    var leading: CGFloat = SettingsStyle.dividerLeading
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Rectangle()
            .fill(SettingsStyle.hairline(colorScheme))
            .frame(height: 1)
            .padding(.leading, leading)
            .padding(.trailing, SettingsStyle.dividerTrailing)
    }
}

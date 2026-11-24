import SwiftUI

/// Leading artwork for a connector row: a remote `iconUrl`, a bundled
/// `AppSymbol` (device tools), or a letter fallback (custom connectors such as
/// “my phone”, which the official app renders as a monogram tile).
struct ConnectorLogoView: View {
    enum Source: Hashable {
        case remote(URL)
        case symbol(String)
        case letter(String)
        /// Bundled brand artwork (transparent, drawn as-is).
        case image(String)
        /// White-background system-style app icon (CoreUI Location / Calendar /
        /// Reminders): clipped to the official rounded square with the soft
        /// bottom shadow measured at #EBEBEB ≈ 8% black, radius ~4, y 2.
        case appIcon(String)
    }

    let source: Source
    var size: CGFloat = ConnectorStyle.logoSize
    var symbolTint: Color?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            switch source {
            case .remote(let url):
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFit()
                    } else {
                        monogram
                    }
                }
            case .symbol(let name):
                AppSymbol(name, size: size * 0.58)
                    .foregroundStyle(symbolTint ?? ConnectorStyle.accent(colorScheme))
            case .letter(let letter):
                monogram(letter: String(letter.prefix(1)).uppercased())
            case .image(let name):
                // The exported artwork is edge-to-edge; the official rows sit
                // ~80% ink inside the 28 pt slot.
                Image(name)
                    .resizable()
                    .scaledToFit()
                    .padding(size * 0.08)
            case .appIcon(let name):
                // The exported CoreUI artwork is edge-to-edge (ink 50% of the
                // canvas); the official render keeps the 40 pt white tile but
                // draws the glyph at ~60% (measured 12 pt ink on 40 pt tile).
                ZStack {
                    RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
                        .fill(.white)
                    Image(name)
                        .resizable()
                        .scaledToFit()
                        .padding(size * 0.2)
                }
                .clipShape(RoundedRectangle(cornerRadius: size * 0.225,
                                            style: .continuous))
                .shadow(color: .black.opacity(colorScheme == .dark ? 0.0 : 0.08),
                        radius: 4, y: 2)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var monogram: some View {
        monogram(letter: monogramLetter)
    }

    private func monogram(letter: String) -> some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(DevicePageStyle.tile(colorScheme))
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                    .strokeBorder(SettingsStyle.hairline(colorScheme), lineWidth: 1)
            }
            .overlay {
                Text(letter)
                    .font(SettingsStyle.text(size * 0.44, weight: .semibold))
                    .foregroundStyle(SettingsStyle.ink(colorScheme))
            }
    }

    private var monogramLetter: String {
        switch source {
        case .letter(let letter): return String(letter.prefix(1)).uppercased()
        case .remote(let url): return String(url.host?.prefix(1) ?? "?").uppercased()
        case .symbol, .image, .appIcon: return "?"
        }
    }
}

/// The official switch is wider and flatter than the system one: 63×28 pt
/// with a 24 pt knob (measured from the 2026-11-24 capture).
struct ConnectorSwitchStyle: ToggleStyle {
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            Capsule()
                .fill(configuration.isOn
                      ? ConnectorStyle.accent(colorScheme)
                      : ConnectorStyle.trackOff(colorScheme))
                .frame(width: 63, height: 28)
                .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                    Circle()
                        .fill(.white)
                        .frame(width: 24, height: 24)
                        .padding(.horizontal, 2)
                        .shadow(color: .black.opacity(0.12), radius: 1, y: 1)
                }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(configuration.isOn ? .isSelected : [])
    }
}

/// Circular toolbar key used by the official connector screens (back, add,
/// refresh, sort). White disc, hairline edge, soft downward shadow.
struct ConnectorCircleButton: View {
    let symbol: String
    var isEnabled = true
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                // Measured: official chevron ink 7.3×13.3 pt (23.6×12.3 pt
                // at 3x) — 17 pt rendered 10.7×18.3 was too large.
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(SettingsStyle.ink(colorScheme))
                .frame(width: ConnectorStyle.circleKey, height: ConnectorStyle.circleKey)
                // Official circular keys are iOS 26 liquid glass, not a
                // painted white disc (same treatment as SubAgentToolbarButton).
                .glassEffect(.regular.interactive(), in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
        .accessibilityLabel(Text(verbatim: symbol))
    }
}

/// Pale-blue capsule with the number of tools behind a connector row.
struct ConnectorCountCapsule: View {
    let count: Int
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Text(verbatim: "\(count)")
            .font(SettingsStyle.text(14, weight: .semibold))
            .foregroundStyle(ConnectorStyle.accent(colorScheme))
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(ConnectorStyle.countFill(colorScheme), in: Capsule())
    }
}

/// Grey “交互式” tag shown after a directory entry's name.
struct ConnectorTag: View {
    let text: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Text(text)
            .font(SettingsStyle.text(13))
            .foregroundStyle(SettingsStyle.secondary(colorScheme))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(ConnectorStyle.tagFill(colorScheme), in: Capsule())
    }
}

/// Anthropic-verified glyph after a connector name (gear-like rosette in the
/// official build). Rendered from the info symbol until the artwork is added.
struct ConnectorVerifiedBadge: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Image(systemName: "checkmark.seal")
            .font(.system(size: 13, weight: .regular))
            .foregroundStyle(SettingsStyle.secondary(colorScheme))
            .accessibilityLabel(Text("Anthropic verified"))
    }
}

/// Yellow banner: “此连接器未经 Anthropic 验证”.
struct ConnectorWarningBanner: View {
    let text: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 17, weight: .regular))
            Text(text)
                .font(SettingsStyle.text(15))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(ConnectorStyle.warningInk(colorScheme))
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .background(ConnectorStyle.warningFill(colorScheme),
                    in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

/// White capsule with a 1 px #DDDDDD edge and ink label — the official
/// suggestion-card button (row “连接”: 51×29 pt; “不用了”: full width × 41 pt,
/// measured from the 2026-11-24 capture).
struct ConnectorOutlineButton: View {
    let title: String
    var height: CGFloat = 29
    var isFullWidth = false
    var isEnabled = true
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(SettingsStyle.text(15, weight: .medium))
                .foregroundStyle(SettingsStyle.ink(colorScheme))
                .lineLimit(1)
                .padding(.horizontal, 10)
                .frame(maxWidth: isFullWidth ? .infinity : nil)
                .frame(height: height)
                .background(SettingsStyle.card(colorScheme), in: Capsule())
                .overlay {
                    Capsule().strokeBorder(ConnectorStyle.border(colorScheme), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
    }
}

/// Floating black capsule (“连接”) used on the directory detail screen.
struct ConnectorPrimaryButton: View {
    let title: String
    var isEnabled = true
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(SettingsStyle.text(16, weight: .semibold))
                .padding(.horizontal, 22)
                .frame(height: ConnectorStyle.actionHeight)
        }
        // Official “连接” is a prominent liquid-glass capsule, not a flat
        // black pill (same treatment as AppGlassButton.prominent).
        .buttonStyle(.glassProminent)
        .buttonBorderShape(.capsule)
        .tint(ConnectorStyle.actionFill(colorScheme))
        .foregroundStyle(ConnectorStyle.actionLabel(colorScheme))
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
    }
}

/// The row body shared by directory and settings lists: logo, title, optional
/// tag/verified glyph, optional two-line subtitle, optional trailing content
/// and chevron.
struct ConnectorCardRow<Trailing: View>: View {
    let logo: ConnectorLogoView.Source
    var logoSize: CGFloat = ConnectorStyle.logoSize
    let title: String
    var tag: String?
    var showsVerified = false
    var subtitle: String?
    var showsChevron = true
    var symbolTint: Color?
    var rowMinHeight: CGFloat = SettingsStyle.rowMinHeight
    @ViewBuilder var trailing: () -> Trailing
    @Environment(\.colorScheme) private var colorScheme

    init(logo: ConnectorLogoView.Source,
         logoSize: CGFloat = ConnectorStyle.logoSize,
         title: String,
         tag: String? = nil,
         showsVerified: Bool = false,
         subtitle: String? = nil,
         showsChevron: Bool = true,
         symbolTint: Color? = nil,
         rowMinHeight: CGFloat = SettingsStyle.rowMinHeight,
         @ViewBuilder trailing: @escaping () -> Trailing) {
        self.logo = logo
        self.logoSize = logoSize
        self.title = title
        self.tag = tag
        self.showsVerified = showsVerified
        self.subtitle = subtitle
        self.showsChevron = showsChevron
        self.symbolTint = symbolTint
        self.rowMinHeight = rowMinHeight
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: ConnectorStyle.logoRowGap) {
            ConnectorLogoView(source: logo, size: logoSize, symbolTint: symbolTint)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(title)
                        .font(SettingsStyle.text(15))
                        .foregroundStyle(SettingsStyle.ink(colorScheme))
                        .lineLimit(1)
                    if showsVerified { ConnectorVerifiedBadge() }
                    if let tag { ConnectorTag(text: tag) }
                }
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(SettingsStyle.text(13))
                        .foregroundStyle(SettingsStyle.secondary(colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            trailing()
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(SettingsStyle.secondary(colorScheme).opacity(0.8))
            }
        }
        .padding(.horizontal, ConnectorStyle.logoRowPadding)
        .padding(.vertical, 11)
        .frame(minHeight: rowMinHeight)
        .contentShape(Rectangle())
    }
}

extension ConnectorCardRow where Trailing == EmptyView {
    init(logo: ConnectorLogoView.Source,
         logoSize: CGFloat = ConnectorStyle.logoSize,
         title: String,
         tag: String? = nil,
         showsVerified: Bool = false,
         subtitle: String? = nil,
         showsChevron: Bool = true,
         symbolTint: Color? = nil,
         rowMinHeight: CGFloat = SettingsStyle.rowMinHeight) {
        self.init(logo: logo, logoSize: logoSize, title: title, tag: tag,
                  showsVerified: showsVerified, subtitle: subtitle,
                  showsChevron: showsChevron, symbolTint: symbolTint,
                  rowMinHeight: rowMinHeight) { EmptyView() }
    }
}

/// Hairline for connector rows, starting after the leading logo.
struct ConnectorRowDivider: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Rectangle()
            .fill(SettingsStyle.hairline(colorScheme))
            .frame(height: 1)
            .padding(.leading, ConnectorStyle.logoDividerLeading)
            .padding(.trailing, SettingsStyle.dividerTrailing)
    }
}

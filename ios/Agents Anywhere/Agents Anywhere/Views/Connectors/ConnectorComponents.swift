import SwiftUI

/// Fixed-size AppSymbol twin for the connector screens. `AppSymbol` uses
/// `@ScaledMetric`, which inflates with Dynamic Type; the official connector
/// glyphs do not scale (measured +30% otherwise).
struct ConnectorSymbol: View {
    let name: String
    var size: CGFloat = 20

    var body: some View {
        Group {
            if let asset = AppSymbolAssets.names[name] {
                Image(asset).resizable().scaledToFit()
            } else {
                Image(systemName: name).resizable().scaledToFit()
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

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
    /// Inset applied to bundled brand artwork. The official settings rows
    /// draw the logo at 0.95 of the slot (measured 22.3 pt ink in a 24 pt
    /// slot); directory rows keep the wider 0.08 inset.
    var imageInset: CGFloat = 0.08
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
                ConnectorSymbol(name: name, size: size * 0.58)
                    .foregroundStyle(symbolTint ?? ConnectorStyle.accent(colorScheme))
            case .letter(let letter):
                monogram(letter: String(letter.prefix(1)).uppercased())
            case .image(let name):
                // The exported artwork is edge-to-edge; the official rows sit
                // slightly inside the slot.
                Image(name)
                    .resizable()
                    .scaledToFit()
                    .padding(size * imageInset)
            case .appIcon(let name):
                // Official device-tool tile: the artwork IS the 24 pt tile
                // (white plate + glyph + red band at 40 units), so it is
                // clipped to the squircle edge to edge, with a 1 px #BBBBBA
                // edge and a soft shadow (measured 8 % dark at the edge,
                // ~2.5 pt falloff, 1 pt down). The earlier 40 pt white plate
                // underneath the artwork was 67 % too large.
                Image(name)
                    .resizable()
                    .scaledToFit()
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: size * ConnectorStyle.appIconRadiusRatio,
                                                style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: size * ConnectorStyle.appIconRadiusRatio,
                                         style: .continuous)
                            .strokeBorder(ConnectorStyle.appIconBorder(colorScheme),
                                          lineWidth: ConnectorStyle.appIconBorderWidth)
                    }
                    .shadow(color: .black.opacity(colorScheme == .dark ? 0.0 : 0.16),
                            radius: 3, y: 1)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var monogram: some View {
        monogram(letter: monogramLetter)
    }

    private func monogram(letter: String) -> some View {
        // Official letter tile (“my phone”): white 24 pt square, 1 px #DDDDDD
        // edge and a ~10.5 pt semibold letter (measured cap 7.7 pt).
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(SettingsStyle.card(colorScheme))
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                    .strokeBorder(ConnectorStyle.border(colorScheme),
                                  lineWidth: ConnectorStyle.appIconBorderWidth)
            }
            .overlay {
                Text(letter)
                    .font(ConnectorStyle.text(size * 0.44, weight: .semibold))
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
        // Same shape as the session page's circular toolbar key
        // (`SubAgentToolbarButton`): a plain button whose label owns one
        // system-glass circle. The host must hide the toolbar's shared
        // background for this item (`.sharedBackgroundVisibility(.hidden)`) —
        // without that the item renders two nested glass circles, which is
        // exactly what the first build shipped.
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: ConnectorStyle.circleGlyphSize(for: symbol), weight: .regular))
                .foregroundStyle(SettingsStyle.ink(colorScheme))
                .frame(width: ConnectorStyle.circleKey, height: ConnectorStyle.circleKey)
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
        // Official capsule: 21.7 pt tall with 11 pt digits (ink 8 pt) and
        // 8.65 pt side padding — the “30” pill measures 28.7 pt wide.
        Text(verbatim: "\(count)")
            .font(ConnectorStyle.text(11, weight: .semibold))
            .foregroundStyle(ConnectorStyle.accent(colorScheme))
            .padding(.horizontal, 8.65)
            .padding(.vertical, 4.3)
            .background(ConnectorStyle.countFill(colorScheme), in: Capsule())
    }
}

/// Grey “交互式” tag shown after a directory entry's name.
struct ConnectorTag: View {
    let text: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Text(text)
            .font(ConnectorStyle.text(13))
            .foregroundStyle(ConnectorDetailStyle.secondary(colorScheme))
            .padding(.horizontal, 9)
            // Official capsule measures ~28 pt tall.
            .padding(.vertical, 5.5)
            .background(ConnectorStyle.tagFill(colorScheme), in: Capsule())
    }
}

/// Anthropic-verified glyph after a connector name (gear-like rosette in the
/// official build). Rendered from the info symbol until the artwork is added.
struct ConnectorVerifiedBadge: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        // Official badge ink 10.7×9.3 pt (2026-11-24 capture); 13 pt rendered
        // 14×14 and read one step too large.
        Image(systemName: "checkmark.seal")
            .font(.system(size: 10.5, weight: .regular))
            .foregroundStyle(ConnectorDetailStyle.secondary(colorScheme))
            .accessibilityLabel(Text("Anthropic verified"))
    }
}

/// Yellow banner: “此连接器未经 Anthropic 验证”.
///
/// Official geometry (07-detail-my-phone-custom.png): 360.7 × 47.7 pt card,
/// 24 pt radius, leading 14 pt to a 20 pt triangle, 15 pt gap, 13 pt text
/// (ink 11.3) in #734500 on #F9DCA4.
struct ConnectorWarningBanner: View {
    let text: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 15) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 20, weight: .regular))
            Text(text)
                .font(ConnectorStyle.text(13))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(ConnectorStyle.warningInk(colorScheme))
        .padding(.horizontal, 14)
        .padding(.vertical, 15.7)
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
                .font(ConnectorStyle.text(15, weight: .medium))
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
                // Official capsule label: ink 24×11.7 pt = 13 pt semibold.
                .font(ConnectorStyle.text(13, weight: .semibold))
                .foregroundStyle(ConnectorStyle.actionLabel(colorScheme))
                // Official capsule measures 66.7 × 39.3 pt for “连接” (13 pt
                // label = 26 pt wide → 20.3 pt side padding), flat #252524
                // fill (sampled 37/37/37 across the interior).
                // `.glassProminent` added the system's own padding and
                // rendered 100.7 × 54.7 — 50 % too big.
                .padding(.horizontal, 20.3)
                .frame(height: ConnectorStyle.actionHeight)
                .background(ConnectorStyle.actionFill(colorScheme), in: Capsule())
        }
        .buttonStyle(.plain)
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
                        .font(ConnectorStyle.text(14))
                        .foregroundStyle(SettingsStyle.ink(colorScheme))
                        .lineLimit(1)
                    if showsVerified { ConnectorVerifiedBadge() }
                    if let tag { ConnectorTag(text: tag) }
                }
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(ConnectorStyle.text(12))
                        .foregroundStyle(ConnectorDetailStyle.secondary(colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                        // Official two-line rows measure 103 pt vs 68.7 for
                        // one line: the description keeps a 20 pt line gap.
                        .lineSpacing(20)
                }
            }
            Spacer(minLength: 8)
            trailing()
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(ConnectorStyle.chevron(colorScheme))
                    // Official chevron right edge sits 27 pt from the card
                    // edge (row padding 18 + 7 extra).
                    .padding(.trailing, 7)
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

import SwiftUI

/// Tokens for the official Connectors screens, measured from the 2026-11-24
/// official iOS captures (1179×2556 = 393×852 pt @3x) stored under
/// `REFERENCES/device/connectors-20261124/` in the reverse-engineering corpus.
///
/// Page background, card surface, ink and hairline are the same tokens as the
/// rest of Settings, so this enum only adds the connector-specific colours and
/// geometry. Values marked `dark?` are projected from the light capture — the
/// official dark screenshots are still missing.
nonisolated enum ConnectorStyle {
    // MARK: Typography

    /// Fixed-size official face for the connector screens.
    ///
    /// `SettingsStyle.text` scales with Dynamic Type (`relativeTo: .body`);
    /// the official connector screens keep fixed sizes, so a larger system
    /// font must not inflate this page (measured +15–30% otherwise).
    static func text(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .custom(SettingsStyle.fontName, fixedSize: size).weight(weight)
    }

    // MARK: Geometry

    /// Remote connector logo in directory rows and detail headers (measured
    /// coloured ink 22.7×21.3 pt inside a 28 pt slot).
    static let logoSize: CGFloat = 28
    /// Leading tile on the settings list rows (location / calendar / reminders).
    static let iconTile: CGFloat = 36
    static let iconTileRadius: CGFloat = 10
    /// The official device-tool tile measures 24×24 pt (bbox 29.7 with its
    /// shadow), drawn edge to edge from the full-bleed icon artwork — not a
    /// 40 pt white plate.
    static let deviceIconSize: CGFloat = 24
    /// Server-row logo slot: 24 pt, same centre line as the device tiles.
    static let serverLogoSize: CGFloat = 24
    /// Corner radius of the app-icon tile (0.225 × 24 = 5.4 pt).
    static let appIconRadiusRatio: CGFloat = 0.225
    /// Official tile edge reads #BBBBBA — a 1 px line at 3x (1/3 pt).
    static let appIconBorderWidth: CGFloat = 1.0 / 3.0
    /// One settings row (measured 146.7 px = 48.9 pt on the official captures).
    static let rowHeight: CGFloat = 49
    /// Hairline start for connector rows: 16 inset + 28 logo + 13 gap.
    static let dividerLeading: CGFloat = 57
    /// Floating search field in the directory.
    static let searchHeight: CGFloat = 44
    /// Circular toolbar keys (back / add / refresh / sort). The official disc
    /// measures 44.5 pt including its 1 px rim, the same 44 pt content height
    /// the session page's toolbar button uses — one glass circle per key, no
    /// extra shared toolbar background behind it.
    static let circleKey: CGFloat = 44
    /// SF Symbol point size per key, fitted to the ink measured in the
    /// 2026-11-24 captures (chevron 7.3×13.3, plus 16.7×16.7,
    /// xmark 14.7×14.7, refresh 18×17.3, sort 17.7×17.7).
    static func circleGlyphSize(for symbol: String) -> CGFloat {
        switch symbol {
        case "chevron.left", "chevron.right": return 16
        case "xmark": return 18.5
        case "arrow.clockwise", "arrow.up.arrow.down": return 20
        default: return 17
        }
    }
    /// Primary black capsule: the official “连接” measures 66.7 × 39.3 pt.
    static let actionHeight: CGFloat = 39.3

    // MARK: Colours

    /// Switch tint, checkmark, links and the “Anthropic verified” glyph.
    /// Token `accentSecondary200`: sRGB `#256ABF` / `#5598E7`. The light
    /// capture reads `#3968B9` because screenshots are Display-P3 encoded —
    /// the token sRGB value is what the app must draw.
    static func accent(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0x55 / 255.0, green: 0x98 / 255.0, blue: 0xE7 / 255.0)
            : Color(red: 0x25 / 255.0, green: 0x6A / 255.0, blue: 0xBF / 255.0)
    }

    /// Yellow warning banner on custom connectors.
    /// Token `warning900` / `warning000`: sRGB `#F9DCA4`/`#734500`,
    /// dark `#412400`/`#FAB219` (P3 screenshot reads `#F4DDAB`/`#6C4714`).
    static func warningFill(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0x41 / 255.0, green: 0x24 / 255.0, blue: 0x00 / 255.0)
            : Color(red: 0xF9 / 255.0, green: 0xDC / 255.0, blue: 0xA4 / 255.0)
    }

    static func warningInk(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0xFA / 255.0, green: 0xB2 / 255.0, blue: 0x19 / 255.0)
            : Color(red: 0x73 / 255.0, green: 0x45 / 255.0, blue: 0x00 / 255.0)
    }

    /// Destructive row (“断开连接”). Token `danger000`: sRGB `#8E2626` /
    /// `#F4ABAB` (P3 capture `#822E2A`).
    static func dangerInk(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0xF4 / 255.0, green: 0xAB / 255.0, blue: 0xAB / 255.0)
            : Color(red: 0x8E / 255.0, green: 0x26 / 255.0, blue: 0x26 / 255.0)
    }

    /// Connected state. Token `success000`: sRGB `#006300` / `#91D68B`
    /// (P3 capture `#296117`).
    static func successInk(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0x91 / 255.0, green: 0xD6 / 255.0, blue: 0x8B / 255.0)
            : Color(red: 0x00 / 255.0, green: 0x63 / 255.0, blue: 0x00 / 255.0)
    }

    /// Hairline / capsule edge. Token `border300`: base `#1C1C1B` at 15%
    /// (composites to `#DDDDDD` on white), dark base `#D2D1C7` at 15%.
    static func border(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0xD2 / 255.0, green: 0xD1 / 255.0, blue: 0xC7 / 255.0).opacity(0.15)
            : Color(red: 0x1C / 255.0, green: 0x1C / 255.0, blue: 0x1B / 255.0).opacity(0.15)
    }

    /// Floating primary action capsule on the detail screen.
    /// Light #252524 on white; dark inverts to #F9F9F8 with #151515 label.
    static func actionFill(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0xF9 / 255.0, green: 0xF9 / 255.0, blue: 0xF8 / 255.0)
            : Color(red: 0x25 / 255.0, green: 0x25 / 255.0, blue: 0x24 / 255.0)
    }

    static func actionLabel(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0x15 / 255.0, green: 0x15 / 255.0, blue: 0x15 / 255.0)
                        : .white
    }

    /// Disclosure chevrons inside directory / detail cards: official #C7C7C5,
    /// not the 58%-black secondary text colour.
    static func chevron(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.white.opacity(0.30)
            : Color(red: 0xC7 / 255.0, green: 0xC7 / 255.0, blue: 0xC5 / 255.0)
    }

    /// Disclosure chevrons on the settings list rows (device tools and
    /// servers) are a full step darker than the directory ones: #888781 in
    /// the 2026-11-24 capture. Dark value projected.
    static func rowChevron(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.white.opacity(0.45)
            : Color(red: 0x88 / 255.0, green: 0x87 / 255.0, blue: 0x81 / 255.0)
    }

    /// “连接” label and its external-link glyph on server rows: #7A7974
    /// (the section-header grey), not the accent blue. Dark projected.
    static func connectLabel(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.white.opacity(0.55)
            : Color(red: 0x7A / 255.0, green: 0x79 / 255.0, blue: 0x74 / 255.0)
    }

    /// Edge of the device-tool app-icon tile. The official tile draws a 1 px
    /// line that samples #BBBBBA; a 0.69-white stroke over the white tile
    /// lands on the same value at 3x. Dark projected.
    static func appIconBorder(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.white.opacity(0.22)
            : Color(red: 0xB0 / 255.0, green: 0xB0 / 255.0, blue: 0xAF / 255.0)
    }

    /// Trailing values on device-tool rows (“已允许 / 读取和写入”).
    /// Binary: `DeviceToolRowView` reads token `text500` (#97958D light);
    /// the screenshot samples #B6B5B4, i.e. the same light grey.
    static func tertiaryText(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0x97 / 255.0, green: 0x95 / 255.0, blue: 0x8D / 255.0)
            : Color(red: 0x97 / 255.0, green: 0x95 / 255.0, blue: 0x8D / 255.0)
    }

    /// Count capsule behind the tool count (“4”). Official token:
    /// `accentSecondary900` — light `#CDE2FB`, dark `#062B57`
    /// (`EVIDENCE/round30-composer-visuals/raw/TOKENS-6.harvest.md:1198`).
    static func countFill(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0x06 / 255.0, green: 0x2B / 255.0, blue: 0x57 / 255.0)
            : Color(red: 0xCD / 255.0, green: 0xE2 / 255.0, blue: 0xFB / 255.0)
    }

    /// Circular toolbar key fill: white on light, #333333 disc on dark.
    static func circleFill(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0x33 / 255.0, green: 0x33 / 255.0, blue: 0x33 / 255.0)
            : SettingsStyle.card(scheme)
    }

    /// “交互式” (interactive) tag on directory rows.
    static func tagFill(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.10)
                        : Color(red: 0xF3 / 255.0, green: 0xF3 / 255.0, blue: 0xF3 / 255.0)
    }

    /// Hairline start that clears the leading icon slot. Measured on the
    /// 2026-11-24 captures: the divider and the row text both start at 68 pt
    /// on screen = 16 inset + 18 row padding + 28 icon slot + 6 gap.
    static let logoDividerLeading: CGFloat = 52
    /// Hairline end: the official divider stops 20 pt short of the card edge.
    static let logoDividerTrailing: CGFloat = 20
    /// Directory / logo row: the text column is aligned at 68 pt on screen.
    static let logoRowPadding: CGFloat = 18
    static let logoRowGap: CGFloat = 6

    /// Off-state switch track (no official capture yet; matches the system
    /// grey the app uses elsewhere).
    static func trackOff(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.18)
                        : Color(red: 0xD1 / 255.0, green: 0xD1 / 255.0, blue: 0xD6 / 255.0)
    }
}

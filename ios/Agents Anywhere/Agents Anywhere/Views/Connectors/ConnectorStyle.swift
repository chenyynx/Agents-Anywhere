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
    // MARK: Geometry

    /// Remote connector logo in directory rows and detail headers (measured
    /// coloured ink 22.7×21.3 pt inside a 28 pt slot).
    static let logoSize: CGFloat = 28
    /// Leading tile on the settings list rows (location / calendar / reminders).
    static let iconTile: CGFloat = 36
    static let iconTileRadius: CGFloat = 10
    /// One settings row (measured 146.7 px = 48.9 pt on the official captures).
    static let rowHeight: CGFloat = 49
    /// Hairline start for connector rows: 16 inset + 28 logo + 13 gap.
    static let dividerLeading: CGFloat = 57
    /// Floating search field in the directory.
    static let searchHeight: CGFloat = 44
    /// Circular toolbar keys (back / add / refresh / sort). The detail capture
    /// measures a 44 pt back disc; the settings keys read 40–42 pt.
    static let circleKey: CGFloat = 42
    /// Primary black capsule (“连接”), ink measured 66.7×39 pt.
    static let actionHeight: CGFloat = 40

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
                        : Color(red: 0xF1 / 255.0, green: 0xF1 / 255.0, blue: 0xEF / 255.0)
    }

    /// Hairline start that clears a leading logo. Measured: the row text
    /// column starts at 70 pt from the screen edge = 18 inset + 28 logo +
    /// 8 gap, so the in-card hairline offset is 54.
    static let logoDividerLeading: CGFloat = 54
    /// Directory / logo row: the text column is aligned at 70 pt on screen.
    static let logoRowPadding: CGFloat = 18
    static let logoRowGap: CGFloat = 8

    /// Off-state switch track (no official capture yet; matches the system
    /// grey the app uses elsewhere).
    static func trackOff(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.18)
                        : Color(red: 0xD1 / 255.0, green: 0xD1 / 255.0, blue: 0xD6 / 255.0)
    }
}

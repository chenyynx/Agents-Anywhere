import Foundation

/// The app-wide accent color, persisted as its raw value under `storageKey`.
///
/// Two distinct roles travel in this type, and their values are deliberately
/// different:
///
/// - The *control* pair (`…BackgroundHex` + `…ForegroundHex`) fills controls —
///   the send/stop key, prominent glass buttons, the SubAgent stop controls —
///   plus the glyph laid on top of that fill.
/// - The *text* values (`…TextHex`) are for everything that must read as text
///   on the standard background: links, the composer caret, selection, and the
///   user bubble's label. Light-mode text values are darkened per accent so
///   they clear the text-contrast bar; a yellow or lime control that clears
///   the icon bar fails as text.
///
/// Hex data only — no `Color`, no SwiftUI — so `ClientCore` tests can pin the
/// persisted strings and the contrast math without a UI framework.
enum AppAccent: String, CaseIterable, Identifiable, Hashable {
    case `default`
    case blue
    case cyan
    case green
    case lime
    case yellow
    case orange
    case pink
    case magenta

    /// The `@AppStorage` key. The nine raw values together are the persisted
    /// contract: installs already carry them, so the strings never change.
    static let storageKey = "agentsAnywhere.accent"

    var id: String { rawValue }

    /// The English key; the catalog adds the translations.
    var title: LocalizedStringResource {
        switch self {
        case .default: "Default"
        case .blue: "Blue"
        case .cyan: "Cyan"
        case .green: "Green"
        case .lime: "Lime"
        case .yellow: "Yellow"
        case .orange: "Orange"
        case .pink: "Pink"
        case .magenta: "Magenta"
        }
    }

    /// Storage can hold anything: a value written by a newer build, a cleared
    /// domain, an empty string. Everything unrecognized renders the shipped
    /// black-and-white look instead of an accent-less UI.
    static func resolve(_ raw: String?) -> AppAccent {
        guard let raw, let accent = AppAccent(rawValue: raw) else { return .default }
        return accent
    }

    // MARK: - Color data

    var lightBackgroundHex: UInt32 { palette.lightBackground }
    var darkBackgroundHex: UInt32 { palette.darkBackground }
    var lightForegroundHex: UInt32 { palette.lightForeground }
    var darkForegroundHex: UInt32 { palette.darkForeground }
    var lightTextHex: UInt32 { palette.lightText }
    var darkTextHex: UInt32 { palette.darkText }

    /// One row per accent: both schemes, both roles, one line — kept as a
    /// single table so it reads against the design row by row. `.default` is
    /// black and white inverted; the shipped look every other row departs
    /// from. `AccentTests` holds every rendered pair above its contrast bar,
    /// so a value may only move if the math moves with it.
    private var palette: Palette {
        switch self {
        case .default: Palette(lightBackground: 0x000000, darkBackground: 0xFFFFFF, lightForeground: 0xFFFFFF, darkForeground: 0x000000, lightText: 0x000000, darkText: 0xFFFFFF)
        case .blue: Palette(lightBackground: 0x007AFF, darkBackground: 0x0A84FF, lightForeground: 0xFFFFFF, darkForeground: 0xFFFFFF, lightText: 0x007AFF, darkText: 0x0A84FF)
        case .cyan: Palette(lightBackground: 0x32ADE6, darkBackground: 0x5ABDE6, lightForeground: 0xFFFFFF, darkForeground: 0xFFFFFF, lightText: 0x0B7285, darkText: 0x64D2FF)
        case .green: Palette(lightBackground: 0x34C759, darkBackground: 0x30D158, lightForeground: 0xFFFFFF, darkForeground: 0xFFFFFF, lightText: 0x248A3D, darkText: 0x30D158)
        case .lime: Palette(lightBackground: 0x9ACD32, darkBackground: 0xB4D83A, lightForeground: 0x1C1C1E, darkForeground: 0x1C1C1E, lightText: 0x587C00, darkText: 0xB4D83A)
        case .yellow: Palette(lightBackground: 0xFFCC00, darkBackground: 0xFFD60A, lightForeground: 0x1C1C1E, darkForeground: 0x1C1C1E, lightText: 0x9A6700, darkText: 0xFFD60A)
        case .orange: Palette(lightBackground: 0xFF9500, darkBackground: 0xFF9F0A, lightForeground: 0xFFFFFF, darkForeground: 0xFFFFFF, lightText: 0xC2410C, darkText: 0xFF9F0A)
        case .pink: Palette(lightBackground: 0xF472B6, darkBackground: 0xF78FC6, lightForeground: 0xFFFFFF, darkForeground: 0xFFFFFF, lightText: 0xD6336C, darkText: 0xF78FC6)
        case .magenta: Palette(lightBackground: 0xD946EF, darkBackground: 0xE260F5, lightForeground: 0xFFFFFF, darkForeground: 0xFFFFFF, lightText: 0xA21CAF, darkText: 0xE260F5)
        }
    }

    private struct Palette {
        let lightBackground: UInt32
        let darkBackground: UInt32
        let lightForeground: UInt32
        let darkForeground: UInt32
        let lightText: UInt32
        let darkText: UInt32
    }
}

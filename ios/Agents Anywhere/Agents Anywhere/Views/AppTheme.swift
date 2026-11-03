import SwiftUI

enum AppTheme {
    static func appBackground(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.black : Color.white
    }

    static func primaryText(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white : Color.black
    }

    static func secondaryText(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.66) : Color.black.opacity(0.58)
    }

    static func primaryControlBackground(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white : Color.black
    }

    static func primaryControlForeground(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.black : Color.white
    }

    static func primaryControlHighlight(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.52) : Color.white.opacity(0.34)
    }

    /// Official composer control chrome (Claude 1.261023.20,
    /// `ChatInputControlChrome`): light #F0EFEC, dark white at 8%.
    static func composerControlFill(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.white.opacity(0.08)
            : Color(red: 240.0 / 255.0, green: 239.0 / 255.0, blue: 236.0 / 255.0)
    }

    /// Official `text100`: light #131313, dark #F9F9F7.
    static func composerControlGlyph(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 249.0 / 255.0, green: 249.0 / 255.0, blue: 247.0 / 255.0)
            : Color(red: 19.0 / 255.0, green: 19.0 / 255.0, blue: 19.0 / 255.0)
    }

    /// Official `text300`: light #383835, dark #C3C2B7.
    static func composerSecondaryGlyph(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 195.0 / 255.0, green: 194.0 / 255.0, blue: 183.0 / 255.0)
            : Color(red: 56.0 / 255.0, green: 56.0 / 255.0, blue: 53.0 / 255.0)
    }

    /// Official `bg000`, the composer attachment tile fill:
    /// light #FFFFFF, dark #20201F.
    static func composerTileBackground(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 32.0 / 255.0, green: 32.0 / 255.0, blue: 31.0 / 255.0)
            : Color.white
    }

    /// Official `border20` renders as a hairline over the tile fill. The base
    /// colour behind the 30% alpha is not statically resolvable (round30 U),
    /// so this approximates the screenshot hairline on both schemes.
    static func composerTileBorder(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.16) : Color.black.opacity(0.10)
    }

    /// Official sheet page colour (screenshots): light #F9F9F7, dark #151515.
    static func composerSheetBackground(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 21.0 / 255.0, green: 21.0 / 255.0, blue: 21.0 / 255.0)
            : Color(red: 249.0 / 255.0, green: 249.0 / 255.0, blue: 247.0 / 255.0)
    }

    /// Official model-picker checkmark (`accentSecondary000`, value still U in
    /// the binary): the screenshot blue, approximated.
    static func pickerCheckmark(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 110.0 / 255.0, green: 155.0 / 255.0, blue: 245.0 / 255.0)
            : Color(red: 47.0 / 255.0, green: 95.0 / 255.0, blue: 191.0 / 255.0)
    }

    static func secondaryControlStroke(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.22) : Color.black.opacity(0.14)
    }

    static func glassScrim(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.black.opacity(0.55) : Color.black.opacity(0.42)
    }

    static func controlShadow(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.clear : Color.black.opacity(0.08)
    }

    /// The single warning semantic. Matches the long-standing `.orange`
    /// precedent (`DeviceStatusTone.warning`) so callers share one token
    /// instead of spelling the literal in each view. It is not scheme-aware
    /// today — orange reads on both the light and dark backgrounds — but the
    /// `(scheme)` shape keeps it swappable without touching call sites.
    static func warning(_ scheme: ColorScheme) -> Color {
        .orange
    }

    static func groupedFill(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.04)
    }

    static func sidebarSelectionFill(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.20) : Color.black.opacity(0.10)
    }

    /// Official sidebar row selection (screenshot: #E7E6E1 on the sidebar
    /// surface). Kept separate from the generic chip selection so device
    /// filters keep their existing tint.
    static func sidebarRowSelectionFill(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.white.opacity(0.20)
            : Color(red: 231.0 / 255.0, green: 230.0 / 255.0, blue: 225.0 / 255.0)
    }

    /// Official DrawerRow text token (binary: slot 0x108151c58, dynamic
    /// color; light #52514E, dark #C3C2B7). Session titles on the drawer
    /// list use this instead of `primary`.
    static func sidebarRowText(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 195.0 / 255.0, green: 194.0 / 255.0, blue: 183.0 / 255.0)
            : Color(red: 82.0 / 255.0, green: 81.0 / 255.0, blue: 78.0 / 255.0)
    }
}

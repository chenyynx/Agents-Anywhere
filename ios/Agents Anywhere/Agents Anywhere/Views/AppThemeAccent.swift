import SwiftUI
import UIKit

/// The accent color as the views need it: `AppAccent`'s hex rows turned into
/// scheme-aware SwiftUI colors. `.default` delegates to the existing
/// black-and-white tokens rather than re-deriving them, so the default look
/// is structurally the shipped one, not approximately it.
extension AppTheme {
    /// The fill of accent-colored controls (send/stop key, prominent glass
    /// buttons, SubAgent stop controls).
    static func accentBackground(_ accent: AppAccent, _ scheme: ColorScheme) -> Color {
        guard accent != .default else { return primaryControlBackground(scheme) }
        return dynamicHex(accent.lightBackgroundHex, accent.darkBackgroundHex)
    }

    /// The glyph laid on top of ``accentBackground(_:_:)``.
    static func accentForeground(_ accent: AppAccent, _ scheme: ColorScheme) -> Color {
        guard accent != .default else { return primaryControlForeground(scheme) }
        return dynamicHex(accent.lightForegroundHex, accent.darkForegroundHex)
    }

    /// The text-role accent: the global tint (links, the composer caret,
    /// selection) and the user bubble's label. Never the control background —
    /// yellow and lime as text on white are unreadable, which is why the
    /// model carries a second, darkened value per accent.
    static func accentTextColor(_ accent: AppAccent, _ scheme: ColorScheme) -> Color {
        guard accent != .default else { return primaryText(scheme) }
        return dynamicHex(accent.lightTextHex, accent.darkTextHex)
    }

    /// The user message bubble's fill. The default reproduces the shipped
    /// bubble exactly — a near-white / near-black gray, no accent at all. An
    /// accent washes the control color at low opacity; dark mode takes more
    /// of the same wash, which would otherwise dissolve into the black
    /// background.
    static func accentBubbleBackground(_ accent: AppAccent, _ scheme: ColorScheme) -> Color {
        guard accent != .default else {
            return scheme == .dark ? Color(white: 0.13) : Color(white: 0.94)
        }
        return accentBackground(accent, scheme).opacity(scheme == .dark ? 0.20 : 0.14)
    }

    /// A color that resolves per interface style at render time: the trait
    /// collection — not this call site — picks the light or dark hex, so a
    /// view re-rendered under a switched appearance gets the right value
    /// without re-resolving from the SwiftUI scheme.
    private static func dynamicHex(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            AppTheme.hexColor(traits.userInterfaceStyle == .dark ? dark : light)
        })
    }

    /// Pure RGB data — no actor state, so the trait-resolution closure may
    /// call it from wherever the provider runs.
    nonisolated private static func hexColor(_ hex: UInt32) -> UIColor {
        UIColor(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

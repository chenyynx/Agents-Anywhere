import Foundation
import Testing
@testable import ClientCore

/// Pins the accent model's two contracts: the persisted raw values — nine
/// strings that outlive any one build — and the color math. Every pair the
/// views render must clear its WCAG bar, so a hex edit that dims a glyph or a
/// bubble fails here, in CI, before it reaches a device.
///
/// Pure numbers only (no SwiftUI): the model carries hex, and the assertions
/// recompute the same quantities the views resolve.
@Suite @MainActor struct AccentTests {
    @Test func unknownOrClearedStorageResolvesToDefault() {
        #expect(AppAccent.resolve(nil) == .default)
        #expect(AppAccent.resolve("") == .default)
        #expect(AppAccent.resolve("turquoise") == .default)
    }

    @Test func everyAccentRawValueRoundTrips() {
        for accent in AppAccent.allCases {
            #expect(AppAccent.resolve(accent.rawValue) == accent)
        }
    }

    /// The full set, order included: these strings are what installs store.
    /// A rename drops every existing choice back to the default; a reorder
    /// would silently reorder the settings list while round-tripping still
    /// passes, so the order is pinned here too.
    @Test func rawValuesAreThePersistedContract() {
        #expect(AppAccent.allCases.map(\.rawValue)
            == ["default", "blue", "cyan", "green", "lime", "yellow", "orange", "pink", "magenta"])
    }

    @Test func storageKeyIsTheAppStorageKey() {
        #expect(AppAccent.storageKey == "agentsAnywhere.accent")
    }

    /// `.default` is the shipped black-and-white pair, both roles, both
    /// schemes: the accent layer must never change what a default install
    /// renders.
    @Test func defaultAccentIsTheBlackAndWhiteInversion() {
        #expect(AppAccent.default.lightBackgroundHex == 0x000000)
        #expect(AppAccent.default.lightForegroundHex == 0xFFFFFF)
        #expect(AppAccent.default.lightTextHex == 0x000000)
        #expect(AppAccent.default.darkBackgroundHex == 0xFFFFFF)
        #expect(AppAccent.default.darkForegroundHex == 0x000000)
        #expect(AppAccent.default.darkTextHex == 0xFFFFFF)
    }

    /// The glyph rule: white on the fill everywhere except lime and yellow,
    /// which carry the near-black `1C1C1E` in both schemes. `.default` is the
    /// inversion itself — white on black, black on white.
    @Test func glyphsAreWhiteExceptLimeAndYellow() {
        for accent in AppAccent.allCases where accent != .lime && accent != .yellow && accent != .default {
            #expect(accent.lightForegroundHex == 0xFFFFFF, "\(accent.rawValue) light")
            #expect(accent.darkForegroundHex == 0xFFFFFF, "\(accent.rawValue) dark")
        }
        #expect(AppAccent.lime.lightForegroundHex == 0x1C1C1E)
        #expect(AppAccent.lime.darkForegroundHex == 0x1C1C1E)
        #expect(AppAccent.yellow.lightForegroundHex == 0x1C1C1E)
        #expect(AppAccent.yellow.darkForegroundHex == 0x1C1C1E)
        #expect(AppAccent.default.lightForegroundHex == 0xFFFFFF)
        #expect(AppAccent.default.darkForegroundHex == 0x000000)
    }

    /// 18 pairs: the control glyph on its own fill, light and dark, clears
    /// the icon bar (2.0). Lime and yellow clear it with the dark glyph;
    /// cyan's dark fill sits at 2.13, the tightest pair in the table.
    @Test func everyControlGlyphClearsItsOwnFill() {
        for accent in AppAccent.allCases {
            let light = contrast(accent.lightForegroundHex, accent.lightBackgroundHex)
            let dark = contrast(accent.darkForegroundHex, accent.darkBackgroundHex)
            #expect(light >= 2.0, "\(accent.rawValue) light glyph \(light)")
            #expect(dark >= 2.0, "\(accent.rawValue) dark glyph \(dark)")
        }
    }

    /// The text role on the standard background (white light, black dark):
    /// readable as text (4.0). Blue sits just above at 4.02 — the shipped
    /// Apple link color — and every light-mode value is its accent's
    /// darkened variant for exactly this bar.
    @Test func textRoleClearsTheStandardBackground() {
        for accent in AppAccent.allCases {
            let light = contrast(accent.lightTextHex, 0xFFFFFF)
            let dark = contrast(accent.darkTextHex, 0x000000)
            #expect(light >= 4.0, "\(accent.rawValue) light text \(light)")
            #expect(dark >= 4.0, "\(accent.rawValue) dark text \(dark)")
        }
    }

    /// The bubble: the text role on the fill `AppTheme.accentBubbleBackground`
    /// renders — the control color at the design's opacity (0.14 light /
    /// 0.20 dark) over the standard background. The bar is 3.0: bubble text
    /// may run softer than body copy, but not unreadable. `.default` renders
    /// the shipped gray (0.94 / 0.13 white) instead of an accent wash; the
    /// bytes here are that gray.
    @Test func textRoleClearsTheBubbleFill() {
        for accent in AppAccent.allCases where accent != .default {
            let light = contrast(accent.lightTextHex, bubble(accent.lightBackgroundHex, over: 0xFFFFFF, opacity: 0.14))
            let dark = contrast(accent.darkTextHex, bubble(accent.darkBackgroundHex, over: 0x000000, opacity: 0.20))
            #expect(light >= 3.0, "\(accent.rawValue) light bubble \(light)")
            #expect(dark >= 3.0, "\(accent.rawValue) dark bubble \(dark)")
        }
        #expect(contrast(AppAccent.default.lightTextHex, 0xF0F0F0) >= 3.0)
        #expect(contrast(AppAccent.default.darkTextHex, 0x212121) >= 3.0)
    }

    // MARK: - The math

    /// WCAG 2.x relative luminance of an sRGB hex value.
    private func luminance(_ hex: UInt32) -> Double {
        func channel(_ shift: UInt32) -> Double {
            let value = Double((hex >> shift) & 0xFF) / 255
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(16) + 0.7152 * channel(8) + 0.0722 * channel(0)
    }

    private func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        let la = luminance(a)
        let lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// The bubble fill as the renderer composites it: `hex` at `opacity` over
    /// the standard background, channel-wise in sRGB.
    private func bubble(_ hex: UInt32, over base: UInt32, opacity: Double) -> UInt32 {
        var result: UInt32 = 0
        for shift: UInt32 in [16, 8, 0] {
            let top = Double((hex >> shift) & 0xFF)
            let bottom = Double((base >> shift) & 0xFF)
            result |= UInt32((bottom + (top - bottom) * opacity).rounded()) << shift
        }
        return result
    }
}

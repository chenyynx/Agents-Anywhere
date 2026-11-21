import Foundation

/// User-tunable chat colours, stored the same way the Thinking orb stores its
/// palette: plain `#RRGGBB` strings in `UserDefaults`.
///
/// The legacy pair is the retired Chat page's body template and link. The
/// Code page adds three independent inks — file reference, external link and
/// inline code — each edited as one colour: light mode uses it verbatim and
/// dark mode resolves the shipped dark value (defaults) or a contrast-lifted
/// variant (custom). Every default is the value the visuals shipped with, so
/// an untouched install looks identical to the reference.
nonisolated enum ChatColorSettings {
    static let bodyTemplateKey = "agentsAnywhere.chat.bodyTemplateHex"
    static let linkKey = "agentsAnywhere.chat.linkHex"
    /// The Code page's three inks (pp 2026-11-22). One stored `#RRGGBB` per
    /// item: the settings page edits a single colour, light mode uses it
    /// verbatim, and dark mode resolves the shipped dark value (a default) or
    /// a lifted variant (a custom colour) — see `codeInk(_:fallback:)`.
    static let codeFileReferenceKey = "agentsAnywhere.code.fileReferenceHex"
    static let codeExternalLinkKey = "agentsAnywhere.code.externalLinkHex"
    static let codeInlineCodeKey = "agentsAnywhere.code.inlineCodeHex"
    /// Inline code weight. Off is the regular the chat has shipped with; on is
    /// semibold, the same weight `**` already gives a bolded run, so a turned-on
    /// span and a `**`-wrapped one read as one family.
    static let inlineCodeBoldKey = "agentsAnywhere.chat.inlineCodeBold"

    /// `[pp 2026-10-18]` a neutral grey. The inline-code orange competed with
    /// the link blue for the same "this is not prose" signal; grey leaves the
    /// colour channel to the link. One value for both appearances: on the dark
    /// chat background it measures 4.8:1, on white 3.6:1 — above the 3:1 that
    /// large or incidental text needs, below what body copy would want.
    static let defaultBodyTemplate = Pair(light: "#858585", dark: "#858585")
    /// Deeper than the shipped `#3377AA` so a link reads as deliberate ink
    /// rather than a washed-out accent. 7.1:1 on white, 6.8:1 on the dark chat
    /// background.
    static let defaultLink = Pair(light: "#1F5C8B", dark: "#6FA8D6")

    /// Built-in Code-page inks. The defaults are the shipped visuals, so an
    /// untouched install renders exactly as before; their dark values are
    /// hand-tuned and bypass the automatic lift.
    /// Same blue as inline code: the white chip is what tells a file
    /// reference apart (pp 2026-11-22).
    static let defaultCodeFileReference = Pair(light: "#184F95", dark: "#6DA7EC")
    static let defaultCodeExternalLink = Pair(light: "#131313", dark: "#F9F9F7")
    static let defaultCodeInlineCode = Pair(light: "#184F95", dark: "#6DA7EC")

    /// Whether inline code renders semibold. Absent key reads as off, so an
    /// untouched install keeps the regular it has always had.
    static func inlineCodeBold(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: inlineCodeBoldKey)
    }

    // MARK: - Code-page inks

    static func codeFileReference(in defaults: UserDefaults = .standard) -> Pair {
        codeInk(defaults.string(forKey: codeFileReferenceKey),
                fallback: defaultCodeFileReference)
    }

    static func codeExternalLink(in defaults: UserDefaults = .standard) -> Pair {
        codeInk(defaults.string(forKey: codeExternalLinkKey),
                fallback: defaultCodeExternalLink)
    }

    static func codeInlineCode(in defaults: UserDefaults = .standard) -> Pair {
        codeInk(defaults.string(forKey: codeInlineCodeKey),
                fallback: defaultCodeInlineCode)
    }

    /// One stored hex, or nothing, becomes the light/dark pair the renderers
    /// resolve at draw time. Nothing (or something unparseable) keeps the
    /// built-in pair untouched; a custom colour keeps its light value and gets
    /// the lifted dark variant.
    static func codeInk(_ raw: String?, fallback: Pair) -> Pair {
        guard let raw, let hex = normalized(raw) else { return fallback }
        return Pair(light: hex, dark: darkVariant(of: hex))
    }

    /// Stores one custom ink. Returns false for an unparseable value.
    @discardableResult
    static func setCodeColor(_ hex: String, for key: String,
                             in defaults: UserDefaults = .standard) -> Bool {
        guard let value = normalized(hex) else { return false }
        defaults.set(value, forKey: key)
        return true
    }

    static func resetCodeColors(in defaults: UserDefaults = .standard) {
        for key in [codeFileReferenceKey, codeExternalLinkKey, codeInlineCodeKey] {
            defaults.removeObject(forKey: key)
        }
    }

    /// The dark chat page background (`#151515`), the surface a chosen ink has
    /// to read on in dark mode.
    static let codeDarkPageHex = "#151515"

    /// Dark-mode variant of a single chosen ink: same hue mixed toward white
    /// until it clears 3:1 against the dark page. A colour that already
    /// clears it is returned unchanged (normalised). The target carries a
    /// little headroom so rounding to 8-bit cannot land below 3:1.
    static func darkVariant(of hex: String) -> String {
        guard let value = normalized(hex), let base = rgb(of: value),
              let background = rgb(of: codeDarkPageHex) else { return hex }
        let target = 3.05
        if contrastRatio(base, background) >= target { return value }
        var low = 0.0
        var high = 1.0
        var best = base
        for _ in 0..<24 {
            let middle = (low + high) / 2
            let lifted = mix(base, toward: (1, 1, 1), amount: middle)
            if contrastRatio(lifted, background) >= target {
                best = lifted
                high = middle
            } else {
                low = middle
            }
        }
        return hexString(best)
    }

    /// WCAG contrast ratio between two `#RRGGBB` values, or nil when either
    /// is unparseable.
    static func contrastRatio(_ first: String, _ second: String) -> Double? {
        guard let a = rgb(of: first), let b = rgb(of: second) else { return nil }
        return contrastRatio(a, b)
    }

    private typealias RGB = (r: Double, g: Double, b: Double)

    private static func rgb(of hex: String) -> RGB? {
        guard let (r, g, b) = parse(hex) else { return nil }
        return (Double(r) / 255, Double(g) / 255, Double(b) / 255)
    }

    private static func contrastRatio(_ a: RGB, _ b: RGB) -> Double {
        let first = relativeLuminance(a)
        let second = relativeLuminance(b)
        return (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }

    private static func relativeLuminance(_ color: RGB) -> Double {
        func channel(_ value: Double) -> Double {
            value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(color.r)
            + 0.7152 * channel(color.g)
            + 0.0722 * channel(color.b)
    }

    private static func mix(_ color: RGB, toward other: RGB,
                            amount: Double) -> RGB {
        (color.r + (other.r - color.r) * amount,
         color.g + (other.g - color.g) * amount,
         color.b + (other.b - color.b) * amount)
    }

    private static func hexString(_ color: RGB) -> String {
        String(format: "#%02X%02X%02X",
               Int((color.r * 255).rounded()),
               Int((color.g * 255).rounded()),
               Int((color.b * 255).rounded()))
    }

    struct Pair: Equatable {
        let light: String
        let dark: String

        var isSymmetric: Bool { light.caseInsensitiveCompare(dark) == .orderedSame }
    }

    /// Storage is one string; a malformed value falls back to the default
    /// rather than leaving the chat with an unparseable colour.
    static func decode(_ raw: String, fallback: Pair) -> Pair {
        let parts = raw.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, parse(parts[0]) != nil, parse(parts[1]) != nil else { return fallback }
        return Pair(light: parts[0], dark: parts[1])
    }

    static func encode(_ pair: Pair) -> String { "\(pair.light)|\(pair.dark)" }

    /// `#RRGGBB` → (r, g, b) in 0…255, or nil for anything else.
    static func parse(_ hex: String) -> (UInt32, UInt32, UInt32)? {
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        return ((value >> 16) & 0xFF, (value >> 8) & 0xFF, value & 0xFF)
    }

    /// Normalises user input for display and storage; nil when unparseable.
    static func normalized(_ hex: String) -> String? {
        guard parse(hex) != nil else { return nil }
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if !text.hasPrefix("#") { text = "#" + text }
        return text
    }
}

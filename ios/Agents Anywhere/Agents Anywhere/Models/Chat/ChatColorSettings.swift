import Foundation

/// User-tunable chat colours, stored the same way the Thinking orb stores its
/// palette: a plain `@AppStorage` string holding `#RRGGBB` per appearance.
///
/// Only the two colours that read as *ink* rather than chrome are exposed —
/// the body's secondary grey (inline code, quotes, captions) and links. Both
/// default to the values the visual refresh shipped with, so an untouched
/// install looks identical to the reference.
enum ChatColorSettings {
    static let bodyTemplateKey = "agentsAnywhere.chat.bodyTemplateHex"
    static let linkKey = "agentsAnywhere.chat.linkHex"
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

    /// Whether inline code renders semibold. Absent key reads as off, so an
    /// untouched install keeps the regular it has always had.
    static func inlineCodeBold(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: inlineCodeBoldKey)
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

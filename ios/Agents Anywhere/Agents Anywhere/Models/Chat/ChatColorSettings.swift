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

    /// moonveil's body template: the inline-code orange it settled on after
    /// the 2026-09-17 review. Light stays this value; dark keeps the same hue
    /// because it is the contrast-carrying colour once the pill is gone.
    static let defaultBodyTemplate = Pair(light: "#FF6A00", dark: "#FF6A00")
    /// Deeper than the shipped `#3377AA` so a link reads as deliberate ink
    /// rather than a washed-out accent.
    static let defaultLink = Pair(light: "#1F5C8B", dark: "#6FA8D6")

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

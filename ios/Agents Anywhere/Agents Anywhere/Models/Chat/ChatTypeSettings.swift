import CoreGraphics
import Foundation

/// Resolves the assistant body's type scale from defaults.
///
/// Three keys, all optional:
/// - `scheme`: which preset is active (defaults to `compact`, AA's shipped look)
/// - `bodySize`: a body size the user dialled in *for the active scheme*; the
///   rest of the scheme re-proportions around it
/// - `custom`: a JSON snapshot used only while `scheme == .custom`
enum ChatTypeSettings {
    static let schemeKey = "agentsAnywhere.chat.typeScheme"
    static let bodySizeKey = "agentsAnywhere.chat.bodySize"
    static let customKey = "agentsAnywhere.chat.customTypeScale"

    static let bodySizeRange: ClosedRange<CGFloat> = 11...20

    /// What the chat renders with right now.
    static func resolve(
        schemeRaw: String?,
        bodySizeRaw: Double?,
        customRaw: String?,
        defaults: UserDefaults = .standard
    ) -> ChatTypeScale {
        let scheme = ChatTypeScheme(rawValue: schemeRaw ?? "") ?? .compact
        let bodyOverride = bodySizeRaw.flatMap { value -> CGFloat? in
            guard value.isFinite else { return nil }
            return min(max(CGFloat(value), bodySizeRange.lowerBound), bodySizeRange.upperBound)
        }
        if scheme == .custom {
            return decodeCustom(customRaw) ?? ChatTypeScheme.compactScale
        }
        return scheme.scale(bodyOverride: bodyOverride) ?? ChatTypeScheme.compactScale
    }

    /// Convenience for the render path, which cannot hold a `UserDefaults`.
    static var current: ChatTypeScale {
        resolve(
            schemeRaw: UserDefaults.standard.string(forKey: schemeKey),
            bodySizeRaw: UserDefaults.standard.object(forKey: bodySizeKey) as? Double,
            customRaw: UserDefaults.standard.string(forKey: customKey)
        )
    }

    // MARK: Custom snapshot

    /// The custom scale is a flat JSON object so a future field can be added
    /// without invalidating stored values; unknown keys are ignored and any
    /// missing key falls back to the compact preset.
    private struct Stored: Codable {
        var body: CGFloat
        var lineSpacing: CGFloat
        var inlineCode: CGFloat?
        var codeBlock: CGFloat?
        var paragraphSpacing: CGFloat
        var headings: [CGFloat]
    }

    static func encodeCustom(_ scale: ChatTypeScale) -> String {
        let stored = Stored(body: scale.body, lineSpacing: scale.lineSpacing,
                            inlineCode: scale.inlineCode, codeBlock: scale.codeBlock,
                            paragraphSpacing: scale.paragraphSpacing, headings: scale.headings)
        guard let data = try? JSONEncoder().encode(stored),
              let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }

    static func decodeCustom(_ raw: String?) -> ChatTypeScale? {
        guard let raw, let data = raw.data(using: .utf8),
              let stored = try? JSONDecoder().decode(Stored.self, from: data),
              stored.body > 0 else { return nil }
        return ChatTypeScale(
            body: stored.body,
            lineSpacing: stored.lineSpacing,
            inlineCode: stored.inlineCode,
            codeBlock: stored.codeBlock,
            paragraphSpacing: stored.paragraphSpacing,
            headings: stored.headings
        )
    }

    // MARK: Reset

    static func reset(in defaults: UserDefaults = .standard) {
        for key in [schemeKey, bodySizeKey, customKey] {
            defaults.removeObject(forKey: key)
        }
    }
}

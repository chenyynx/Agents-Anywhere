#if canImport(UIKit)
import CoreText
import UIKit

/// Builds the official Code page's variable fonts.
///
/// The app bundles Anthropic Sans/Serif and JetBrains Mono (extracted from
/// the official IPA; see `Resources/Fonts`). They are variable fonts: weight
/// comes from the `wght` axis, not from a static face. `UIFont(name:)` picks
/// the default instance, so a weight request has to go through
/// `kCTFontVariationAttribute`.
enum MarkdownFontFactory {
    /// The `wght` axis tag.
    private static let weightAxis = NSNumber(value: 0x77676874)

    static func font(name: String?, size: CGFloat, weight: CGFloat) -> UIFont {
        let size = max(1, size)
        guard let name, let base = UIFont(name: name, size: size) else {
            return UIFont.systemFont(ofSize: size, weight: uiWeight(weight))
        }
        return UIFont(descriptor: descriptor(base.fontDescriptor, weight: weight),
                      size: size)
    }

    /// Applies a weight variation to an existing (variable) font, keeping its
    /// family. Used by syntax highlighting's keyword emphasis.
    static func weighted(_ font: UIFont, weight: CGFloat) -> UIFont {
        UIFont(descriptor: descriptor(font.fontDescriptor, weight: weight),
               size: font.pointSize)
    }

    private static func descriptor(_ base: UIFontDescriptor,
                                   weight: CGFloat) -> UIFontDescriptor {
        let variation: [NSNumber: NSNumber] = [weightAxis: NSNumber(value: weight)]
        let attributes: [UIFontDescriptor.AttributeName: Any] = [
            UIFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String):
                variation,
        ]
        return base.addingAttributes(attributes)
    }

    /// Fallback mapping for system faces when a bundled family is missing.
    private static func uiWeight(_ weight: CGFloat) -> UIFont.Weight {
        switch weight {
        case ..<350: return .light
        case ..<450: return .regular
        case ..<520: return .medium
        case ..<650: return .semibold
        case ..<750: return .bold
        default: return .heavy
        }
    }
}
#endif

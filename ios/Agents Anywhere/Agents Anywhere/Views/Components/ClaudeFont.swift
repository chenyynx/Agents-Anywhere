import CoreText
import SwiftUI
import UIKit

/// The official app's UI face: Anthropic Sans Mobile, a variable font
/// (`wght` 300–800) bundled from the 1.261109.19 capture. The outline rows use
/// it so Latin text and digits match the official letterforms; CJK glyphs fall
/// back to the system face exactly as they do in the official app.
enum ClaudeFont {
    static let postScriptName = "AnthropicSansMobileVariable-TextRegular"

    /// The capture's row text sits between the 400 and 500 named instances
    /// (stroke 5.29 px against 4.66 / 5.61); 460 reproduces it at the scaled
    /// 13 pt size.
    static let rowWeight: CGFloat = 460

    /// `UIAppFonts` registers the bundled file at launch; registering it here
    /// as well keeps previews and a missed plist path working, since a custom
    /// font is the only way to reproduce the capture's letterforms.
    private static let isRegistered: Bool = {
        guard let url = Bundle.main.url(forResource: postScriptName,
                                        withExtension: "ttf") else { return false }
        return CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }()

    static func text(_ size: CGFloat, weight: CGFloat = rowWeight) -> Font {
        _ = isRegistered
        guard let base = UIFont(name: postScriptName, size: size) else {
            return .system(size: size, weight: .regular)
        }
        let axis = NSNumber(value: 0x77676874) // 'wght'
        let descriptor = base.fontDescriptor.addingAttributes([
            UIFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String):
                [axis: NSNumber(value: weight)] as [NSNumber: NSNumber],
        ])
        return Font(UIFont(descriptor: descriptor, size: size))
    }
}

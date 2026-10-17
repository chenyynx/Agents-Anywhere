import SwiftUI
import UIKit

/// Bridges `ChatPalette`'s hex tokens to SwiftUI colours.
///
/// The tokens live in `ClientCore` for macOS compilation; this view-layer
/// bridge is where `UIColor` is allowed to exist.
extension ChatPalette.Token {
    var color: Color { Color(uiColor: uiColor) }

    var uiColor: UIColor {
        UIColor { traits in
            UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light)
        }
    }
}

extension ChatPalette.Token {
    /// Convenience so call sites read like a palette, not like a token.
    static func foreground(_ token: ChatPalette.Token) -> Color { token.color }
}

private extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: 1)
    }
}

import SwiftUI
import UIKit

/// The outline's official type: the Code page's bundled Anthropic Sans for the
/// rows and JetBrains Mono for inline code. `AppFontRegistry` already
/// registers both faces at launch, so this only selects the captured weights.
enum ClaudeFont {
    /// The capture's row text sits between the 400 and 500 instances
    /// (stroke 5.29 px against 4.66 / 5.61); 460 reproduces it at the scaled
    /// 13 pt size.
    static let rowWeight: CGFloat = 460

    static func text(_ size: CGFloat, weight: CGFloat = rowWeight) -> Font {
        Font(MarkdownFontFactory.font(name: CodePageTheme.sansFontName,
                                      size: size, weight: weight))
    }

    static func mono(_ size: CGFloat) -> Font {
        Font(MarkdownFontFactory.font(name: CodePageTheme.monoFontName,
                                      size: size, weight: 400))
    }
}

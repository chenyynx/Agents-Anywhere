import SwiftUI
import UIKit

/// The outline's official type: the Code page's bundled Anthropic Sans for the
/// rows and JetBrains Mono for inline code. `AppFontRegistry` already
/// registers both faces at launch, so this only selects the captured weights.
enum ClaudeFont {
    /// The capture's speaker sits on the Medium named instance: its stroke
    /// measures 5.29 px, where 460 rendered only 4.79 px. The title and stamp
    /// pass the Regular 400 face explicitly.
    static let rowWeight: CGFloat = 500

    static func text(_ size: CGFloat, weight: CGFloat = rowWeight) -> Font {
        Font(MarkdownFontFactory.font(name: CodePageTheme.sansFontName,
                                      size: size, weight: weight))
    }

    static func mono(_ size: CGFloat) -> Font {
        Font(MarkdownFontFactory.font(name: CodePageTheme.monoFontName,
                                      size: size, weight: 400))
    }
}

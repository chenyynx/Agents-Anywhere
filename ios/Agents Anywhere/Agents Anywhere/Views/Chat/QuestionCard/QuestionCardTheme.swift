import SwiftUI
import UIKit

/// Bridges the E-grade numbers in `QuestionCardMetrics` to SwiftUI colours and
/// the official Anthropic Sans faces. The metrics stay in `Models` so the
/// package tests can assert them; this file only resolves them for drawing.
nonisolated enum QuestionCardTheme {

    static func color(_ pair: QuestionCardMetrics.Pair, _ scheme: ColorScheme) -> Color {
        let rgb = scheme == .dark ? pair.dark : pair.light
        return Color(.sRGB, red: rgb.red, green: rgb.green, blue: rgb.blue,
                     opacity: rgb.alpha)
    }

    static func font(size: CGFloat, weight: CGFloat) -> Font {
        Font(MarkdownFontFactory.font(name: CodePageTheme.sansFontName,
                                      size: size, weight: weight))
    }

    /// SwiftUI's `Text` has no line-height control; add the gap between the
    /// official line height and the face's natural line box.
    static func lineSpacing(size: CGFloat, lineHeight: CGFloat) -> CGFloat {
        let natural = UIFont(name: CodePageTheme.sansFontName, size: size)?.lineHeight
            ?? size * 1.2
        return max(0, lineHeight - natural)
    }
}

import SwiftUI
import Textual

/// Syntax palette for fenced code blocks.
///
/// Token keys come from `StructuredText.HighlighterTheme.TokenType` (the
/// hyphenated raw values — `class-name`, `block-comment` — not the Swift
/// property names). Textual's tokenizer is untouched; only colours change.
///
/// Every entry is written as an explicit `AnyTextProperty` because the
/// dictionary's value type cannot be inferred through the shorthand members.
enum ChatHighlighterTheme {
    private static func color(_ token: ChatPalette.Token, weight: Font.Weight? = nil) -> AnyTextProperty {
        guard let weight else { return AnyTextProperty(.foregroundColor(token.color)) }
        return AnyTextProperty(.foregroundColor(token.color), .fontWeight(weight))
    }

    static let standard = StructuredText.HighlighterTheme(
        foregroundColor: ChatPalette.text.dynamicColor,
        backgroundColor: ChatPalette.codeFill.dynamicColor,
        tokenProperties: [
            // Measured in the reference capture (TOML: key / string / comment / punct).
            .property: color(ChatPalette.synKey),
            .variable: color(ChatPalette.synKey),
            .string: color(ChatPalette.synString),
            .char: color(ChatPalette.synString),
            .regex: color(ChatPalette.synString),
            .comment: color(ChatPalette.synComment),
            .blockComment: color(ChatPalette.synComment),
            .docComment: color(ChatPalette.synComment),
            .punctuation: color(ChatPalette.synPunct),
            .symbol: color(ChatPalette.synPunct),

            // Derived: the reference run contained no keyword, number, type or
            // call, so these follow the same family as the measured colours.
            .keyword: color(ChatPalette.synKeyword, weight: .semibold),
            .literal: color(ChatPalette.synKeyword, weight: .semibold),
            .boolean: color(ChatPalette.synKeyword, weight: .semibold),
            .number: color(ChatPalette.synNumber),
            .className: color(ChatPalette.synType),
            .function: color(ChatPalette.synFunction),
            .functionName: color(ChatPalette.synFunction),
        ]
    )
}

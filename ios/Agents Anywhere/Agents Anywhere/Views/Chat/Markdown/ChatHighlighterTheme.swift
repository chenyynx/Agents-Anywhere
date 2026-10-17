import SwiftUI
import Textual

/// Syntax palette for fenced code blocks.
///
/// Token keys come from `StructuredText.HighlighterTheme.TokenType` (the
/// hyphenated raw values — `class-name`, `block-comment` — not the Swift
/// property names). Textual's tokenizer is untouched; only colours change.
///
/// `HighlighterTheme` takes `DynamicColor` for its two base slots but accepts a
/// plain `Color` for each token property, which is what the palette tokens
/// bridge to.
enum ChatHighlighterTheme {
    static let standard = StructuredText.HighlighterTheme(
        foregroundColor: ChatPalette.text.dynamicColor,
        backgroundColor: ChatPalette.codeFill.dynamicColor,
        tokenProperties: [
            // Measured in the reference capture (TOML: key / string / comment / punct).
            .property: .foregroundColor(ChatPalette.synKey.color),
            .variable: .foregroundColor(ChatPalette.synKey.color),
            .string: .foregroundColor(ChatPalette.synString.color),
            .char: .foregroundColor(ChatPalette.synString.color),
            .regex: .foregroundColor(ChatPalette.synString.color),
            .comment: .foregroundColor(ChatPalette.synComment.color),
            .blockComment: .foregroundColor(ChatPalette.synComment.color),
            .docComment: .foregroundColor(ChatPalette.synComment.color),
            .punctuation: .foregroundColor(ChatPalette.synPunct.color),
            .symbol: .foregroundColor(ChatPalette.synPunct.color),

            // Derived: the reference run contained no keyword, number, type or
            // call, so these follow the same family as the measured colours.
            .keyword: AnyTextProperty(.foregroundColor(ChatPalette.synKeyword.color), .fontWeight(.semibold)),
            .literal: AnyTextProperty(.foregroundColor(ChatPalette.synKeyword.color), .fontWeight(.semibold)),
            .boolean: AnyTextProperty(.foregroundColor(ChatPalette.synKeyword.color), .fontWeight(.semibold)),
            .number: .foregroundColor(ChatPalette.synNumber.color),
            .className: .foregroundColor(ChatPalette.synType.color),
            .function: .foregroundColor(ChatPalette.synFunction.color),
            .functionName: .foregroundColor(ChatPalette.synFunction.color),
        ]
    )
}

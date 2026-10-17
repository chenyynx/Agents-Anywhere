import SwiftUI
import Textual

/// Syntax palette for fenced code blocks.
///
/// Token keys come from `StructuredText.HighlighterTheme.TokenType` (the
/// hyphenated raw values — `class-name`, `block-comment` — not the Swift
/// property names). Textual's tokenizer is untouched; only colours change.
enum ChatHighlighterTheme {
    static let standard = StructuredText.HighlighterTheme(
        foregroundColor: ChatPalette.text.color,
        backgroundColor: ChatPalette.codeFill.color,
        tokenProperties: [
            // Measured in the reference capture (TOML: key / string / comment / punct).
            .property: property(.foregroundColor(ChatPalette.synKey.color)),
            .variable: property(.foregroundColor(ChatPalette.synKey.color)),
            .string: property(.foregroundColor(ChatPalette.synString.color)),
            .char: property(.foregroundColor(ChatPalette.synString.color)),
            .regex: property(.foregroundColor(ChatPalette.synString.color)),
            .comment: property(.foregroundColor(ChatPalette.synComment.color)),
            .blockComment: property(.foregroundColor(ChatPalette.synComment.color)),
            .docComment: property(.foregroundColor(ChatPalette.synComment.color)),
            .punctuation: property(.foregroundColor(ChatPalette.synPunct.color)),
            .symbol: property(.foregroundColor(ChatPalette.synPunct.color)),

            // Derived: the reference run contained no keyword, number, type or
            // call, so these follow the same family as the measured colours.
            .keyword: property(.foregroundColor(ChatPalette.synKeyword.color), .fontWeight(.semibold)),
            .literal: property(.foregroundColor(ChatPalette.synKeyword.color), .fontWeight(.semibold)),
            .boolean: property(.foregroundColor(ChatPalette.synKeyword.color), .fontWeight(.semibold)),
            .number: property(.foregroundColor(ChatPalette.synNumber.color)),
            .className: property(.foregroundColor(ChatPalette.synType.color)),
            .function: property(.foregroundColor(ChatPalette.synFunction.color)),
            .functionName: property(.foregroundColor(ChatPalette.synFunction.color)),
        ]
    )
}

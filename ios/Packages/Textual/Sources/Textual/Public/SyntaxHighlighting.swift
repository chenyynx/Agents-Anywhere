import Foundation

/// A token produced by Textual's Prism tokenizer.
///
/// This is a thin public bridge over the tokenizer that fenced code blocks
/// already use. It lets a host that renders code outside a `StructuredText`
/// view keep the exact same token stream instead of reimplementing Prism.
public struct SyntaxHighlightToken: Hashable, Sendable {
  public let content: String
  public let type: StructuredText.HighlighterTheme.TokenType

  public init(content: String, type: StructuredText.HighlighterTheme.TokenType) {
    self.content = content
    self.type = type
  }
}

public enum SyntaxHighlighting {
  /// Tokenize `code` with the same JavaScriptCore Prism bundle Textual ships.
  ///
  /// Returns one plain token when the language is unknown, the bundle is
  /// missing, or JavaScriptCore is unavailable.
  public static func tokenize(
    code: String,
    language: String?
  ) async -> [SyntaxHighlightToken] {
    guard let language, !language.isEmpty,
          let tokenizer = CodeTokenizer.shared else {
      return [SyntaxHighlightToken(content: code, type: .plain)]
    }
    let tokens = await tokenizer.tokenize(code: code, language: language)
    return tokens.map { SyntaxHighlightToken(content: $0.content, type: $0.type) }
  }
}

#if canImport(UIKit)
import Foundation
import Textual

/// One highlighted span of a fenced code block.
struct CodeHighlightToken: Hashable {
    let content: String
    /// Engine-neutral scope name. Phase 1 uses Textual's Prism
    /// `TokenType.rawValue`; Phase 2 maps the official PegEngine's scope names
    /// onto the same strings.
    let scope: String
}

/// The seam between the code card and the highlighter.
///
/// Phase 1 wraps Textual's Prism tokenizer. Phase 2 replaces the
/// implementation with the official PegEngine's resumable session
/// (`PegHighlighter` / `PegHighlightSession` / `PegIncrementalHighlight`)
/// without touching the card, the leaf or the height cache.
@MainActor
protocol CodeHighlightEngine: AnyObject {
    func tokenize(_ code: String, language: String?) async -> [CodeHighlightToken]
}

/// Prism via Textual's JavaScriptCore bundle. The tokenizer is an actor, so
/// the JavaScript work stays off the main actor; only the returned stream is
/// applied on the main actor.
///
/// Phase 1 caveat: this is a full tokenize per tick. Prism exposes no
/// resumable state, and restarting inside a multi-line string or comment would
/// recolour text incorrectly — the official PegEngine solves that with its own
/// session. Until Phase 2, the savings come from applying only the changed
/// tail and from keeping the tokenization off the main actor. This engine is
/// deliberately not claimed to be token-identical to the official PegEngine.
@MainActor
final class PrismCodeHighlightEngine: CodeHighlightEngine {
    func tokenize(_ code: String, language: String?) async -> [CodeHighlightToken] {
        let tokens = await SyntaxHighlighting.tokenize(code: code, language: language)
        return tokens.map { CodeHighlightToken(content: $0.content, scope: $0.type.rawValue) }
    }
}
#endif

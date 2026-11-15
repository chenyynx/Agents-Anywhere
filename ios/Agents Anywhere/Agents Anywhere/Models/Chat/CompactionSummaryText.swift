import Foundation

/// The official Code page's compaction labels
/// (`EVIDENCE/round31-compaction-ui.md` §4–§5). The settled divider carries
/// one line: `已压缩对话`, extended with a token clause when the wire's
/// `compact_boundary` metadata has one, or the failure message.
///
/// The official summary is numbers only — `savedTokens(Int)` /
/// `preCompactionTokens(Int)` / `unknown`. The compacted conversation's text
/// is a separate transcript item, never part of this line.
nonisolated enum CompactionSummaryText {
    /// The two token variants the official strings carry.
    enum TokenCount: Equatable, Sendable {
        /// `compacted_conversation_saved_tokens` — `已压缩对话 · 节省了 %@ 个 token`.
        case saved(Int)
        /// `compacted_conversation_from_tokens` — `已压缩对话 · 压缩前 %@ 个 token`.
        case preCompaction(Int)
    }

    /// The token clause the compact marker's content supports.
    ///
    /// The CLI's `compact_boundary` carries `preTokens`, `postTokens` and
    /// `cumulativeDroppedTokens` (real-wire fixture:
    /// `connector/tests/test_claude_commands.py`). Saved is the more useful
    /// number, so it wins when the drop is positive; a zero drop falls back
    /// to the conversation's size instead of announcing "saved 0 tokens".
    static func tokenCount(in content: JSONValue?) -> TokenCount? {
        if let saved = content?["cumulativeDroppedTokens"]?.intValue, saved > 0 {
            return .saved(saved)
        }
        if let pre = content?["preTokens"]?.intValue, pre > 0 {
            return .preCompaction(pre)
        }
        return nil
    }

    /// The settled divider label, in the official Code form.
    static func label(_ count: TokenCount?,
                      locale: Locale = .autoupdatingCurrent) -> String {
        switch count {
        case let .saved(tokens):
            return String(localized: "已压缩对话 · 节省了 \(tokens.formatted(.number.locale(locale))) 个 token")
        case let .preCompaction(tokens):
            return String(localized: "已压缩对话 · 压缩前 \(tokens.formatted(.number.locale(locale))) 个 token")
        case nil:
            return String(localized: "已压缩对话")
        }
    }

    /// `2bf2.compaction_failed_message`.
    static var failed: String { String(localized: "对话压缩失败。") }
}

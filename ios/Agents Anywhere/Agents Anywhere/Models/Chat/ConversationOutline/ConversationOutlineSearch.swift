import Foundation

/// One entry that matches the query, with the message a tap should open and the
/// excerpt to show in the row.
nonisolated struct ConversationOutlineSearchResult: Equatable {
    let hits: [ConversationOutlineSearchHit]
    /// Matching messages, which can exceed `hits.count` because one outline
    /// row merges several messages of the same turn and sender.
    let messageCount: Int
}

nonisolated struct ConversationOutlineSearchHit: Equatable {
    let entryID: V2TimelineItemID
    let partID: V2TimelineItemID
    /// The matched message's visible characters, with Markdown markers
    /// resolved and whitespace folded, for VoiceOver and tests.
    let snippet: String
    /// The same message with its inline formatting preserved.
    let snippetAttributed: AttributedString
}

/// Outline search: case- and diacritic-insensitive substring matching over the
/// already-built rows. The official app folds both sides the same way and shows
/// the whole matched message — no highlight colour (that branch is dead code in
/// the official build).
nonisolated enum ConversationOutlineSearch {
    static func tokens(_ query: String) -> [String] {
        query.split(whereSeparator: \.isWhitespace).map(String.init).filter { !$0.isEmpty }
    }

    static func folded(_ text: String, locale: Locale = .current) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: locale)
    }

    /// Returns a hit only when every query token appears in one part; the hit's
    /// `partID` is that part, so a tap lands on the message that matched.
    static func hit(
        in entry: ConversationOutlineEntry,
        query: String,
        locale: Locale = .current
    ) -> ConversationOutlineSearchHit? {
        search([entry], query: query, locale: locale).hits.first
    }

    /// One pass over the corpus: count every matching message and keep the
    /// first hit of each entry for the row. Only that hit's text is parsed, so
    /// typing does not rebuild an AttributedString for every message.
    static func search(
        _ entries: [ConversationOutlineEntry],
        query: String,
        locale: Locale = .current
    ) -> ConversationOutlineSearchResult {
        let tokens = tokens(query)
        guard !tokens.isEmpty else {
            return ConversationOutlineSearchResult(
                hits: [],
                messageCount: entries.reduce(0) { $0 + $1.parts.count }
            )
        }
        let foldedTokens = tokens.map { folded($0, locale: locale) }
        var hits: [ConversationOutlineSearchHit] = []
        var messageCount = 0
        for entry in entries {
            var firstHit: ConversationOutlineSearchHit?
            for part in entry.parts {
                let foldedText = folded(part.text, locale: locale)
                guard foldedTokens.allSatisfy({ foldedText.contains($0) }) else { continue }
                messageCount += 1
                guard firstHit == nil else { continue }
                // The captured search rows show the whole matched message:
                // whitespace folded, inline Markdown resolved. Short messages
                // stay short, long ones run many lines, and the "…" they show
                // belong to the messages themselves.
                let normalized = ConversationOutlineRowContentMaker.preview(part.text)
                guard !normalized.isEmpty else { continue }
                let attributed = ConversationOutlineRowContentMaker.markdownTitle(normalized)
                firstHit = ConversationOutlineSearchHit(
                    entryID: entry.id,
                    partID: part.id,
                    snippet: String(attributed.characters),
                    snippetAttributed: attributed
                )
            }
            if let firstHit { hits.append(firstHit) }
        }
        return ConversationOutlineSearchResult(hits: hits, messageCount: messageCount)
    }

    static func filter(
        _ entries: [ConversationOutlineEntry],
        query: String,
        locale: Locale = .current
    ) -> [ConversationOutlineSearchHit] {
        search(entries, query: query, locale: locale).hits
    }

    /// The count line's numerator: matching **messages**, not rows. The
    /// official line reads "已显示 22/72 条消息" where 22 can exceed the
    /// number of visible rows because one row holds several messages.
    static func matchingMessageCount(
        _ entries: [ConversationOutlineEntry],
        query: String,
        locale: Locale = .current
    ) -> Int {
        search(entries, query: query, locale: locale).messageCount
    }
}

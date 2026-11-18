import Foundation

/// One entry that matches the query, with the message a tap should open and the
/// excerpt to show in the row.
nonisolated struct ConversationOutlineSearchHit: Equatable {
    let entryID: V2TimelineItemID
    let partID: V2TimelineItemID
    let snippet: String
}

/// Outline search: case- and diacritic-insensitive substring matching over the
/// already-built rows. The official app folds both sides the same way and shows
/// an excerpt around the first hit — no highlight colour (that branch is dead
/// code in the official build).
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
        locale: Locale = .current,
        maxSnippetLength: Int = 140
    ) -> ConversationOutlineSearchHit? {
        let tokens = tokens(query)
        guard !tokens.isEmpty else { return nil }
        let foldedTokens = tokens.map { folded($0, locale: locale) }
        for part in entry.parts {
            let foldedText = folded(part.text, locale: locale)
            guard foldedTokens.allSatisfy({ foldedText.contains($0) }) else { continue }
            return ConversationOutlineSearchHit(
                entryID: entry.id,
                partID: part.id,
                snippet: snippet(in: part.text, tokens: tokens, locale: locale, maxLength: maxSnippetLength)
            )
        }
        return nil
    }

    static func filter(
        _ entries: [ConversationOutlineEntry],
        query: String,
        locale: Locale = .current
    ) -> [ConversationOutlineSearchHit] {
        guard !tokens(query).isEmpty else { return [] }
        return entries.compactMap { hit(in: $0, query: query, locale: locale) }
    }

    /// The excerpt around the first token occurrence, with an ellipsis on each
    /// side that was trimmed.
    static func snippet(
        in text: String,
        tokens: [String],
        locale: Locale = .current,
        maxLength: Int = 140
    ) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        guard maxLength > 0 else { return trimmed }
        let characters = Array(trimmed)
        guard characters.count > maxLength else { return trimmed }

        let range = tokens
            .lazy
            .compactMap { trimmed.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive], locale: locale) }
            .min { $0.lowerBound < $1.lowerBound }
        let matchStart = range.map { trimmed.distance(from: trimmed.startIndex, to: $0.lowerBound) } ?? 0
        let matchLength = range.map { trimmed.distance(from: $0.lowerBound, to: $0.upperBound) } ?? 0

        let context = max(0, (maxLength - matchLength) / 2)
        var start = max(0, matchStart - context)
        var end = min(characters.count, start + maxLength)
        if end - start < maxLength {
            start = max(0, end - maxLength)
            end = min(characters.count, start + maxLength)
        }
        let prefix = start > 0 ? "…" : ""
        let suffix = end < characters.count ? "…" : ""
        return prefix + String(characters[start..<end]) + suffix
    }
}

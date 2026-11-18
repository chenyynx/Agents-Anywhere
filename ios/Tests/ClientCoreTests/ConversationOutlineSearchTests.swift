import Foundation
import Testing
@testable import ClientCore

@Suite("Conversation outline search")
struct ConversationOutlineSearchTests {
    private func entry(
        id: String = "e1",
        sender: V2MessageRole = .assistant,
        text: String,
        parts: [(String, String)]? = nil
    ) -> ConversationOutlineEntry {
        let pairs = parts ?? [(id + "-part", text)]
        return ConversationOutlineEntry(
            id: id,
            sender: sender,
            text: text,
            parts: pairs.map {
                ConversationOutlineEntry.Part(id: $0.0, text: $0.1, createdAt: nil, isActive: false)
            },
            isArriving: false,
            sentAt: nil,
            attachmentCount: 0
        )
    }

    @Test("case and diacritics are ignored on both sides")
    func caseAndDiacritics() {
        let row = entry(text: "Café au lait")
        #expect(ConversationOutlineSearch.hit(in: row, query: "CAFE") != nil)
        #expect(ConversationOutlineSearch.hit(in: row, query: "cafe au") != nil)
        #expect(ConversationOutlineSearch.hit(in: row, query: "tea") == nil)
    }

    @Test("Chinese substrings match without tokenisation")
    func chineseSubstring() {
        let row = entry(text: "在的，Bung Jin。有什么需要帮忙的？")
        #expect(ConversationOutlineSearch.hit(in: row, query: "需要帮忙") != nil)
        #expect(ConversationOutlineSearch.hit(in: row, query: "不在") == nil)
    }

    @Test("every token must appear in the same message part")
    func allTokensMustMatchOnePart() {
        let row = entry(
            text: "alpha\nbeta",
            parts: [("p1", "alpha only"), ("p2", "beta only")]
        )
        #expect(ConversationOutlineSearch.hit(in: row, query: "alpha beta") == nil)
        #expect(ConversationOutlineSearch.hit(in: row, query: "alpha only")?.partID == "p1")
    }

    @Test("the hit points at the part that matched")
    func hitUsesMatchingPart() {
        let row = entry(
            text: "first\nsecond hit",
            parts: [("p1", "first"), ("p2", "second hit")]
        )
        let hit = ConversationOutlineSearch.hit(in: row, query: "hit")
        #expect(hit?.partID == "p2")
        #expect(hit?.snippet == "second hit")
    }

    @Test("the excerpt resolves inline Markdown and folds whitespace")
    func excerptResolvesMarkdown() throws {
        let row = entry(text: "line one\nline two **证据**（已验证）：`code` tail")
        let hit = try #require(ConversationOutlineSearch.hit(in: row, query: "证据"))
        let snippet = hit.snippet
        #expect(!snippet.contains("**"))
        #expect(!snippet.contains("`"))
        #expect(!snippet.contains("\n"))
        #expect(snippet.contains("证据"))
        #expect(String(hit.snippetAttributed.characters) == hit.snippet)
        let hasBold = hit.snippetAttributed.runs.contains { run in
            run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
        }
        #expect(hasBold)
    }

    @Test("the search preview is the whole matched message, not a window")
    func wholeMessagePreview() {
        let prefix = String(repeating: "a", count: 300)
        let suffix = String(repeating: "b", count: 300)
        let row = entry(text: prefix + " needle " + suffix)
        let hit = ConversationOutlineSearch.hit(in: row, query: "needle")
        #expect(hit?.snippet == prefix + " needle " + suffix)
        #expect(hit?.snippet.contains("…") == false)
    }

    @Test("surrounding blank lines do not collapse the excerpt to an ellipsis")
    func excerptIgnoresBlankLines() {
        let row = entry(text: "\n\n  target text  \n")
        #expect(ConversationOutlineSearch.hit(in: row, query: "target")?.snippet == "target text")
    }

    @Test("the count line counts matching messages, not rows")
    func matchingMessageCountCountsParts() {
        let first = entry(
            id: "e1",
            text: "alpha\nBeta",
            parts: [("p1", "alpha one"), ("p2", "Beta two"), ("p3", "gamma")]
        )
        let second = entry(id: "e2", text: "beta", parts: [("p4", "beta three")])
        #expect(ConversationOutlineSearch.matchingMessageCount([first, second], query: "beta") == 2)
        #expect(ConversationOutlineSearch.matchingMessageCount([first, second], query: "alpha") == 1)
        #expect(ConversationOutlineSearch.matchingMessageCount([first, second], query: "zzz") == 0)
        #expect(ConversationOutlineSearch.matchingMessageCount([first, second], query: "   ") == 4)
    }

    @Test("the count line can exceed the rendered rows")
    func countCanExceedRows() {
        let multi = entry(
            id: "e3",
            text: "beta one\nbeta two",
            parts: [("p5", "beta one"), ("p6", "beta two")]
        )
        let result = ConversationOutlineSearch.search([multi], query: "beta")
        #expect(result.messageCount == 2)
        #expect(result.hits.count == 1)
        #expect(result.hits.first?.partID == "p5")
    }

    @Test("empty query filters nothing")
    func emptyQuery() {
        let rows = [entry(id: "e1", text: "one"), entry(id: "e2", text: "two")]
        #expect(ConversationOutlineSearch.filter(rows, query: "   ").isEmpty)
        #expect(ConversationOutlineSearch.filter(rows, query: "one").map { $0.entryID } == ["e1"])
    }
}

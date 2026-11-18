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

    @Test("long text produces an excerpt with ellipses")
    func snippetTrimsBothSides() {
        let prefix = String(repeating: "a", count: 200)
        let suffix = String(repeating: "b", count: 200)
        let row = entry(text: prefix + " needle " + suffix)
        let snippet = ConversationOutlineSearch.hit(in: row, query: "needle", maxSnippetLength: 120)?.snippet ?? ""
        #expect(snippet.contains("needle"))
        #expect(snippet.hasPrefix("…"))
        #expect(snippet.hasSuffix("…"))
        #expect(snippet.count <= 122)
    }

    @Test("empty query filters nothing")
    func emptyQuery() {
        let rows = [entry(id: "e1", text: "one"), entry(id: "e2", text: "two")]
        #expect(ConversationOutlineSearch.filter(rows, query: "   ").isEmpty)
        #expect(ConversationOutlineSearch.filter(rows, query: "one").map { $0.entryID } == ["e1"])
    }
}

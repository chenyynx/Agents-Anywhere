import Foundation
import Testing
@testable import ClientCore

@Suite("Conversation outline row content cache")
struct ConversationOutlineRowContentCacheTests {
    private func entry(
        id: String = "e1",
        text: String = "Hello"
    ) -> ConversationOutlineEntry {
        ConversationOutlineEntry(
            id: id,
            sender: .assistant,
            text: text,
            parts: [
                ConversationOutlineEntry.Part(
                    id: id, text: text, createdAt: nil, isActive: false),
            ],
            isArriving: false,
            sentAt: nil,
            attachmentCount: 0
        )
    }

    private func makeContent(
        _ entry: ConversationOutlineEntry
    ) -> ConversationOutlineRowContent {
        ConversationOutlineRowContentMaker.content(for: entry, hit: nil, strings: .init())
    }

    @Test("an unchanged entry reuses the cached content")
    func reusesUnchangedEntry() {
        let cache = ConversationOutlineRowContentCache()
        var builds = 0
        func make(_ entry: ConversationOutlineEntry) -> ConversationOutlineRowContent {
            builds += 1
            return makeContent(entry)
        }

        let first = cache.content(for: entry(), make: make)
        let second = cache.content(for: entry(), make: make)

        #expect(builds == 1)
        #expect(first == second)
        #expect(cache.count == 1)
    }

    @Test("a changed entry is rebuilt")
    func rebuildsChangedEntry() {
        let cache = ConversationOutlineRowContentCache()
        var builds = 0
        func make(_ entry: ConversationOutlineEntry) -> ConversationOutlineRowContent {
            builds += 1
            return makeContent(entry)
        }

        let first = cache.content(for: entry(text: "Hello"), make: make)
        let second = cache.content(for: entry(text: "Hello, again"), make: make)

        #expect(builds == 2)
        #expect(first.title != second.title)
    }

    @Test("pruning drops rows that left and keeps the survivors cached")
    func prunesDepartedRows() {
        let cache = ConversationOutlineRowContentCache()
        var builds = 0
        func make(_ entry: ConversationOutlineEntry) -> ConversationOutlineRowContent {
            builds += 1
            return makeContent(entry)
        }

        _ = cache.content(for: entry(id: "a"), make: make)
        _ = cache.content(for: entry(id: "b"), make: make)
        #expect(cache.count == 2)

        cache.retain(ids: ["a"])
        #expect(cache.count == 1)

        builds = 0
        _ = cache.content(for: entry(id: "a"), make: make)
        #expect(builds == 0)
        _ = cache.content(for: entry(id: "b"), make: make)
        #expect(builds == 1)
    }
}

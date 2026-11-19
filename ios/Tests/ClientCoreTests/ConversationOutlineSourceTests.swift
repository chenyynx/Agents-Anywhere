import Foundation
import Testing
@testable import ClientCore

@Suite("Conversation outline data source")
@MainActor
struct ConversationOutlineSourceTests {
    private func message(
        id: String,
        turn: String? = nil,
        role: String = "assistant",
        text: String,
        orderSeq: Int,
        status: String = "done"
    ) throws -> V2TimelineItem {
        var source: [String: JSONValue] = [:]
        if let turn { source["turnId"] = .string(turn) }
        return try V2TimelineItem(json: .object([
            "id": .string(id),
            "sessionId": .string("s"),
            "type": .string("message"),
            "status": .string(status),
            "role": .string(role),
            "content": .object(["text": .string(text)]),
            "source": .object(source),
            "orderSeq": .number(Double(orderSeq)),
            "createdAt": .string("2026-11-18T04:04:00Z"),
        ]))
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("aa-outline-source-\(UUID().uuidString)", isDirectory: true)
    }

    @Test("the loaded window wins over its cached copy")
    func liveRowWinsOverCachedCopy() throws {
        let cached = try message(id: "m1", text: "stale", orderSeq: 1, status: "running")
        let live = try message(id: "m1", text: "fresh", orderSeq: 1)
        let merged = ConversationOutlineSource.merged(live: [live], cached: [cached])
        #expect(merged.count == 1)
        #expect(merged[0].displayText == "fresh")
        #expect(merged[0].status == .done)
    }

    @Test("cached rows outside the window extend the outline")
    func mergedRowsBuildEntriesAcrossTheWindowBoundary() throws {
        let cached = [
            try message(id: "m1", turn: "t1", role: "user", text: "old", orderSeq: 1),
            try message(id: "m2", turn: "t1", text: "old reply", orderSeq: 2),
        ]
        let live = [
            try message(id: "m3", turn: "t2", role: "user", text: "new", orderSeq: 3),
        ]
        let entries = ConversationOutlineEntryBuilder.entries(
            from: ConversationOutlineSource.merged(live: live, cached: cached))
        #expect(entries.map(\.id) == ["m1", "m2", "m3"])
        #expect(entries.map(\.text) == ["old", "old reply", "new"])
    }

    @Test("the store returns its newest cached rows in timeline order")
    func storeReadsTheNewestCachedRows() async throws {
        let rawItems = try (1...20).map { try itemObject(id: "item-\($0)", order: $0, seq: $0) }
        let projection = V2SessionProjection(
            snapshot: try snapshot(items: rawItems), maximumItems: 20)
        let probe = repository(transport: TestHTTPTransport())
        let archive = V2SessionArchive(data: projection.data, model: probe.session(id: "session"))
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let writer = V2LocalStore(directory: directory, maximumSessions: 20,
                                  timelineDatabaseEnabled: true)
        await writer.saveSession(archive)
        await writer.close(removing: false)

        let reader = V2LocalStore(directory: directory, maximumSessions: 20,
                                  timelineDatabaseEnabled: true)
        let all = await reader.outlineItems(sessionID: "session", limit: 5000,
                                            byteBudget: .max)
        let newest = await reader.outlineItems(sessionID: "session", limit: 5,
                                               byteBudget: .max)
        await reader.close(removing: false)

        let items = try #require(all)
        #expect(items.map(\.id) == (1...20).map { "item-\($0)" })
        let window = try #require(newest)
        #expect(window.map(\.id) == (16...20).map { "item-\($0)" })
    }

    @Test("a store without the row database contributes nothing")
    func disabledStoreHasNoOutlineRows() async throws {
        let rawItems = try [itemObject(id: "item-1", order: 1, seq: 1)]
        let projection = V2SessionProjection(
            snapshot: try snapshot(items: rawItems), maximumItems: 1)
        let probe = repository(transport: TestHTTPTransport())
        let archive = V2SessionArchive(data: projection.data, model: probe.session(id: "session"))
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = V2LocalStore(directory: directory, maximumSessions: 20,
                                 timelineDatabaseEnabled: false)
        await store.saveSession(archive)
        let items = await store.outlineItems(sessionID: "session", limit: 100,
                                             byteBudget: .max)
        await store.close(removing: false)
        #expect(items == nil)
    }
}

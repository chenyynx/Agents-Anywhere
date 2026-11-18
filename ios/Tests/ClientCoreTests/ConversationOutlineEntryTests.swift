import Foundation
import Testing
@testable import ClientCore

@Suite("Conversation outline entry building")
struct ConversationOutlineEntryTests {
    private func message(
        id: String,
        turn: String? = "t1",
        role: String = "assistant",
        text: String,
        orderSeq: Int,
        status: String = "done",
        attachments: Int = 0,
        parentItemId: String? = nil
    ) throws -> V2TimelineItem {
        var content: [String: JSONValue] = ["text": .string(text)]
        if attachments > 0 {
            content["attachments"] = .array((0..<attachments).map { .object(["name": .string("file\($0)")]) })
        }
        if let parentItemId { content["parentItemId"] = .string(parentItemId) }
        var source: [String: JSONValue] = [:]
        if let turn { source["turnId"] = .string(turn) }
        return try V2TimelineItem(json: .object([
            "id": .string(id),
            "sessionId": .string("s"),
            "type": .string("message"),
            "status": .string(status),
            "role": .string(role),
            "content": .object(content),
            "source": .object(source),
            "orderSeq": .number(Double(orderSeq)),
            "createdAt": .string("2026-11-18T04:04:00Z"),
        ]))
    }

    @Test("adjacent messages of one turn and sender merge into one row")
    func mergesSameTurnSameRole() throws {
        let items = [
            try message(id: "m3", role: "assistant", text: "B", orderSeq: 3),
            try message(id: "m1", role: "user", text: "hello", orderSeq: 1),
            try message(id: "m4", role: "user", turn: "t2", text: "next", orderSeq: 4),
            try message(id: "m2", role: "assistant", text: "A", orderSeq: 2),
        ]
        let entries = ConversationOutlineEntryBuilder.entries(from: items)
        #expect(entries.count == 3)
        #expect(entries[0].sender == .user)
        #expect(entries[0].text == "hello")
        #expect(entries[1].sender == .assistant)
        #expect(entries[1].text == "A\nB")
        #expect(entries[1].parts.map(\.id) == ["m2", "m3"])
        #expect(entries[1].id == "m2")
        #expect(entries[2].text == "next")
    }

    @Test("same sender in different turns stays separate")
    func doesNotMergeAcrossTurns() throws {
        let items = [
            try message(id: "m1", turn: "t1", text: "one", orderSeq: 1),
            try message(id: "m2", turn: "t2", text: "two", orderSeq: 2),
        ]
        let entries = ConversationOutlineEntryBuilder.entries(from: items)
        #expect(entries.map(\.id) == ["m1", "m2"])
    }

    @Test("messages without a turn id never merge")
    func missingTurnNeverMerges() throws {
        let items = [
            try message(id: "m1", turn: nil, text: "one", orderSeq: 1),
            try message(id: "m2", turn: nil, text: "two", orderSeq: 2),
        ]
        #expect(ConversationOutlineEntryBuilder.entries(from: items).count == 2)
    }

    @Test("subagent rows and non-message rows are excluded")
    func excludesSubagentsAndNonMessages() throws {
        let subagent = try message(id: "m2", text: "child", orderSeq: 2, parentItemId: "card")
        let tool = try V2TimelineItem(json: .object([
            "id": .string("m3"),
            "sessionId": .string("s"),
            "type": .string("tool"),
            "status": .string("done"),
            "content": .object(["kind": .string("tool"), "name": .string("Bash")]),
            "orderSeq": .number(3),
        ]))
        let items = [try message(id: "m1", text: "main", orderSeq: 1), subagent, tool]
        let entries = ConversationOutlineEntryBuilder.entries(from: items)
        #expect(entries.map(\.id) == ["m1"])
    }

    @Test("attachments are counted across the merged parts")
    func sumsAttachments() throws {
        let items = [
            try message(id: "m1", role: "user", text: "", orderSeq: 1, attachments: 2),
            try message(id: "m2", role: "user", text: "caption", orderSeq: 2, attachments: 1),
        ]
        let entries = ConversationOutlineEntryBuilder.entries(from: items)
        #expect(entries.count == 1)
        #expect(entries[0].attachmentCount == 3)
        #expect(entries[0].text == "caption")
    }

    @Test("active status marks the merged row as arriving")
    func marksArriving() throws {
        let items = [
            try message(id: "m1", text: "first", orderSeq: 1, status: "done"),
            try message(id: "m2", text: "second", orderSeq: 2, status: "running"),
        ]
        let entries = ConversationOutlineEntryBuilder.entries(from: items)
        #expect(entries.count == 1)
        #expect(entries[0].isArriving)
    }

    @Test("ordering follows orderSeq with the id as the tie-break")
    func orderIsStable() throws {
        let items = [
            try message(id: "b", turn: "t2", text: "second", orderSeq: 2),
            try message(id: "a", turn: "t1", text: "first", orderSeq: 2),
        ]
        #expect(ConversationOutlineEntryBuilder.entries(from: items).map(\.id) == ["a", "b"])
    }
}

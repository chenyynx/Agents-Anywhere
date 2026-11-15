import Foundation
import Testing
@testable import ClientCore

// The Code page's user-attachment wire mapping. The official user message
// draws its text bubble first and its attachments after it, as sibling
// blocks outside the bubble (CLOSURE.md §4). These tests pin the builder's
// block order, the pure-attachment case, and the per-file dedup rule without
// UIKit; the height side is pinned in `CodeRowHeightPlanTests`.

private func attachment(_ id: String? = nil, name: String = "file.png",
                        mediaType: String = "image/png",
                        width: Int? = nil, height: Int? = nil) -> [String: Any] {
    var value: [String: Any] = ["name": name, "mediaType": mediaType]
    if let id { value["fileId"] = id }
    if let width { value["width"] = width }
    if let height { value["height"] = height }
    return value
}

private func makeBody(id: String, order: Int, message: String, text: String,
                      role: String = "user",
                      attachments: [[String: Any]] = [],
                      clientMessageID: String? = nil) throws -> V2TimelineItem {
    var content: [String: Any] = ["text": text]
    if !attachments.isEmpty { content["attachments"] = attachments }
    var source: [String: Any] = ["itemId": message]
    if let clientMessageID { source["clientMessageId"] = clientMessageID }
    return try decode([
        "id": id, "sessionId": "session", "type": "message", "status": "done",
        "role": role, "content": content, "source": source,
        "orderSeq": order, "revision": 1, "updatedSeq": order, "contentHash": id,
    ])
}

private func descriptor(_ block: CodeMessageRow.Block) -> String {
    switch block {
    case let .reasoning(id, _, _, _): return "reasoning:\(id)"
    case let .text(id, _): return "text:\(id)"
    case let .attachments(id, _, _): return "attachments:\(id)"
    case .toolCalls: return "toolCalls"
    case let .other(id, _): return "other:\(id)"
    }
}

/// The files and correlation id of the `.attachments` block at `index`.
private func attachmentBlock(
    _ blocks: [CodeMessageRow.Block], at index: Int
) -> (files: [V2AttachmentContent], clientMessageID: String?)? {
    guard blocks.indices.contains(index),
          case let .attachments(_, files, clientMessageID) = blocks[index] else {
        return nil
    }
    return (files, clientMessageID)
}

@Suite("Code user attachments")
struct CodeMessageTimelineTests {
    @Test func attachmentsPrecedeTheTextBubble() throws {
        let body = try makeBody(
            id: "m1", order: 1, message: "msg-1", text: "hello",
            attachments: [attachment("f1"),
                          attachment("f2", name: "b.pdf", mediaType: "application/pdf")])
        let rows = CodeMessageBuilder.rows(for: [body], profile: .claudeCode)

        #expect(rows.count == 1)
        #expect(rows[0].role == .user)
        #expect(rows[0].blocks.map(descriptor) == ["attachments:m1", "text:m1"])
        #expect(attachmentBlock(rows[0].blocks, at: 0)?.files.compactMap(\.fileId) == ["f1", "f2"])
    }

    @Test func aPureAttachmentMessageKeepsItsRow() throws {
        // No text at all: the attachments are followed by an empty `.text`
        // block (the renderer drops it), and the attachments keep the row
        // alive instead of `guard !blocks.isEmpty` discarding it.
        let body = try makeBody(id: "m1", order: 1, message: "msg-1", text: "",
                                attachments: [attachment("f1")])
        let rows = CodeMessageBuilder.rows(for: [body], profile: .claudeCode)

        #expect(rows.count == 1)
        #expect(rows[0].blocks.map(descriptor) == ["attachments:m1", "text:m1"])
        #expect(attachmentBlock(rows[0].blocks, at: 0)?.files.count == 1)
    }

    @Test func multipleBodiesKeepAttachmentsThenTextOrder() throws {
        let first = try makeBody(id: "m1", order: 1, message: "msg-1", text: "one",
                                 attachments: [attachment("f1")])
        let second = try makeBody(id: "m2", order: 2, message: "msg-1", text: "two",
                                  attachments: [attachment("f2")])
        let rows = CodeMessageBuilder.rows(for: [first, second], profile: .claudeCode)

        #expect(rows.count == 1)
        #expect(rows[0].blocks.map(descriptor) ==
            ["attachments:m1", "text:m1", "attachments:m2", "text:m2"])
        #expect(attachmentBlock(rows[0].blocks, at: 0)?.files.compactMap(\.fileId) == ["f1"])
        #expect(attachmentBlock(rows[0].blocks, at: 2)?.files.compactMap(\.fileId) == ["f2"])
    }

    @Test func duplicateFilesDrawOnceAtTheirFirstBody() throws {
        let first = try makeBody(id: "m1", order: 1, message: "msg-1", text: "one",
                                 attachments: [attachment("f1")])
        let second = try makeBody(id: "m2", order: 2, message: "msg-1", text: "two",
                                  attachments: [attachment("f1")])
        let rows = CodeMessageBuilder.rows(for: [first, second], profile: .claudeCode)

        #expect(rows[0].blocks.map(descriptor) == ["attachments:m1", "text:m1", "text:m2"])
    }

    @Test func duplicateFilesInsideOneBodyDrawOnce() throws {
        let body = try makeBody(id: "m1", order: 1, message: "msg-1", text: "one",
                                attachments: [attachment("f1"),
                                              attachment("f1", name: "renamed.png")])
        let rows = CodeMessageBuilder.rows(for: [body], profile: .claudeCode)

        #expect(attachmentBlock(rows[0].blocks, at: 0)?.files.compactMap(\.fileId) == ["f1"])
    }

    @Test func filesWithoutAFileIDDeduplicateByCacheKey() throws {
        // Before upload an attachment has no server id; the cache key (the raw
        // payload identity) is the fallback dedup key.
        let body = try makeBody(id: "m1", order: 1, message: "msg-1", text: "one",
                                attachments: [attachment(nil, name: "x.png"),
                                              attachment(nil, name: "x.png")])
        let rows = CodeMessageBuilder.rows(for: [body], profile: .claudeCode)

        #expect(attachmentBlock(rows[0].blocks, at: 0)?.files.count == 1)
    }

    @Test func assistantAttachmentsAreNotDrawnAsAUserGrid() throws {
        // The official attachment block belongs to the user row
        // (CLOSURE.md §4); an assistant message's attachment payload must not
        // inherit the user tile layout.
        let body = try makeBody(id: "m1", order: 1, message: "msg-1", text: "done",
                                role: "assistant", attachments: [attachment("f1")])
        let rows = CodeMessageBuilder.rows(for: [body], profile: .claudeCode)

        #expect(rows[0].blocks.map(descriptor) == ["text:m1"])
    }

    @Test func theAttachmentBlockCarriesTheSendCorrelationID() throws {
        let body = try makeBody(id: "m1", order: 1, message: "msg-1", text: "one",
                                attachments: [attachment("f1")],
                                clientMessageID: "client-1")
        let rows = CodeMessageBuilder.rows(for: [body], profile: .claudeCode)

        #expect(attachmentBlock(rows[0].blocks, at: 0)?.clientMessageID == "client-1")
    }
}

@Suite("Code child rows for the sub-agent panel")
struct CodeMessageChildRowTests {
    /// A sub-agent child body row: the connector attributes it to the Agent
    /// card with `content.parentItemId`, which the main timeline filters out.
    private func childText() throws -> V2TimelineItem {
        try decode([
            "id": "c1", "sessionId": "session", "type": "message",
            "status": "done", "role": "assistant",
            "content": ["text": "child body", "parentItemId": "card-1"],
            "source": ["itemId": "child-msg-1"],
            "orderSeq": 1, "revision": 1, "updatedSeq": 1, "contentHash": "c1",
        ])
    }

    @Test func childRowsRequireThePanelOptIn() throws {
        let child = try childText()
        #expect(CodeMessageBuilder.rows(for: [child], profile: .generic).isEmpty)

        let rows = CodeMessageBuilder.rows(for: [child], profile: .generic,
                                           includeSubAgentChildren: true)
        #expect(rows.count == 1)
        #expect(rows.first?.blocks.map(descriptor) == ["text:c1"])

        // The Claude profile takes the cross-message merge path; the panel's
        // main runtime must keep the same opt-in behaviour there.
        #expect(CodeMessageBuilder.rows(for: [child], profile: .claudeCode).isEmpty)
        let claudeRows = CodeMessageBuilder.rows(for: [child], profile: .claudeCode,
                                                 includeSubAgentChildren: true)
        #expect(claudeRows.count == 1)
        #expect(claudeRows.first?.blocks.map(descriptor) == ["text:c1"])
    }
}

@Suite("Code rows without a declared message key")
struct CodeKeylessRowGroupingTests {
    /// A body row without `source.itemId` / `nativeMessageId` used to be a
    /// standalone row drawn by the retired Chat renderer. The builder now
    /// falls back to the row's own id, so the Code row draws it instead.
    private func keylessBody() throws -> V2TimelineItem {
        try decode([
            "id": "legacy-body", "sessionId": "session", "type": "message",
            "status": "done", "role": "assistant",
            "content": ["text": "Hello"], "source": [String: Any](),
            "orderSeq": 1, "revision": 1, "updatedSeq": 1, "contentHash": "legacy-body",
        ])
    }

    /// A tool row without a declared key. It used to fall to the retired Chat
    /// row; the builder must keep it in a Code unit (a span on the merge path,
    /// a message unit on the legacy path).
    private func keylessTool() throws -> V2TimelineItem {
        try decode([
            "id": "legacy-tool", "sessionId": "session", "type": "tool",
            "status": "done",
            "content": ["kind": "command", "command": "ls"],
            "source": [String: Any](),
            "orderSeq": 2, "revision": 1, "updatedSeq": 2, "contentHash": "legacy-tool",
        ])
    }

    /// A reasoning row without a key keeps its own Code row too (a message
    /// unit keyed by the row id), so the thinking block renders in the current
    /// style instead of the retired Chat fold.
    private func keylessReasoning(status: String = "done") throws -> V2TimelineItem {
        try decode([
            "id": "legacy-think", "sessionId": "session", "type": "reasoning",
            "status": status,
            "content": ["text": "hmm"], "source": [String: Any](),
            "orderSeq": 4, "revision": 1, "updatedSeq": 4, "contentHash": "legacy-think",
        ])
    }

    /// A compact marker is not stackable: it stays its own standalone unit and
    /// keeps the divider.
    private func compactMarker() throws -> V2TimelineItem {
        try decode([
            "id": "compact", "sessionId": "session", "type": "system",
            "status": "done",
            "content": ["kind": "compact", "state": "completed"],
            "source": [String: Any](),
            "orderSeq": 3, "revision": 1, "updatedSeq": 3, "contentHash": "compact",
        ])
    }

    @Test func aBodyWithoutADeclaredKeyKeepsItsCodeRow() throws {
        for profile in [CodeRuntimeProfile.claudeCode, .generic] {
            let units = CodeMessageBuilder.units(for: [try keylessBody()], profile: profile)
            #expect(units.count == 1)
            guard case let .message(key, items) = units[0] else {
                Issue.record("expected a message unit for \(profile.family)")
                continue
            }
            #expect(key == "legacy-body")
            #expect(items.map(\.id) == ["legacy-body"])
        }
    }

    @Test func aToolWithoutADeclaredKeyStaysInACodeRow() throws {
        for profile in [CodeRuntimeProfile.claudeCode, .generic] {
            let units = CodeMessageBuilder.units(for: [try keylessTool()], profile: profile)
            #expect(units.count == 1)
            if case .standalone = units[0] {
                Issue.record("keyless tool fell back to a standalone row for \(profile.family)")
            }
            #expect(units[0].items.map(\.id) == ["legacy-tool"])
        }
    }

    @Test func aReasoningRowWithoutADeclaredKeyKeepsItsCodeRow() throws {
        for profile in [CodeRuntimeProfile.claudeCode, .generic] {
            let units = CodeMessageBuilder.units(for: [try keylessReasoning()], profile: profile)
            #expect(units.count == 1)
            if case .standalone = units[0] {
                Issue.record("keyless reasoning fell back to a standalone row for \(profile.family)")
            }
            #expect(units[0].items.map(\.id) == ["legacy-think"])
        }
    }

    @Test func aRunningKeylessReasoningKeepsAStandaloneLine() throws {
        // The Code builder draws only settled reasoning; a running/failed
        // keyless row must stay standalone so the fallback can draw its line
        // instead of the unit disappearing.
        for profile in [CodeRuntimeProfile.claudeCode, .generic] {
            let units = CodeMessageBuilder.units(for: [try keylessReasoning(status: "running")],
                                                 profile: profile)
            #expect(units.count == 1)
            guard case .standalone = units[0] else {
                Issue.record("running keyless reasoning left the standalone path for \(profile.family)")
                continue
            }
        }
    }

    @Test func aStandaloneKeylessReasoningBuildsOnlyTheGenericBlock() throws {
        // The view treats an `.other`-only row as undrawable and keeps its
        // marker line; this pins the builder premise that rule reads.
        let rows = CodeMessageBuilder.rows(for: [try keylessReasoning(status: "running")],
                                           profile: .claudeCode)
        #expect(rows.count == 1)
        #expect(rows[0].blocks.count == 1)
        if case .other = rows[0].blocks[0] {} else {
            Issue.record("expected the builder's generic placeholder block")
        }
    }

    @Test func aCompactMarkerStaysStandalone() throws {
        for profile in [CodeRuntimeProfile.claudeCode, .generic] {
            let units = CodeMessageBuilder.units(for: [try compactMarker()], profile: profile)
            #expect(units.count == 1)
            guard case let .standalone(item) = units[0] else {
                Issue.record("expected a standalone compact marker for \(profile.family)")
                continue
            }
            #expect(item.id == "compact")
        }
    }
}

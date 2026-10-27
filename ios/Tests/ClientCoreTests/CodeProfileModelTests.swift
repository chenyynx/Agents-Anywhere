import Foundation
import Testing
@testable import ClientCore

// W1: the Code page's pure model. The grouping rules are the official client
// rule (CANONICAL/04-tool-calls.md §3) and the row model is derived from the
// server's declared message grouping (`nativeMessageId` / `itemId` + RBT
// order), so both are tested here without UIKit.

private func makeItem(id: String, order: Int, type: String = "message",
                      role: String? = "assistant", status: String = "done",
                      content: [String: Any] = [:], source: [String: Any] = [:]) throws -> V2TimelineItem {
    var object: [String: Any] = [
        "id": id, "sessionId": "session", "type": type, "status": status,
        "content": content, "source": source, "orderSeq": order,
        "revision": 1, "updatedSeq": order, "contentHash": id,
    ]
    if let role { object["role"] = role }
    return try decode(object)
}

private func makeBody(id: String, order: Int, message: String, text: String = "body",
                      role: String = "assistant") throws -> V2TimelineItem {
    try makeItem(id: id, order: order, role: role, content: ["text": text],
                 source: ["itemId": message])
}

private func makeReasoning(id: String, order: Int, message: String,
                           text: String = "thinking") throws -> V2TimelineItem {
    try makeItem(id: id, order: order, type: "reasoning", content: ["text": text],
                 source: ["itemId": message])
}

private func makeToolItem(id: String, order: Int, message: String? = "msg-1",
                          blockIndex: Int? = 0, name: String = "Read",
                          parentItemId: String? = nil,
                          status: String = "done") throws -> V2TimelineItem {
    var content: [String: Any] = ["kind": "tool", "toolName": name]
    if let parentItemId { content["parentItemId"] = parentItemId }
    var source: [String: Any] = ["itemId": id]
    if let message { source["nativeMessageId"] = message }
    if let blockIndex { source["blockIndex"] = blockIndex }
    return try makeItem(id: id, order: order, type: "tool", status: status,
                        content: content, source: source)
}

private func makeCall(_ name: String, id: String = "call", order: Int = 1,
                      blockIndex: Int? = 0, status: String = "done") throws -> CodeToolCall {
    CodeToolCall(item: try makeToolItem(id: id, order: order, blockIndex: blockIndex,
                                        name: name, status: status))
}

/// Segment sequence in a form that keeps both the kind and the call order.
private func descriptor(_ segment: CodeToolSegment) -> String {
    switch segment {
    case let .span(calls):
        return "span(" + calls.map(\.id).joined(separator: ",") + ")"
    case let .special(kind, call):
        return "special(\(kind),\(call.id))"
    }
}

private func blockDescriptors(_ row: CodeMessageRow) -> [String] {
    row.blocks.map { block in
        switch block {
        case let .reasoning(id, _, _): return "reasoning:\(id)"
        case let .text(id, _): return "text:\(id)"
        case let .attachments(id, _, _): return "attachments:\(id)"
        case let .other(id, _): return "other:\(id)"
        case .toolCalls: return "toolCalls"
        }
    }
}

/// The spans of a row's trailing `.toolCalls` block, each as its call ids.
private func spanIDs(in blocks: [CodeMessageRow.Block]) -> [[String]] {
    guard case let .toolCalls(segments) = blocks.last else { return [] }
    return segments.compactMap { segment in
        guard case let .span(calls) = segment else { return nil }
        return calls.map(\.id)
    }
}

@Suite("Code tool segments")
struct CodeToolSegmentTests {
    @Test func singlePlainCallIsASpanOfOne() throws {
        let segments = CodeToolSegmenter.segments([try makeCall("Read")], policy: .claudeCode)
        #expect(segments.map(descriptor) == ["span(call)"])
    }

    @Test func consecutivePlainCallsGatherIntoOneSpan() throws {
        let calls = [try makeCall("Read", id: "a", order: 1),
                     try makeCall("Grep", id: "b", order: 2),
                     try makeCall("Bash", id: "c", order: 3)]
        let segments = CodeToolSegmenter.segments(calls, policy: .claudeCode)
        #expect(segments.map(descriptor) == ["span(a,b,c)"])
    }

    @Test func tenPlainCallsStillFormOneSpan() throws {
        // The official rule has no count threshold: volume never splits a span.
        let calls = try (0..<10).map { try makeCall("Read", id: "c\($0)", order: $0) }
        let segments = CodeToolSegmenter.segments(calls, policy: .claudeCode)
        #expect(segments.map(descriptor) == ["span(c0,c1,c2,c3,c4,c5,c6,c7,c8,c9)"])
    }

    @Test func aSpecialFlushesTheOpenSpanAndStandsAlone() throws {
        let calls = [try makeCall("Read", id: "a", order: 1),
                     try makeCall("Workflow", id: "w", order: 2),
                     try makeCall("Bash", id: "c", order: 3)]
        let segments = CodeToolSegmenter.segments(calls, policy: .claudeCode)
        #expect(segments.map(descriptor) == ["span(a)", "special(workflow,w)", "span(c)"])
    }

    @Test func consecutiveSpecialsStaySeparateSegmentsInOrder() throws {
        // No empty span is emitted between the two specials, and they keep
        // their call order.
        let calls = [try makeCall("Workflow", id: "w", order: 1),
                     try makeCall("Artifact", id: "a", order: 2)]
        let segments = CodeToolSegmenter.segments(calls, policy: .claudeCode)
        #expect(segments.map(descriptor) == ["special(workflow,w)", "special(artifactCard,a)"])
    }

    @Test func aSpecialAtTheStartLeavesNoEmptySpan() throws {
        let calls = [try makeCall("Workflow", id: "w", order: 1),
                     try makeCall("Read", id: "r", order: 2),
                     try makeCall("Bash", id: "b", order: 3)]
        let segments = CodeToolSegmenter.segments(calls, policy: .claudeCode)
        #expect(segments.map(descriptor) == ["special(workflow,w)", "span(r,b)"])
    }

    @Test func aSpecialAtTheEndFlushesThePrecedingSpan() throws {
        let calls = [try makeCall("Read", id: "r", order: 1),
                     try makeCall("Workflow", id: "w", order: 2)]
        let segments = CodeToolSegmenter.segments(calls, policy: .claudeCode)
        #expect(segments.map(descriptor) == ["span(r)", "special(workflow,w)"])
    }

    @Test func aSkippedCallNeverFlushesTheSpan() throws {
        // ExitPlanMode produces no segment and does not split the span: the
        // official loop `continue`s before the special branch.
        let calls = [try makeCall("Read", id: "a", order: 1),
                     try makeCall("ExitPlanMode", id: "p", order: 2),
                     try makeCall("Bash", id: "c", order: 3)]
        let segments = CodeToolSegmenter.segments(calls, policy: .claudeCode)
        #expect(segments.map(descriptor) == ["span(a,c)"])
    }

    @Test func skippedCallsAtBothEdgesDoNotFlush() throws {
        let calls = [try makeCall("ExitPlanMode", id: "p", order: 1),
                     try makeCall("Read", id: "r", order: 2),
                     try makeCall("AskUserQuestion", id: "q", order: 3)]
        let segments = CodeToolSegmenter.segments(calls, policy: .claudeCode)
        #expect(segments.map(descriptor) == ["span(r)"])
    }

    @Test func onlySkippedCallsProduceNoSegments() throws {
        let calls = [try makeCall("ExitPlanMode", id: "p", order: 1),
                     try makeCall("AskUserQuestion", id: "q", order: 2)]
        #expect(CodeToolSegmenter.segments(calls, policy: .claudeCode).isEmpty)
    }

    @Test func unknownToolsJoinTheSpanUnderTheClaudeTable() throws {
        // The tables are exact matches; an unseen name is plain, never
        // guessed into a special or a skip.
        let calls = [try makeCall("SomeFutureTool", id: "x", order: 1),
                     try makeCall("Read", id: "a", order: 2)]
        let segments = CodeToolSegmenter.segments(calls, policy: .claudeCode)
        #expect(segments.map(descriptor) == ["span(x,a)"])
    }

    @Test func emptyBlockProducesNoSegments() {
        #expect(CodeToolSegmenter.segments([], policy: .claudeCode).isEmpty)
    }

    @Test func theSegmenterWorksOnOneBlockAtATime() throws {
        // Accepted simplification: the builder folds all of a message's tool
        // rows into one `Block.toolCalls` (RBT makes them contiguous), so the
        // page never re-derives the official block boundaries. This test pins
        // the segmenter's per-block contract: two blocks must be segmented
        // separately, never concatenated into one span.
        let first = CodeToolSegmenter.segments(
            [try makeCall("Read", id: "a1", order: 1),
             try makeCall("Grep", id: "a2", order: 2)], policy: .claudeCode)
        let second = CodeToolSegmenter.segments(
            [try makeCall("Bash", id: "b1", order: 3)], policy: .claudeCode)
        #expect(first.map(descriptor) == ["span(a1,a2)"])
        #expect(second.map(descriptor) == ["span(b1)"])
    }

    @Test func runtimeTablesStaySeparate() throws {
        // The Claude table skips its two tools; the Codex table has not seen
        // them, so the same call stays a plain call there.
        let call = try makeCall("ExitPlanMode", id: "p")
        #expect(CodeToolSegmenter.segments([call], policy: .claudeCode).isEmpty)
        #expect(CodeToolSegmenter.segments([call], policy: .codex).map(descriptor) == ["span(p)"])
        // Only name-derived specials are in the table: backgroundTask and
        // threadSessionCard are derived from tool-use/dispatch data, not wire
        // tool names.
        #expect(CodeToolSegmentPolicy.claudeCode.specialToolNames.count == 3)
        #expect(CodeToolSegmentPolicy.claudeCode.specialToolNames["Workflow"] == .workflow)
        #expect(CodeToolSegmentPolicy.claudeCode.specialToolNames["WritingDraft"] == .writingDraft)
        #expect(CodeToolSegmentPolicy.claudeCode.specialToolNames["Artifact"] == .artifactCard)
    }
}

@Suite("Code tool calls")
struct CodeToolCallTests {
    @Test func aCallReadsNameKindStatusAndBlockIndex() throws {
        let call = CodeToolCall(item: try makeToolItem(id: "t1", order: 1, blockIndex: 4,
                                                       name: "Grep", status: "running"))
        #expect(call.id == "t1")
        #expect(call.name == "Grep")
        #expect(call.kind == .search)
        #expect(call.status == .running)
        #expect(call.blockIndex == 4)
        #expect(call.item.id == "t1")
    }

    @Test func anExplicitKindWinsOverTheClassifier() throws {
        // P2-1: W7 constructs calls with the profile's kind; the name
        // classifier must not override an observed runtime mapping.
        let call = CodeToolCall(item: try makeToolItem(id: "t1", order: 1, name: "Read"),
                                kind: .bash)
        #expect(call.name == "Read")
        #expect(call.kind == .bash)
    }

    @Test func aWireKindClassifiesWhenNoNameIsPresent() throws {
        let item = try makeItem(id: "t1", order: 1, type: "tool",
                                content: ["kind": "agent_call"], source: ["itemId": "t1"])
        let call = CodeToolCall(item: item)
        #expect(call.name == "agent_call")
        #expect(call.kind == .task)
        #expect(call.blockIndex == nil)
    }

    @Test func anUnrecognisedShapeIsOtherNotGuessed() throws {
        let item = try makeItem(id: "t1", order: 1, type: "tool",
                                content: [:], source: ["itemId": "t1"])
        let call = CodeToolCall(item: item)
        #expect(call.name == "tool")
        #expect(call.kind == .other)
    }

    @Test func theKindTableCoversObservedNamesAndWireKinds() {
        #expect(CodeToolKind.classify(name: "Read", wireKind: nil) == .read)
        #expect(CodeToolKind.classify(name: "Edit", wireKind: nil) == .edit)
        #expect(CodeToolKind.classify(name: "Write", wireKind: nil) == .write)
        #expect(CodeToolKind.classify(name: "Bash", wireKind: nil) == .bash)
        #expect(CodeToolKind.classify(name: "WebFetch", wireKind: nil) == .search)
        #expect(CodeToolKind.classify(name: "TodoWrite", wireKind: nil) == .todo)
        #expect(CodeToolKind.classify(name: "Task", wireKind: nil) == .task)
        #expect(CodeToolKind.classify(name: "ExitPlanMode", wireKind: nil) == .plan)
        #expect(CodeToolKind.classify(name: "AskUserQuestion", wireKind: nil) == .question)
        #expect(CodeToolKind.classify(name: "whatever", wireKind: "command") == .bash)
        #expect(CodeToolKind.classify(name: "whatever", wireKind: "agent_call") == .task)
        #expect(CodeToolKind.classify(name: "whatever", wireKind: "web_search") == .search)
        #expect(CodeToolKind.classify(name: "whatever", wireKind: "mcp") == .mcp)
        #expect(CodeToolKind.classify(name: "some_future_tool", wireKind: nil) == .other)
    }

    @Test func aKnownNameBeatsACoarseWireKind() {
        // Codex stamps every non-web-search function call `kind: "mcp"`; a
        // name-first lookup is what keeps `update_plan` from staying `.mcp`.
        #expect(CodeToolKind.classify(name: "update_plan", wireKind: "mcp") == .todo)
        #expect(CodeToolKind.classify(name: "Read", wireKind: "mcp") == .read)
        #expect(CodeToolKind.classify(name: "apply_patch", wireKind: "mcp") == .edit)
        // An unknown name still lets the wire kind classify.
        #expect(CodeToolKind.classify(name: "some_future_tool", wireKind: "mcp") == .mcp)
    }

    @Test func statusMappingCollapsesTheWireStates() {
        #expect(CodeToolStatus(.pending) == .running)
        #expect(CodeToolStatus(.running) == .running)
        #expect(CodeToolStatus(.waitingApproval) == .running)
        #expect(CodeToolStatus(.done) == .complete)
        #expect(CodeToolStatus(.failed) == .failed)
        #expect(CodeToolStatus(.cancelled) == .failed)
        #expect(CodeToolStatus(.interrupted) == .failed)
        #expect(CodeToolStatus(.hidden) == .running)
        #expect(CodeToolStatus(.unknown) == .running)
    }
}

@Suite("Code message rows")
struct CodeMessageRowTests {
    @Test func bodyReasoningAndToolsShareOneRow() throws {
        let reasoning = try makeReasoning(id: "r1", order: 1, message: "msg-1")
        let body = try makeBody(id: "m1", order: 2, message: "msg-1", text: "Done.")
        let tool = try makeToolItem(id: "t1", order: 3, message: "msg-1", blockIndex: 0)
        let rows = CodeMessageBuilder.rows(for: [reasoning, body, tool], profile: .claudeCode)
        #expect(rows.count == 1)
        #expect(rows.map(\.id) == ["msg-1"])
        #expect(rows[0].role == .assistant)
        #expect(blockDescriptors(rows[0]) == ["reasoning:r1", "text:m1", "toolCalls"])
    }

    @Test func blocksFollowRBTNotArrivalOrder() throws {
        // Arrival order is deliberately body, tool, reasoning; the declared
        // group order is reasoning → body → tools.
        let body = try makeBody(id: "m1", order: 1, message: "msg-1")
        let tool = try makeToolItem(id: "t1", order: 2, message: "msg-1", blockIndex: 0)
        let reasoning = try makeReasoning(id: "r1", order: 3, message: "msg-1")
        let rows = CodeMessageBuilder.rows(for: [body, tool, reasoning], profile: .claudeCode)
        #expect(rows.count == 1)
        #expect(blockDescriptors(rows[0]) == ["reasoning:r1", "text:m1", "toolCalls"])
    }

    @Test func productionReasoningRowsAreRecognised() throws {
        // Connector shape: type=system with content.kind=reasoning
        // (connector/connector/runtimes/claude/timeline/messages.py:495-511).
        let reasoning = try makeItem(id: "r1", order: 1, type: "system", role: "system",
                                     content: ["kind": "reasoning", "text": "deep thought"],
                                     source: ["itemId": "msg-1"])
        let body = try makeBody(id: "m1", order: 2, message: "msg-1", text: "answer")
        let rows = CodeMessageBuilder.rows(for: [reasoning, body], profile: .claudeCode)
        #expect(rows.count == 1)
        guard case let .reasoning(id, text, _) = rows[0].blocks[0] else {
            Issue.record("expected a reasoning block"); return
        }
        #expect(id == "r1")
        #expect(text == "deep thought")
        #expect(blockDescriptors(rows[0]) == ["reasoning:r1", "text:m1"])
    }

    @Test func rowsInsideABlockKeepTheirWireOrder() throws {
        let reasoningLate = try makeReasoning(id: "r2", order: 4, message: "msg-1")
        let bodyLate = try makeBody(id: "m2", order: 3, message: "msg-1", text: "second")
        let reasoningEarly = try makeReasoning(id: "r1", order: 1, message: "msg-1")
        let bodyEarly = try makeBody(id: "m1", order: 2, message: "msg-1", text: "first")
        let rows = CodeMessageBuilder.rows(
            for: [reasoningLate, bodyLate, reasoningEarly, bodyEarly], profile: .claudeCode)
        // The engine merges a message's consecutive thinking runs into one
        // `thinkingContent` block; the server's RBT order already places the
        // body rows after it, so the client sees one thinking block.
        #expect(blockDescriptors(rows[0]) == ["reasoning:r1", "text:m1", "text:m2"])
    }

    @Test func consecutiveReasoningIsOneThinkingBlock() throws {
        let first = try makeItem(id: "r1", order: 1, type: "reasoning", status: "done",
                                 content: ["text": "first"],
                                 source: ["itemId": "msg-1"])
        let tool = try makeToolItem(id: "t1", order: 2, message: "msg-1", blockIndex: 0)
        let second = try makeItem(id: "r2", order: 3, type: "reasoning", status: "done",
                                  content: ["text": "second"],
                                  source: ["itemId": "msg-1"])
        let rows = CodeMessageBuilder.rows(for: [first, tool, second], profile: .claudeCode)
        guard case let .reasoning(id, text, status) = rows[0].blocks[0] else {
            Issue.record("expected one merged reasoning block"); return
        }
        #expect(id == "r1")
        #expect(text == "first\n\nsecond")
        #expect(status == .done)
        #expect(blockDescriptors(rows[0]) == ["reasoning:r1", "toolCalls"])
    }

    @Test func runningReasoningKeepsTheBlockRunning() throws {
        let running = try makeItem(id: "r1", order: 1, type: "reasoning", status: "running",
                                   content: ["text": "still"],
                                   source: ["itemId": "msg-1"])
        let done = try makeItem(id: "r2", order: 2, type: "reasoning", status: "done",
                                content: ["text": "done"],
                                source: ["itemId": "msg-1"])
        let rows = CodeMessageBuilder.rows(for: [running, done], profile: .claudeCode)
        guard case let .reasoning(_, _, status) = rows[0].blocks[0] else {
            Issue.record("expected a reasoning block"); return
        }
        #expect(status == .running)
    }

    @Test func toolsOrderByDeclaredBlockIndexEvenWhenInputIsReversed() throws {
        // Input order is the reverse of blockIndex order.
        let late = try makeToolItem(id: "t2", order: 2, message: "msg-1", blockIndex: 5)
        let early = try makeToolItem(id: "t1", order: 3, message: "msg-1", blockIndex: 1)
        let rows = CodeMessageBuilder.rows(for: [late, early], profile: .claudeCode)
        #expect(spanIDs(in: rows[0].blocks) == [["t1", "t2"]])
    }

    @Test func toolTiesKeepWireOrder() throws {
        let second = try makeToolItem(id: "t2", order: 2, message: "msg-1", blockIndex: 1)
        let first = try makeToolItem(id: "t1", order: 1, message: "msg-1", blockIndex: 1)
        let rows = CodeMessageBuilder.rows(for: [second, first], profile: .claudeCode)
        #expect(spanIDs(in: rows[0].blocks) == [["t1", "t2"]])
    }

    @Test func aMissingBlockIndexKeepsTheWholeToolGroupInWireOrder() throws {
        // blockIndex order alone would be t3, t1, t2; because one row declares
        // no index the target order is unknown, so nothing is reordered.
        let first = try makeToolItem(id: "t1", order: 1, message: "msg-1", blockIndex: 5)
        let missing = try makeToolItem(id: "t2", order: 2, message: "msg-1", blockIndex: nil)
        let third = try makeToolItem(id: "t3", order: 3, message: "msg-1", blockIndex: 0)
        let rows = CodeMessageBuilder.rows(for: [first, missing, third], profile: .claudeCode)
        #expect(spanIDs(in: rows[0].blocks) == [["t1", "t2", "t3"]])
    }

    @Test func toolRowsWithoutBlockIndexKeepTheirInputOrder() throws {
        let first = try makeToolItem(id: "t1", order: 1, message: "msg-1", blockIndex: nil)
        let second = try makeToolItem(id: "t2", order: 2, message: "msg-1", blockIndex: nil)
        let rows = CodeMessageBuilder.rows(for: [first, second], profile: .claudeCode)
        #expect(spanIDs(in: rows[0].blocks) == [["t1", "t2"]])
    }

    @Test func rowsWithTheSameKeyGroupEvenWhenNotAdjacent() throws {
        let firstBody = try makeBody(id: "m1", order: 1, message: "msg-1", text: "one")
        let otherBody = try makeBody(id: "m2", order: 2, message: "msg-2", text: "two")
        let lateTool = try makeToolItem(id: "t1", order: 3, message: "msg-1", blockIndex: 0)
        let rows = CodeMessageBuilder.rows(for: [firstBody, otherBody, lateTool],
                                           profile: .claudeCode)
        #expect(rows.map(\.id) == ["msg-1", "msg-2"])
        #expect(blockDescriptors(rows[0]) == ["text:m1", "toolCalls"])
        #expect(blockDescriptors(rows[1]) == ["text:m2"])
    }

    @Test func aRepeatedItemIDDoesNotDuplicateContent() throws {
        // The projection hands over one version per id; a repeated id must not
        // mint a second block or tool call.
        let body = try makeBody(id: "m1", order: 1, message: "msg-1")
        let tool = try makeToolItem(id: "t1", order: 2, message: "msg-1", blockIndex: 0)
        let rows = CodeMessageBuilder.rows(for: [body, tool, body, tool], profile: .claudeCode)
        #expect(rows.count == 1)
        #expect(blockDescriptors(rows[0]) == ["text:m1", "toolCalls"])
        #expect(spanIDs(in: rows[0].blocks) == [["t1"]])
    }

    @Test func separateMessagesStaySeparateRows() throws {
        let first = try makeBody(id: "m1", order: 1, message: "msg-1", text: "one")
        let second = try makeBody(id: "m2", order: 2, message: "msg-2", text: "two")
        let rows = CodeMessageBuilder.rows(for: [first, second], profile: .claudeCode)
        #expect(rows.map(\.id) == ["msg-1", "msg-2"])
    }

    @Test func aUserMessageKeepsItsOwnRow() throws {
        let user = try makeItem(id: "u1", order: 1, role: "user",
                                content: ["text": "question"], source: ["itemId": "u-1"])
        let rows = CodeMessageBuilder.rows(for: [user], profile: .claudeCode)
        #expect(rows.map(\.id) == ["u-1"])
        #expect(rows[0].role == .user)
        #expect(blockDescriptors(rows[0]) == ["text:u1"])
    }

    @Test func aToolOnlyRowHasNoDeclaredMessageRole() throws {
        // No message item in the row, so the role falls back to `.system`
        // rather than guessing user/assistant from the tool name.
        let tool = try makeToolItem(id: "t1", order: 1, message: "msg-1", blockIndex: 0)
        let rows = CodeMessageBuilder.rows(for: [tool], profile: .claudeCode)
        #expect(rows[0].role == .system)
    }

    @Test func subAgentChildRowsLeaveTheMainTimeline() throws {
        let body = try makeBody(id: "m1", order: 1, message: "msg-1")
        let child = try makeToolItem(id: "c1", order: 2, message: "msg-1",
                                     parentItemId: "card-1")
        let rows = CodeMessageBuilder.rows(for: [body, child], profile: .claudeCode)
        #expect(rows.count == 1)
        #expect(blockDescriptors(rows[0]) == ["text:m1"])
    }

    @Test func aRowWithoutADeclaredKeyStandsAlone() throws {
        let marker = try makeItem(id: "sys1", order: 1, type: "marker", role: nil,
                                  content: ["text": "compacted"])
        let rows = CodeMessageBuilder.rows(for: [marker], profile: .claudeCode)
        #expect(rows.map(\.id) == ["item:sys1"])
        #expect(rows[0].role == .system)
        guard case let .other(id, type) = rows[0].blocks[0] else {
            Issue.record("expected an other block"); return
        }
        #expect(id == "sys1")
        #expect(type == "marker")
    }

    @Test func aNonStackableRowWithAKeyKeepsItsOwnRow() throws {
        let artifact = try makeItem(id: "a1", order: 1, type: "artifact", role: nil,
                                    content: ["kind": "diff"], source: ["itemId": "msg-1"])
        let body = try makeBody(id: "m1", order: 2, message: "msg-1")
        let rows = CodeMessageBuilder.rows(for: [artifact, body], profile: .claudeCode)
        #expect(rows.map(\.id) == ["item:a1", "msg-1"])
        #expect(blockDescriptors(rows[0]) == ["other:a1"])
        #expect(blockDescriptors(rows[1]) == ["text:m1"])
    }

    @Test func aMessageWithOnlySkippedToolCallsProducesNoRow() throws {
        let plan = try makeToolItem(id: "p", order: 1, blockIndex: 0, name: "ExitPlanMode")
        let question = try makeToolItem(id: "q", order: 2, blockIndex: 1, name: "AskUserQuestion")
        #expect(CodeMessageBuilder.rows(for: [plan, question], profile: .claudeCode).isEmpty)
    }

    @Test func theRuntimeProfileDecidesSkipSemantics() throws {
        // The same wire call is dropped under the Claude profile and kept as
        // a plain call under Codex; the builder never switches on a runtime id.
        let plan = try makeToolItem(id: "p", order: 1, message: "msg-1",
                                    blockIndex: 0, name: "ExitPlanMode")
        #expect(CodeMessageBuilder.rows(for: [plan], profile: .claudeCode).isEmpty)
        let rows = CodeMessageBuilder.rows(for: [plan], profile: .codex)
        #expect(rows.count == 1)
        #expect(blockDescriptors(rows[0]) == ["toolCalls"])
    }

    @Test func aHiddenToolRowIsLeftForTheCallerToFilter() throws {
        // The builder has no visibility policy: a hidden wire row still yields
        // a running call (`CodeToolStatus` maps `.hidden` to `.running`). W7
        // must filter `status == .hidden` before building so a bookkeeping row
        // never renders.
        let hidden = try makeToolItem(id: "h1", order: 1, message: "msg-1",
                                      blockIndex: 0, status: "hidden")
        let rows = CodeMessageBuilder.rows(for: [hidden], profile: .claudeCode)
        #expect(rows.count == 1)
        guard case let .toolCalls(segments) = rows[0].blocks[0],
              case let .span(calls) = segments[0] else {
            Issue.record("expected a tool span"); return
        }
        #expect(calls.map(\.id) == ["h1"])
        #expect(calls[0].status == .running)
    }

    @Test func aCodexFileChangeArtifactJoinsTheToolSpanAsAnEdit() throws {
        // Codex publishes a file change as an artifact row carrying
        // `content.kind = "file_change"`; the official page renders it in the
        // collapsed tool span. It must be a tool row whose kind comes from the
        // profile's table (`.edit`), not a generic row and not `.other`.
        let artifact = try makeItem(id: "a1", order: 1, type: "artifact", role: nil,
                                    content: ["kind": "file_change", "path": "a.swift",
                                              "action": "update"],
                                    source: ["itemId": "msg-1"])
        let rows = CodeMessageBuilder.rows(for: [artifact], profile: .codex)
        #expect(rows.count == 1)
        #expect(rows[0].id == "msg-1")
        guard case let .toolCalls(segments) = rows[0].blocks[0],
              case let .span(calls) = segments[0] else {
            Issue.record("expected a tool span"); return
        }
        #expect(calls.map(\.id) == ["a1"])
        #expect(calls[0].name == "file_change")
        #expect(calls[0].kind == .edit)
    }
}

import Foundation
import Testing
@testable import ClientCore

// W1: the Code page's pure model. The grouping rules are the official client
// rule (CANONICAL/04-tool-calls.md §3) and the row model is derived from the
// server's declared message grouping (`nativeMessageId` / `itemId` + RBT
// order), so both are tested here without UIKit.

private func makeItem(id: String, order: Int, type: String = "message",
                      role: String? = "assistant", status: String = "done",
                      content: [String: Any] = [:], source: [String: Any] = [:],
                      topLevelTurnID: String? = nil) throws -> V2TimelineItem {
    var object: [String: Any] = [
        "id": id, "sessionId": "session", "type": type, "status": status,
        "content": content, "source": source, "orderSeq": order,
        "revision": 1, "updatedSeq": order, "contentHash": id,
    ]
    if let role { object["role"] = role }
    if let topLevelTurnID { object["turnId"] = topLevelTurnID }
    return try decode(object)
}

/// The connector declares a row's turn on `source` (`TimelineSource.turn_id`);
/// the server persists it there verbatim. Only old/local payloads carry a
/// top-level `turnId`.
private func turnSource(_ turnId: String?, _ source: [String: Any]) -> [String: Any] {
    guard let turnId else { return source }
    var source = source
    source["turnId"] = turnId
    return source
}

private func makeBody(id: String, order: Int, message: String, text: String = "body",
                      role: String = "assistant",
                      turnId: String? = nil) throws -> V2TimelineItem {
    try makeItem(id: id, order: order, role: role, content: ["text": text],
                 source: turnSource(turnId, ["itemId": message]))
}

private func makeReasoning(id: String, order: Int, message: String,
                           text: String = "thinking",
                           turnId: String? = nil) throws -> V2TimelineItem {
    try makeItem(id: id, order: order, type: "reasoning", content: ["text": text],
                 source: turnSource(turnId, ["itemId": message]))
}

private func makeToolItem(id: String, order: Int, message: String? = "msg-1",
                          blockIndex: Int? = 0, name: String = "Read",
                          parentItemId: String? = nil,
                          status: String = "done",
                          turnId: String? = nil) throws -> V2TimelineItem {
    var content: [String: Any] = ["kind": "tool", "toolName": name]
    if let parentItemId { content["parentItemId"] = parentItemId }
    var source: [String: Any] = ["itemId": id]
    if let message { source["nativeMessageId"] = message }
    if let blockIndex { source["blockIndex"] = blockIndex }
    return try makeItem(id: id, order: order, type: "tool", status: status,
                        content: content, source: turnSource(turnId, source))
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

@Suite("V2 timeline item turn id")
struct V2TimelineItemTurnIDTests {
    @Test func sourceTurnIdWinsAndEmptyIsAbsent() throws {
        let declared = try makeItem(id: "m1", order: 1, content: ["text": "x"],
                                    source: ["itemId": "msg-1", "turnId": "source-turn"])
        #expect(declared.turnId == "source-turn")

        // Both shapes present: the connector's `source.turnId` is the truth.
        let both = try makeItem(id: "m2", order: 2, content: ["text": "x"],
                                source: ["itemId": "msg-2", "turnId": "source-turn"],
                                topLevelTurnID: "top-turn")
        #expect(both.turnId == "source-turn")

        // Old/local payload: the top-level shape stays a compatible fallback.
        let topLevelOnly = try makeItem(id: "m3", order: 3, content: ["text": "x"],
                                        source: ["itemId": "msg-3"],
                                        topLevelTurnID: "top-turn")
        #expect(topLevelOnly.turnId == "top-turn")

        // An empty declared id is absent, like every other identity string.
        let empty = try makeItem(id: "m4", order: 4, content: ["text": "x"],
                                 source: ["itemId": "msg-4", "turnId": ""])
        #expect(empty.turnId == nil)
        let emptySourceWithFallback = try makeItem(
            id: "m5", order: 5, content: ["text": "x"],
            source: ["itemId": "msg-5", "turnId": ""], topLevelTurnID: "top-turn")
        #expect(emptySourceWithFallback.turnId == "top-turn")
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

    @Test func runningReasoningStaysOutOfTheSettledBlock() throws {
        // A running row is the live working line; the persistent block only
        // carries settled text and must stay visible while another segment is
        // still streaming.
        let running = try makeItem(id: "r1", order: 1, type: "reasoning", status: "running",
                                   content: ["text": "still"],
                                   source: ["itemId": "msg-1"])
        let done = try makeItem(id: "r2", order: 2, type: "reasoning", status: "done",
                                content: ["text": "done"],
                                source: ["itemId": "msg-1"])
        let rows = CodeMessageBuilder.rows(for: [running, done], profile: .claudeCode)
        guard case let .reasoning(id, text, status) = rows[0].blocks[0] else {
            Issue.record("expected a reasoning block"); return
        }
        #expect(id == "r2")
        #expect(text == "done")
        #expect(status == .done)
    }

    @Test func spanOrderFollowsOrderSeqEvenWhenBlockIndexDisagrees() throws {
        // The merged span orders by `orderSeq` (the only sequence truth across
        // messages; each message restarts `blockIndex` at 0). Input order is the
        // reverse of the arrival order, and `blockIndex` disagrees with it:
        // `orderSeq` wins.
        let late = try makeToolItem(id: "t2", order: 2, message: "msg-1", blockIndex: 5)
        let early = try makeToolItem(id: "t1", order: 3, message: "msg-1", blockIndex: 1)
        let rows = CodeMessageBuilder.rows(for: [late, early], profile: .claudeCode)
        #expect(spanIDs(in: rows[0].blocks) == [["t2", "t1"]])
    }

    @Test func aNonMergingRuntimeKeepsTheDeclaredBlockIndexOrder() throws {
        // Codex has no cross-message merge evidence, so its rows keep the
        // pre-round27 per-message correction: `blockIndex` when every tool row
        // declares it.
        let late = try makeToolItem(id: "t2", order: 2, message: "msg-1", blockIndex: 5)
        let early = try makeToolItem(id: "t1", order: 3, message: "msg-1", blockIndex: 1)
        let rows = CodeMessageBuilder.rows(for: [late, early], profile: .codex)
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

// Round 27: the official engine merges a turn's serial `toolCalls` blocks
// across `DisplayMessage`s (merge function `0x102fa3c24` in 1.261023.20),
// skipping `thinkingContent`, and stops at text/attachment/marker rows, at a
// turn end, and at any row type it does not stack. The planner is the single
// source of the row sequence; these tests pin its units, its idempotency, the
// runtime gate and the grouping hand-off.
@Suite("Code message planner")
struct CodeMessagePlannerTests {
    /// A unit's stable address, in the form a test can compare across runs.
    private func unitDescriptor(_ unit: CodeMessageUnit) -> String {
        switch unit {
        case let .message(key, _): return "message:\(key)"
        case let .span(id, _): return "span:\(id)"
        case let .standalone(item): return "item:\(item.id)"
        }
    }

    // MARK: - Merge

    @Test func parallelToolCallsInOneMessageStayOneSpan() throws {
        let items = [try makeToolItem(id: "t1", order: 1, message: "msg-1", blockIndex: 0),
                     try makeToolItem(id: "t2", order: 2, message: "msg-1", blockIndex: 1),
                     try makeToolItem(id: "t3", order: 3, message: "msg-1", blockIndex: 2)]
        let rows = CodeMessageBuilder.rows(for: items, profile: .claudeCode)
        #expect(rows.count == 1)
        #expect(spanIDs(in: rows[0].blocks) == [["t1", "t2", "t3"]])
    }

    @Test func serialToolMessagesMergeIntoOneSpanAcrossMessageIDs() throws {
        // Three serial tools live in three API messages; the official engine
        // folds them into the earliest `toolCalls` row. Input is deliberately
        // shuffled: the planner sorts by `orderSeq`.
        let first = try makeToolItem(id: "t1", order: 1, message: "msg-1", blockIndex: 0)
        let second = try makeToolItem(id: "t2", order: 2, message: "msg-2", blockIndex: 0)
        let third = try makeToolItem(id: "t3", order: 3, message: "msg-3", blockIndex: 0)
        let rows = CodeMessageBuilder.rows(for: [third, first, second], profile: .claudeCode)
        #expect(rows.count == 1)
        #expect(spanIDs(in: rows[0].blocks) == [["t1", "t2", "t3"]])
        // The span id is the first tool row's stable `source.itemId`.
        #expect(rows[0].id == "t1")
        #expect(rows[0].role == .system)
    }

    @Test func interleavedMessageIDsStayOneSpanInWireOrder() throws {
        // A-B-A: message A's second tool arrives after message B's tool. The
        // declared row order is the only ordering truth; `blockIndex` restarts
        // at 0 per message and must never be used to re-sort the run.
        let aFirst = try makeToolItem(id: "a1", order: 1, message: "msg-a", blockIndex: 0)
        let bFirst = try makeToolItem(id: "b1", order: 2, message: "msg-b", blockIndex: 0)
        let aSecond = try makeToolItem(id: "a2", order: 3, message: "msg-a", blockIndex: 1)
        let rows = CodeMessageBuilder.rows(for: [aFirst, bFirst, aSecond], profile: .claudeCode)
        #expect(rows.count == 1)
        #expect(spanIDs(in: rows[0].blocks) == [["a1", "b1", "a2"]])
    }

    @Test func spanOrderFollowsOrderSeqNotACrossMessageBlockIndex() throws {
        // Sorting by `blockIndex` globally would put t2 first (0 before 5);
        // the declared sequence says t1 first.
        let first = try makeToolItem(id: "t1", order: 1, message: "msg-1", blockIndex: 5)
        let second = try makeToolItem(id: "t2", order: 2, message: "msg-2", blockIndex: 0)
        let rows = CodeMessageBuilder.rows(for: [first, second], profile: .claudeCode)
        #expect(spanIDs(in: rows[0].blocks) == [["t1", "t2"]])
    }

    // MARK: - Breaks

    @Test func anAssistantTextMessageEndsTheRun() throws {
        // The sheet's "中间有 assistant text → 2 行" counts the two tool rows;
        // the text message keeps its own row, so the builder returns three
        // units: span, text, span.
        let first = try makeToolItem(id: "t1", order: 1, message: "msg-1", blockIndex: 0)
        let body = try makeBody(id: "m1", order: 2, message: "msg-2", text: "Now the fix.")
        let second = try makeToolItem(id: "t2", order: 3, message: "msg-3", blockIndex: 0)
        let rows = CodeMessageBuilder.rows(for: [first, body, second], profile: .claudeCode)
        #expect(rows.count == 3)
        #expect(rows.map(\.id) == ["t1", "msg-2", "t2"])
        #expect(spanIDs(in: rows[0].blocks) == [["t1"]])
        #expect(blockDescriptors(rows[1]) == ["text:m1"])
        #expect(spanIDs(in: rows[2].blocks) == [["t2"]])
    }

    @Test func aTextMessageKeepsItsOwnToolAndMergesLaterToolRows() throws {
        // The literal two-row case: the middle message declares text *and* a
        // tool, so its row already ends in `toolCalls` and the following
        // message's tool merges into it (official tail scan).
        let first = try makeToolItem(id: "t1", order: 1, message: "msg-1", blockIndex: 0)
        let body = try makeBody(id: "m1", order: 2, message: "msg-2", text: "Applying it.")
        let own = try makeToolItem(id: "t2", order: 3, message: "msg-2", blockIndex: 0)
        let later = try makeToolItem(id: "t3", order: 4, message: "msg-3", blockIndex: 0)
        let rows = CodeMessageBuilder.rows(for: [first, body, own, later], profile: .claudeCode)
        #expect(rows.count == 2)
        #expect(rows.map(\.id) == ["t1", "msg-2"])
        #expect(spanIDs(in: rows[0].blocks) == [["t1"]])
        #expect(blockDescriptors(rows[1]) == ["text:m1", "toolCalls"])
        #expect(spanIDs(in: rows[1].blocks) == [["t2", "t3"]])
    }

    @Test func aUserPromptEndsTheRunAndNeverMergesToolsAcrossIt() throws {
        // "不跨 user 行": a user prompt is a turn boundary even when the client
        // has no `turnId` yet. The two tool rows stay two spans; the prompt is
        // the third builder row (the sheet counts the two tool rows).
        let first = try makeToolItem(id: "t1", order: 1, message: "msg-1", blockIndex: 0)
        let prompt = try makeItem(id: "u1", order: 2, role: "user",
                                  content: ["text": "stop here"], source: ["itemId": "user-msg"])
        let second = try makeToolItem(id: "t2", order: 3, message: "msg-2", blockIndex: 0)
        let rows = CodeMessageBuilder.rows(for: [first, prompt, second], profile: .claudeCode)
        #expect(rows.count == 3)
        #expect(rows.map(\.id) == ["t1", "user-msg", "t2"])
        #expect(rows[1].role == .user)
        #expect(spanIDs(in: rows[0].blocks) == [["t1"]])
        #expect(spanIDs(in: rows[2].blocks) == [["t2"]])
    }

    @Test func aMarkerEndsTheRun() throws {
        let first = try makeToolItem(id: "t1", order: 1, message: "msg-1", blockIndex: 0)
        let marker = try makeItem(id: "sys1", order: 2, type: "marker", role: nil,
                                  content: ["text": "compacted"])
        let second = try makeToolItem(id: "t2", order: 3, message: "msg-2", blockIndex: 0)
        let rows = CodeMessageBuilder.rows(for: [first, marker, second], profile: .claudeCode)
        #expect(rows.count == 3)
        #expect(blockDescriptors(rows[1]) == ["other:sys1"])
        #expect(spanIDs(in: rows[0].blocks) == [["t1"]])
        #expect(spanIDs(in: rows[2].blocks) == [["t2"]])
    }

    @Test func anAttachmentMessageEndsTheRun() throws {
        let first = try makeToolItem(id: "t1", order: 1, message: "msg-1", blockIndex: 0)
        let attachmentMessage = try makeItem(
            id: "u1", order: 2, role: "user",
            content: ["text": "look",
                      "attachments": [["name": "shot.png", "mediaType": "image/png",
                                       "fileId": "f1"]]],
            source: ["itemId": "user-msg"])
        let second = try makeToolItem(id: "t2", order: 3, message: "msg-2", blockIndex: 0)
        let rows = CodeMessageBuilder.rows(for: [first, attachmentMessage, second],
                                           profile: .claudeCode)
        #expect(rows.count == 3)
        #expect(blockDescriptors(rows[1]) == ["attachments:u1", "text:u1"])
        #expect(spanIDs(in: rows[0].blocks) == [["t1"]])
        #expect(spanIDs(in: rows[2].blocks) == [["t2"]])
    }

    @Test func aToolRowWithoutAGroupingKeyEndsTheRun() throws {
        // No `nativeMessageId` and no `itemId`: the row cannot join a span and
        // keeps its own item.
        let first = try makeToolItem(id: "t1", order: 1, message: "msg-1", blockIndex: 0)
        let orphan = try makeItem(id: "o1", order: 2, type: "tool", role: "tool",
                                  content: ["kind": "tool", "toolName": "Read"], source: [:])
        let second = try makeToolItem(id: "t2", order: 3, message: "msg-2", blockIndex: 0)
        let rows = CodeMessageBuilder.rows(for: [first, orphan, second], profile: .claudeCode)
        #expect(rows.count == 3)
        #expect(rows.map(\.id) == ["t1", "item:o1", "t2"])
        #expect(spanIDs(in: rows[0].blocks) == [["t1"]])
        #expect(spanIDs(in: rows[2].blocks) == [["t2"]])
    }

    @Test func anAgentCardWithoutABlockIndexEndsTheRun() throws {
        // The connector's Agent card is `content.kind == "agent_call"` with no
        // `blockIndex`; it is the official `threadSessionCard` shape and keeps
        // its own row instead of merging into the surrounding run.
        let first = try makeToolItem(id: "t1", order: 1, message: "msg-1", blockIndex: 0)
        let card = try makeItem(id: "c1", order: 2, type: "tool", role: "tool",
                                content: ["kind": "agent_call", "toolName": "Agent"],
                                source: ["itemId": "c1", "nativeMessageId": "msg-2"])
        let second = try makeToolItem(id: "t2", order: 3, message: "msg-3", blockIndex: 0)
        let rows = CodeMessageBuilder.rows(for: [first, card, second], profile: .claudeCode)
        #expect(rows.count == 3)
        #expect(spanIDs(in: rows[0].blocks) == [["t1"]])
        #expect(spanIDs(in: rows[1].blocks) == [["c1"]])
        #expect(spanIDs(in: rows[2].blocks) == [["t2"]])
    }

    @Test func skippedPlanAndAnswerCallsNeitherRenderNorBreakTheSpan() throws {
        // `ExitPlanMode` and an answered `AskUserQuestion` are pulled out of
        // the tool block: no segment, and no flush either (round27 C A2).
        let first = try makeToolItem(id: "t1", order: 1, message: "msg-1", blockIndex: 0)
        let plan = try makeToolItem(id: "p", order: 2, message: "msg-2",
                                    blockIndex: 0, name: "ExitPlanMode")
        let answer = try makeToolItem(id: "q", order: 3, message: "msg-3",
                                      blockIndex: 0, name: "AskUserQuestion")
        let second = try makeToolItem(id: "t2", order: 4, message: "msg-4", blockIndex: 0)
        let rows = CodeMessageBuilder.rows(for: [first, plan, answer, second],
                                           profile: .claudeCode)
        #expect(rows.count == 1)
        #expect(spanIDs(in: rows[0].blocks) == [["t1", "t2"]])
    }

    @Test func aTransientQuestionInAnInteractionTargetStaysItsOwnRow() throws {
        // A question still waiting for an answer is anchored by an interaction
        // notice: it gets a standalone unit *and* ends the run, unlike the
        // answered/skipped form above.
        let first = try makeToolItem(id: "t1", order: 1, message: "msg-1", blockIndex: 0)
        let question = try makeToolItem(id: "q", order: 2, message: "msg-2", blockIndex: 0,
                                        name: "AskUserQuestion", status: "running")
        let second = try makeToolItem(id: "t2", order: 3, message: "msg-3", blockIndex: 0)
        let units = CodeMessageBuilder.units(for: [first, question, second],
                                             profile: .claudeCode,
                                             interactionTargets: ["q"])
        #expect(units.map { unitDescriptor($0) } == ["span:t1", "item:q", "span:t2"])
        guard case let .standalone(item) = units[1] else {
            Issue.record("expected the question to keep its own unit"); return
        }
        #expect(item.id == "q")
    }

    // MARK: - Thinking

    @Test func reasoningMergesAcrossSerialMessagesIntoOneThinkingBlock() throws {
        let first = try makeReasoning(id: "r1", order: 1, message: "msg-1", text: "first")
        let tool = try makeToolItem(id: "t1", order: 2, message: "msg-1", blockIndex: 0)
        let second = try makeReasoning(id: "r2", order: 3, message: "msg-2", text: "second")
        let laterTool = try makeToolItem(id: "t2", order: 4, message: "msg-2", blockIndex: 0)
        let rows = CodeMessageBuilder.rows(for: [first, tool, second, laterTool],
                                           profile: .claudeCode)
        #expect(rows.count == 1)
        guard case let .reasoning(id, text, status) = rows[0].blocks[0] else {
            Issue.record("expected one merged thinking block"); return
        }
        #expect(id == "r1")
        #expect(text == "first\n\nsecond")
        #expect(status == .done)
        #expect(blockDescriptors(rows[0]) == ["reasoning:r1", "toolCalls"])
        #expect(spanIDs(in: rows[0].blocks) == [["t1", "t2"]])
    }

    @Test func thinkingFromLaterSerialMessagesJoinsTheOpenMessageRow() throws {
        // The common production shape: an assistant text message with a tool,
        // then serial tool-only messages that each start with thinking. The
        // thinking is transparent (rule 3), so it joins the row that is still
        // open; the official thinking merger backscans the same way.
        let reasoning1 = try makeReasoning(id: "r1", order: 1, message: "msg-1",
                                           text: "plan")
        let body = try makeBody(id: "m1", order: 2, message: "msg-1",
                                text: "Running it.")
        let tool1 = try makeToolItem(id: "t1", order: 3, message: "msg-1", blockIndex: 0)
        let reasoning2 = try makeReasoning(id: "r2", order: 4, message: "msg-2",
                                           text: "check")
        let tool2 = try makeToolItem(id: "t2", order: 5, message: "msg-2", blockIndex: 0)
        let reasoning3 = try makeReasoning(id: "r3", order: 6, message: "msg-3",
                                           text: "done")
        let tool3 = try makeToolItem(id: "t3", order: 7, message: "msg-3", blockIndex: 0)
        let rows = CodeMessageBuilder.rows(
            for: [reasoning1, body, tool1, reasoning2, tool2, reasoning3, tool3],
            profile: .claudeCode)
        #expect(rows.count == 1)
        #expect(rows[0].id == "msg-1")
        guard case let .reasoning(id, text, status) = rows[0].blocks[0] else {
            Issue.record("expected one merged thinking block"); return
        }
        #expect(id == "r1")
        #expect(text == "plan\n\ncheck\n\ndone")
        #expect(status == .done)
        #expect(blockDescriptors(rows[0]) == ["reasoning:r1", "text:m1", "toolCalls"])
        #expect(spanIDs(in: rows[0].blocks) == [["t1", "t2", "t3"]])
    }

    @Test func aRunningReasoningRowDoesNotHideTheSettledThinkingBlock() throws {
        // A running row is represented by the live working line; it must not
        // join the persistent block, or the whole `思考过程` row would flip to
        // running and disappear while the next segment streams.
        let running = try makeItem(id: "r1", order: 1, type: "reasoning", status: "running",
                                   content: ["text": "still"],
                                   source: ["itemId": "msg-1"])
        let tool = try makeToolItem(id: "t1", order: 2, message: "msg-1", blockIndex: 0)
        let done = try makeReasoning(id: "r2", order: 3, message: "msg-2", text: "done")
        let laterTool = try makeToolItem(id: "t2", order: 4, message: "msg-2", blockIndex: 0)
        let rows = CodeMessageBuilder.rows(for: [running, tool, done, laterTool],
                                           profile: .claudeCode)
        guard case let .reasoning(id, text, status) = rows[0].blocks[0] else {
            Issue.record("expected one merged thinking block"); return
        }
        #expect(id == "r2")
        #expect(text == "done")
        #expect(status == .done)
    }

    // MARK: - Turn boundaries (source.turnId)

    @Test func twoScheduledTurnsWithoutAUserRowStayTwoRows() throws {
        // A scheduled turn publishes no user row. Two turns' tool-only
        // messages declare different turn ids and must not merge into one span
        // even though they are adjacent in `orderSeq`.
        let firstInA = try makeToolItem(id: "a1", order: 1, message: "msg-a1",
                                        blockIndex: 0, turnId: "turn-a")
        let secondInA = try makeToolItem(id: "a2", order: 2, message: "msg-a2",
                                         blockIndex: 0, turnId: "turn-a")
        let firstInB = try makeToolItem(id: "b1", order: 3, message: "msg-b1",
                                        blockIndex: 0, turnId: "turn-b")
        let secondInB = try makeToolItem(id: "b2", order: 4, message: "msg-b2",
                                         blockIndex: 0, turnId: "turn-b")
        let rows = CodeMessageBuilder.rows(
            for: [firstInA, firstInB, secondInA, secondInB], profile: .claudeCode)
        #expect(rows.count == 2)
        #expect(rows.map(\.id) == ["a1", "b1"])
        #expect(spanIDs(in: rows[0].blocks) == [["a1", "a2"]])
        #expect(spanIDs(in: rows[1].blocks) == [["b1", "b2"]])
    }

    @Test func oneTurnAcrossThreeMessagesIsOneRow() throws {
        let first = try makeToolItem(id: "t1", order: 1, message: "msg-1",
                                     blockIndex: 0, turnId: "turn-1")
        let second = try makeToolItem(id: "t2", order: 2, message: "msg-2",
                                      blockIndex: 0, turnId: "turn-1")
        let third = try makeToolItem(id: "t3", order: 3, message: "msg-3",
                                     blockIndex: 0, turnId: "turn-1")
        let rows = CodeMessageBuilder.rows(for: [third, first, second], profile: .claudeCode)
        #expect(rows.count == 1)
        #expect(rows[0].id == "t1")
        #expect(spanIDs(in: rows[0].blocks) == [["t1", "t2", "t3"]])
    }

    @Test func missingTurnIdFallsBackToTheUserRowBoundary() throws {
        // Old payloads carry no turn id anywhere: the pre-turnId grouping is
        // untouched. Tools merge across messages; a user prompt still splits.
        let first = try makeToolItem(id: "t1", order: 1, message: "msg-1", blockIndex: 0)
        let second = try makeToolItem(id: "t2", order: 3, message: "msg-2", blockIndex: 0)
        let merged = CodeMessageBuilder.rows(for: [first, second], profile: .claudeCode)
        #expect(merged.count == 1)
        #expect(spanIDs(in: merged[0].blocks) == [["t1", "t2"]])

        let prompt = try makeItem(id: "u1", order: 2, role: "user",
                                  content: ["text": "next"], source: ["itemId": "user-msg"])
        let split = CodeMessageBuilder.rows(for: [first, prompt, second], profile: .claudeCode)
        #expect(split.count == 3)
        #expect(spanIDs(in: split[0].blocks) == [["t1"]])
        #expect(split[1].role == .user)
        #expect(spanIDs(in: split[2].blocks) == [["t2"]])
    }

    @Test func aRowWithoutATurnIdInheritsThePreviousTurn() throws {
        // `t2` declares no turn, so it belongs to `turn-a` and may merge; it
        // neither starts a boundary nor swallows the next declared turn.
        let first = try makeToolItem(id: "t1", order: 1, message: "msg-1",
                                     blockIndex: 0, turnId: "turn-a")
        let inherited = try makeToolItem(id: "t2", order: 2, message: "msg-2", blockIndex: 0)
        let nextTurn = try makeToolItem(id: "t3", order: 3, message: "msg-3",
                                        blockIndex: 0, turnId: "turn-b")
        let rows = CodeMessageBuilder.rows(for: [first, inherited, nextTurn],
                                           profile: .claudeCode)
        #expect(rows.count == 2)
        #expect(rows.map(\.id) == ["t1", "t3"])
        #expect(spanIDs(in: rows[0].blocks) == [["t1", "t2"]])
        #expect(spanIDs(in: rows[1].blocks) == [["t3"]])
    }

    @Test func aTurnIdOnOnlyTheBodyRowStillSplitsAtTheNextDeclaredTurn() throws {
        // Production history shape: the body row declares the turn, its tool
        // rows do not. The tools inherit the body's turn, and the next
        // message's declared turn ends the run.
        let bodyA = try makeBody(id: "m1", order: 1, message: "msg-a",
                                 text: "first", turnId: "turn-a")
        let toolA = try makeToolItem(id: "t1", order: 2, message: "msg-a", blockIndex: 0)
        let bodyB = try makeBody(id: "m2", order: 3, message: "msg-b",
                                 text: "second", turnId: "turn-b")
        let toolB = try makeToolItem(id: "t2", order: 4, message: "msg-b", blockIndex: 0)
        let rows = CodeMessageBuilder.rows(for: [bodyA, toolA, bodyB, toolB],
                                           profile: .claudeCode)
        #expect(rows.count == 2)
        #expect(rows.map(\.id) == ["msg-a", "msg-b"])
        #expect(blockDescriptors(rows[0]) == ["text:m1", "toolCalls"])
        #expect(spanIDs(in: rows[0].blocks) == [["t1"]])
        #expect(blockDescriptors(rows[1]) == ["text:m2", "toolCalls"])
        #expect(spanIDs(in: rows[1].blocks) == [["t2"]])
    }

    @Test func aSubAgentChildsOwnTurnIdDoesNotSplitTheParentRun() throws {
        // A captured subagent frame can fall back to a sub-agent-local turn id
        // (`turn_claude_subagent_*`) when its parent card is not projected yet.
        // The child row is not part of this timeline, so it must not end the
        // parent turn's span.
        let first = try makeToolItem(id: "t1", order: 1, message: "msg-1",
                                     blockIndex: 0, turnId: "turn-a")
        let child = try makeToolItem(id: "c1", order: 2, message: "msg-2",
                                     blockIndex: 0, parentItemId: "card-1",
                                     turnId: "turn_claude_subagent_card")
        let second = try makeToolItem(id: "t2", order: 3, message: "msg-3",
                                      blockIndex: 0, turnId: "turn-a")
        let rows = CodeMessageBuilder.rows(for: [first, child, second],
                                           profile: .claudeCode)
        #expect(rows.count == 1)
        #expect(spanIDs(in: rows[0].blocks) == [["t1", "t2"]])
    }

    @Test func replanningTurnUnitsIsIdempotent() throws {
        let items = [try makeToolItem(id: "t1", order: 1, message: "msg-1",
                                      blockIndex: 0, turnId: "turn-a"),
                     try makeToolItem(id: "t2", order: 2, message: "msg-2",
                                      blockIndex: 0, turnId: "turn-a"),
                     try makeToolItem(id: "t3", order: 3, message: "msg-3",
                                      blockIndex: 0, turnId: "turn-b")]
        let units = CodeMessageBuilder.units(for: items, profile: .claudeCode)
        #expect(units.map { unitDescriptor($0) } == ["span:t1", "span:t3"])
        for unit in units {
            let again = CodeMessageBuilder.units(for: unit.items, profile: .claudeCode)
            #expect(again.map { unitDescriptor($0) } == [unitDescriptor(unit)])
            #expect(again[0].items.map(\.id) == unit.items.map(\.id))
        }
    }

    // MARK: - Stability

    @Test func replanningOneUnitIsIdempotent() throws {
        // The adapter, the row view and the height measurer rebuild a group
        // from the group's own rows; a unit must plan back to itself.
        let items = [try makeReasoning(id: "r1", order: 1, message: "msg-1", text: "think"),
                     try makeBody(id: "m1", order: 2, message: "msg-1", text: "body"),
                     try makeToolItem(id: "t1", order: 3, message: "msg-1", blockIndex: 0),
                     try makeToolItem(id: "t2", order: 4, message: "msg-2", blockIndex: 0),
                     try makeReasoning(id: "r2", order: 5, message: "msg-2", text: "more"),
                     try makeToolItem(id: "t3", order: 6, message: "msg-2", blockIndex: 0)]
        let units = CodeMessageBuilder.units(for: items, profile: .claudeCode)
        #expect(units.map { unitDescriptor($0) } == ["message:msg-1"])
        for unit in units {
            let again = CodeMessageBuilder.units(for: unit.items, profile: .claudeCode)
            #expect(again.map { unitDescriptor($0) } == [unitDescriptor(unit)])
            #expect(again[0].items.map(\.id) == unit.items.map(\.id))
        }
    }

    @Test func aWindowThatStartsMidRunPlansDeterministically() throws {
        // History pagination can hand over a suffix of a turn. The planner
        // knows nothing about the missing earlier tools; it must not crash or
        // invent a row, and the first surviving tool anchors the span.
        let first = try makeToolItem(id: "t2", order: 2, message: "msg-2", blockIndex: 0)
        let second = try makeToolItem(id: "t3", order: 3, message: "msg-3", blockIndex: 0)
        let rows = CodeMessageBuilder.rows(for: [first, second], profile: .claudeCode)
        #expect(rows.count == 1)
        #expect(rows[0].id == "t2")
        #expect(spanIDs(in: rows[0].blocks) == [["t2", "t3"]])
    }

    // MARK: - Runtime gate and grouping hand-off

    @Test func anInjectedTurnBoundaryEndsTheRun() throws {
        // Rule 6's seam: the default boundary is a user row; a future
        // `source.turnId` line can pass its own predicate without touching
        // the planner.
        let first = try makeToolItem(id: "t1", order: 1, message: "msg-1", blockIndex: 0)
        let second = try makeToolItem(id: "t2", order: 2, message: "msg-2", blockIndex: 0)
        let units = CodeMessageBuilder.units(for: [first, second],
                                             profile: .claudeCode,
                                             isTurnBoundary: { $0.id == "t2" })
        #expect(units.map { unitDescriptor($0) } == ["span:t1", "span:t2"])
    }

    @Test func onlyTheClaudeProfileMergesToolRowsAcrossMessages() throws {
        #expect(CodeRuntimeProfile.claudeCode.mergesToolRowsAcrossMessages)
        for profile in [CodeRuntimeProfile.codex, .dsh, .generic] {
            #expect(!profile.mergesToolRowsAcrossMessages, "\(profile.family)")
        }

        let first = try makeToolItem(id: "t1", order: 1, message: "msg-1", blockIndex: 0)
        let second = try makeToolItem(id: "t2", order: 2, message: "msg-2", blockIndex: 0)
        #expect(CodeMessageBuilder.rows(for: [first, second], profile: .claudeCode).count == 1)
        let codexRows = CodeMessageBuilder.rows(for: [first, second], profile: .codex)
        #expect(codexRows.count == 2)
        #expect(codexRows.map(\.id) == ["msg-1", "msg-2"])
    }

    @Test func codeGroupsGroupSerialToolsIntoOneSpan() throws {
        // `TimelineGrouping.codeGroups` must reuse the planner, so the
        // collection identity and the row builder agree on the unit list.
        let first = try makeToolItem(id: "t1", order: 1, message: "msg-1", blockIndex: 0)
        let second = try makeToolItem(id: "t2", order: 2, message: "msg-2", blockIndex: 0)
        let models = [ChatTimelineRowModel(first), ChatTimelineRowModel(second)]
        let groups = TimelineGrouping.codeGroups(models, profile: .claudeCode,
                                                 interactionTargets: [])
        #expect(groups.count == 1)
        #expect(groups[0].explicitID == "t1")
        #expect(groups[0].rows.map(\.id) == ["t1", "t2"])
    }

    @Test func codeGroupsKeepATransientQuestionAsItsOwnGroup() throws {
        let first = try makeToolItem(id: "t1", order: 1, message: "msg-1", blockIndex: 0)
        let question = try makeToolItem(id: "q", order: 2, message: "msg-2", blockIndex: 0,
                                        name: "AskUserQuestion", status: "running")
        let second = try makeToolItem(id: "t2", order: 3, message: "msg-3", blockIndex: 0)
        let models = [ChatTimelineRowModel(first), ChatTimelineRowModel(question),
                      ChatTimelineRowModel(second)]
        let groups = TimelineGrouping.codeGroups(models, profile: .claudeCode,
                                                 interactionTargets: ["q"])
        #expect(groups.count == 3)
        #expect(groups.map(\.explicitID) == ["t1", nil, "t2"])
        #expect(groups[1].rows.map(\.id) == ["q"])
    }
}

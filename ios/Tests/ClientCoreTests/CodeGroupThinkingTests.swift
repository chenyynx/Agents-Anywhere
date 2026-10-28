import Foundation
import Testing
@testable import ClientCore

// The Code row's group-detail thinking mapping (R28 §U 收口三, I-high).
//
// The official span detail shows the group's settled thinking text above its
// call list. AA's row model keeps reasoning and toolCalls as sibling blocks,
// so the view threads the text into the first toolCalls block. These tests pin
// that pure mapping: only settled (`done`) reasoning contributes, the runs
// join with a blank line, and the anchor is the first toolCalls block (or no
// plan at all when either side is missing). The profile gate reuses the same
// function for its detail-group fixture.

private func makeCall(_ id: String) throws -> CodeToolCall {
    let item: V2TimelineItem = try decode([
        "id": id,
        "sessionId": "session",
        "type": "tool",
        "status": "done",
        "content": ["toolName": "Edit", "input": ["file_path": "/repo/Main.dc.html"]],
        "source": ["itemId": id],
        "orderSeq": 1,
        "revision": 1,
        "updatedSeq": 1,
        "contentHash": id,
    ])
    return CodeToolCall(item: item, kind: .edit)
}

private func toolBlock(_ ids: [String] = ["tool-1"]) throws -> CodeMessageRow.Block {
    .toolCalls([.span(try ids.map(makeCall))])
}

private func reasoning(_ id: String,
                       _ text: String,
                       status: V2TimelineItemStatus = .done) -> CodeMessageRow.Block {
    .reasoning(id: id, text: text, status: status)
}

@Suite("Code group thinking mapping")
struct CodeGroupThinkingTests {

    @Test func settledReasoningReachesTheFirstToolBlock() throws {
        let blocks: [CodeMessageRow.Block] = [
            reasoning("r1", "Inspecting both files before the edit."),
            .text(id: "m1", text: "Done."),
            try toolBlock(["t1", "t2"]),
        ]
        let plan = CodeGroupThinking.plan(for: blocks)

        #expect(plan?.text == "Inspecting both files before the edit.")
        // The text is anchored to the first `.toolCalls` block, not to the
        // reasoning block or the body before it.
        #expect(plan?.anchorBlockIndex == 2)
    }

    @Test func noReasoningProducesNoPlan() throws {
        let blocks: [CodeMessageRow.Block] = [
            .text(id: "m1", text: "Done."),
            try toolBlock(["t1"]),
        ]
        #expect(CodeGroupThinking.plan(for: blocks) == nil)
    }

    @Test func noToolCallsProducesNoPlan() {
        // Nothing would carry the text into a detail request.
        let blocks: [CodeMessageRow.Block] = [
            reasoning("r1", "Only thinking, no tools."),
            .text(id: "m1", text: "Answer."),
        ]
        #expect(CodeGroupThinking.plan(for: blocks) == nil)
    }

    @Test func multipleSettledRunsJoinWithABlankLine() throws {
        let blocks: [CodeMessageRow.Block] = [
            reasoning("r1", "First check."),
            reasoning("r2", "Second check."),
            try toolBlock(["t1"]),
        ]
        let plan = CodeGroupThinking.plan(for: blocks)

        #expect(plan?.text == "First check.\n\nSecond check.")
        #expect(plan?.anchorBlockIndex == 2)
    }

    @Test func onlySettledRunsContribute() throws {
        // A running reasoning block belongs to the turn-level working line;
        // it must not leak into the detail page, and it must not stop a
        // settled run beside it from contributing.
        let runningFirst: [CodeMessageRow.Block] = [
            reasoning("r1", "Still streaming.", status: .running),
            try toolBlock(["t1"]),
        ]
        #expect(CodeGroupThinking.plan(for: runningFirst) == nil)

        let mixed: [CodeMessageRow.Block] = [
            reasoning("r1", "Still streaming.", status: .running),
            reasoning("r2", "Settled check."),
            try toolBlock(["t1"]),
        ]
        let plan = CodeGroupThinking.plan(for: mixed)
        #expect(plan?.text == "Settled check.")
        #expect(plan?.anchorBlockIndex == 2)
    }
}

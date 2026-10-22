import Foundation
import Testing
@testable import ClientCore

// The collapsed tool row's label shape. Device report 2026-10-23 caught the
// span summary counting calls instead of files: six edits to one file read as
// "Edited 6 files". These tests pin the official counting rules from
// `EVIDENCE/resources-r6.md` §3.3 (`ccr_summary_*` counts distinct files /
// commands / agents / tools).

private func makeCall(_ id: String,
                      name: String,
                      kind: CodeToolKind,
                      input: [String: Any] = [:],
                      status: String = "done") throws -> CodeToolCall {
    let item: V2TimelineItem = try decode([
        "id": id,
        "sessionId": "session",
        "type": "tool",
        "status": status,
        "content": ["kind": "tool_call", "toolName": name, "input": input],
        "source": ["itemId": id, "nativeMessageId": "msg-1", "blockIndex": 1],
        "orderSeq": 1,
        "revision": 1,
        "updatedSeq": 1,
        "contentHash": id,
    ])
    return CodeToolCall(item: item, kind: kind)
}

@Suite("Code tool label plan")
struct CodeToolLabelPlanTests {
    @Test func singleEditCarriesItsTarget() throws {
        let call = try makeCall("e1", name: "Edit", kind: .edit,
                                input: ["file_path": "/repo/Sources/A.swift"])
        let plan = try #require(CodeToolLabelPlan.make(calls: [call], cwd: nil))
        #expect(plan.verb == .edited)
        #expect(plan.target == "/repo/Sources/A.swift")
        #expect(plan.phrases.isEmpty)
    }

    /// Six Edit calls, one file: the official server summary would name the
    /// file; the client derives the same shape instead of saying "6 files".
    @Test func sixEditsToOneFileKeepTheSingleFileShape() throws {
        let calls = try (0..<6).map { index in
            try makeCall("e\(index)", name: "Edit", kind: .edit,
                         input: ["file_path": "/home/u/memory/MEMORY.md"])
        }
        let plan = try #require(CodeToolLabelPlan.make(calls: calls, cwd: nil))
        #expect(plan.verb == .edited)
        #expect(plan.target == "/home/u/memory/MEMORY.md")
        #expect(plan.phrases.isEmpty)
    }

    @Test func editsToDistinctFilesCountFilesNotCalls() throws {
        let calls = try (0..<6).map { index in
            try makeCall("e\(index)", name: "Edit", kind: .edit,
                         input: ["file_path": "/repo/F\(index).swift"])
        }
        let plan = try #require(CodeToolLabelPlan.make(calls: calls, cwd: nil))
        #expect(plan.verb == nil)
        #expect(plan.phrases == [
            .init(verb: .edited, unit: .files, count: 6),
        ])
    }

    @Test func duplicateReadsOfOneFileCountOnce() throws {
        let calls = try (0..<3).map { index in
            try makeCall("r\(index)", name: "Read", kind: .read,
                         input: ["file_path": "/repo/Only.swift"])
        }
        let plan = try #require(CodeToolLabelPlan.make(calls: calls, cwd: nil))
        #expect(plan.verb == .read)
        #expect(plan.target == "/repo/Only.swift")
    }

    @Test func mixedSpanCountsFilesAndCommands() throws {
        let calls = [
            try makeCall("r1", name: "Read", kind: .read, input: ["file_path": "/repo/A.swift"]),
            try makeCall("r2", name: "Read", kind: .read, input: ["file_path": "/repo/B.swift"]),
            try makeCall("b1", name: "Bash", kind: .bash, input: ["command": "ls"]),
            try makeCall("b2", name: "Bash", kind: .bash, input: ["command": "pwd"]),
            try makeCall("b3", name: "Bash", kind: .bash, input: ["command": "git status"]),
        ]
        let plan = try #require(CodeToolLabelPlan.make(calls: calls, cwd: nil))
        #expect(plan.verb == nil)
        #expect(plan.phrases == [
            .init(verb: .read, unit: .files, count: 2),
            .init(verb: .ran, unit: .commands, count: 3),
        ])
    }

    @Test func grepSpanUsesSearchedCodeSummary() throws {
        let calls = [
            try makeCall("g1", name: "Grep", kind: .search, input: ["pattern": "a"]),
            try makeCall("g2", name: "Grep", kind: .search, input: ["pattern": "b"]),
        ]
        let plan = try #require(CodeToolLabelPlan.make(calls: calls, cwd: nil))
        #expect(plan.phrases == [
            .init(verb: .searchedCode, unit: .none, count: 1),
        ])
    }

    @Test func emptyTodoCallIsClearedTodos() throws {
        let call = try makeCall("t1", name: "TodoWrite", kind: .todo,
                                input: ["todos": []])
        let plan = try #require(CodeToolLabelPlan.make(calls: [call], cwd: nil))
        #expect(plan.verb == .clearedTodos)
        #expect(plan.target == nil)
    }

    @Test func usedToolKeepsItsNameAsTarget() throws {
        let call = try makeCall("m1", name: "mcp__github__search", kind: .mcp)
        let plan = try #require(CodeToolLabelPlan.make(calls: [call], cwd: nil))
        #expect(plan.verb == .used)
        #expect(plan.target == "mcp__github__search")
    }

    @Test func writeCountsFiles() throws {
        let calls = [
            try makeCall("w1", name: "Write", kind: .write, input: ["file_path": "/repo/New1.swift"]),
            try makeCall("w2", name: "Write", kind: .write, input: ["file_path": "/repo/New2.swift"]),
        ]
        let plan = try #require(CodeToolLabelPlan.make(calls: calls, cwd: nil))
        #expect(plan.phrases == [
            .init(verb: .created, unit: .files, count: 2),
        ])
    }
}

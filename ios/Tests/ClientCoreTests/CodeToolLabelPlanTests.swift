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
                      status: String = "done",
                      text: String? = nil) throws -> CodeToolCall {
    var content: [String: Any] = ["kind": "tool_call", "toolName": name, "input": input]
    if let text { content["text"] = text }
    let item: V2TimelineItem = try decode([
        "id": id,
        "sessionId": "session",
        "type": "tool",
        "status": status,
        "content": content,
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

    // MARK: Official Write kind (fileWriteKind)

    @Test func writeCreateResultUsesTheCreatedVerb() throws {
        let call = try makeCall("w1", name: "Write", kind: .write,
                                input: ["file_path": "/repo/A.swift"],
                                text: "File created successfully at: /repo/A.swift (file state is current in your context — no need to Read it back)")
        #expect(CodeToolLabelPlan.fileWriteKind(for: call) == .create)
        let plan = try #require(CodeToolLabelPlan.make(calls: [call], cwd: nil))
        #expect(plan.verb == .created)
        #expect(plan.target == "/repo/A.swift")
    }

    @Test func writeUpdateResultUsesTheUpdatedVerb() throws {
        let call = try makeCall("w1", name: "Write", kind: .write,
                                input: ["file_path": "/repo/A.swift"],
                                text: "The file /repo/A.swift has been updated successfully. (file state is current in your context — no need to Read it back)")
        #expect(CodeToolLabelPlan.fileWriteKind(for: call) == .update)
        let plan = try #require(CodeToolLabelPlan.make(calls: [call], cwd: nil))
        #expect(plan.verb == .updated)
        #expect(plan.target == "/repo/A.swift")
    }

    @Test func unknownWriteResultKeepsTheCreatedVerb() throws {
        let call = try makeCall("w1", name: "Write", kind: .write,
                                input: ["file_path": "/repo/A.swift"],
                                text: "No tool result was recorded in Claude history.")
        #expect(CodeToolLabelPlan.fileWriteKind(for: call) == nil)
        let plan = try #require(CodeToolLabelPlan.make(calls: [call], cwd: nil))
        #expect(plan.verb == .created)
    }

    /// Claude Code's Edit shares the "has been updated successfully"
    /// wording; it is not a fileWriteKind and its diff must keep counting.
    @Test func editWithUpdateWordingIsNotAnUpdateWrite() throws {
        let item: V2TimelineItem = try decode([
            "id": "e1", "sessionId": "session", "type": "tool", "status": "done",
            "content": [
                "kind": "file_change", "toolName": "Edit",
                "input": ["file_path": "/repo/A.swift"],
                "text": "The file /repo/A.swift has been updated successfully.",
                "structuredPatch": [[
                    "oldStart": 1, "oldLines": 1, "newStart": 1, "newLines": 1,
                    "lines": ["-old", "+new"],
                ]],
            ],
            "source": ["itemId": "e1"],
            "orderSeq": 1, "revision": 1, "updatedSeq": 1, "contentHash": "e1",
        ])
        let call = CodeToolCall(item: item, kind: .edit)
        #expect(CodeToolLabelPlan.fileWriteKind(for: call) == nil)
        #expect(CodeToolLabelPlan.diffStat(for: [call])
            == CodeDiffStat(added: 1, removed: 1))
    }

    /// Official `0x10288fa10` skips an update write but keeps counting the
    /// other calls; the update write's own patch must not reach the badge.
    @Test func diffBadgeSkipsUpdateWriteButKeepsTheEdit() throws {
        let writeItem: V2TimelineItem = try decode([
            "id": "w1", "sessionId": "session", "type": "tool", "status": "done",
            "content": [
                "kind": "file_change", "toolName": "Write",
                "input": ["file_path": "/repo/A.swift"],
                "text": "The file /repo/A.swift has been updated successfully. (file state is current in your context — no need to Read it back)",
                "structuredPatch": [[
                    "oldStart": 1, "oldLines": 1, "newStart": 1, "newLines": 1,
                    "lines": ["-old", "+new"],
                ]],
            ],
            "source": ["itemId": "w1"],
            "orderSeq": 1, "revision": 1, "updatedSeq": 1, "contentHash": "w1",
        ])
        let editItem: V2TimelineItem = try decode([
            "id": "e1", "sessionId": "session", "type": "tool", "status": "done",
            "content": [
                "kind": "file_change", "toolName": "Edit",
                "structuredPatch": [[
                    "oldStart": 1, "oldLines": 1, "newStart": 1, "newLines": 3,
                    "lines": ["-c", "+d", "+e"],
                ]],
            ],
            "source": ["itemId": "e1"],
            "orderSeq": 2, "revision": 1, "updatedSeq": 1, "contentHash": "e1",
        ])
        #expect(CodeToolLabelPlan.diffStat(for: [
            CodeToolCall(item: writeItem, kind: .write),
            CodeToolCall(item: editItem, kind: .edit),
        ]) == CodeDiffStat(added: 2, removed: 1))
    }

    /// A create write is not skipped: its patch is a real diff and is summed
    /// with its siblings.
    @Test func diffBadgeCountsCreateWriteWithTheEdit() throws {
        let writeItem: V2TimelineItem = try decode([
            "id": "w1", "sessionId": "session", "type": "tool", "status": "done",
            "content": [
                "kind": "file_change", "toolName": "Write",
                "input": ["file_path": "/repo/B.swift"],
                "text": "File created successfully at: /repo/B.swift (file state is current in your context — no need to Read it back)",
                "structuredPatch": [[
                    "oldStart": 0, "oldLines": 0, "newStart": 1, "newLines": 2,
                    "lines": ["+a", "+b"],
                ]],
            ],
            "source": ["itemId": "w1"],
            "orderSeq": 1, "revision": 1, "updatedSeq": 1, "contentHash": "w1",
        ])
        let editItem: V2TimelineItem = try decode([
            "id": "e1", "sessionId": "session", "type": "tool", "status": "done",
            "content": [
                "kind": "file_change", "toolName": "Edit",
                "structuredPatch": [[
                    "oldStart": 1, "oldLines": 1, "newStart": 1, "newLines": 1,
                    "lines": ["-c", "+d"],
                ]],
            ],
            "source": ["itemId": "e1"],
            "orderSeq": 2, "revision": 1, "updatedSeq": 1, "contentHash": "e1",
        ])
        #expect(CodeToolLabelPlan.diffStat(for: [
            CodeToolCall(item: writeItem, kind: .write),
            CodeToolCall(item: editItem, kind: .edit),
        ]) == CodeDiffStat(added: 3, removed: 1))
    }

    // MARK: Diff badge counts

    @Test func diffBadgeCountsStructuredPatchLines() throws {
        let item: V2TimelineItem = try decode([
            "id": "e1", "sessionId": "session", "type": "tool", "status": "done",
            "content": [
                "kind": "file_change", "toolName": "Edit",
                "structuredPatch": [[
                    "oldStart": 1, "oldLines": 2, "newStart": 1, "newLines": 3,
                    "lines": [" a", "-b", "+c", "+d"],
                ]],
            ],
            "source": ["itemId": "e1"],
            "orderSeq": 1, "revision": 1, "updatedSeq": 1, "contentHash": "e1",
        ])
        let call = CodeToolCall(item: item, kind: .edit)
        #expect(CodeToolLabelPlan.diffStat(for: [call])
            == CodeDiffStat(added: 2, removed: 1))
    }

    @Test func diffBadgeCountsBareChangeDiff() throws {
        let item: V2TimelineItem = try decode([
            "id": "e2", "sessionId": "session", "type": "tool", "status": "done",
            "content": [
                "kind": "file_change", "toolName": "Edit",
                "changes": [[
                    "path": "a.swift", "action": "update",
                    "diff": "--- a.swift\n+++ a.swift\n@@\n-let a = 1\n+let a = 2\n",
                ]],
            ],
            "source": ["itemId": "e2"],
            "orderSeq": 1, "revision": 1, "updatedSeq": 1, "contentHash": "e2",
        ])
        let call = CodeToolCall(item: item, kind: .edit)
        #expect(CodeToolLabelPlan.diffStat(for: [call])
            == CodeDiffStat(added: 1, removed: 1))
    }

    // MARK: Official failure counts and target rule

    /// `0x10288e3c0`: each category's `failed` is the number of distinct
    /// keys whose status is failed, using the same key as `count`.
    @Test func failedCallsAreCountedPerCategory() throws {
        let calls = [
            try makeCall("r1", name: "Read", kind: .read,
                         input: ["file_path": "/repo/A.swift"], status: "failed"),
            try makeCall("r2", name: "Read", kind: .read,
                         input: ["file_path": "/repo/B.swift"]),
            try makeCall("b1", name: "Bash", kind: .bash,
                         input: ["command": "ls"], status: "failed"),
            try makeCall("b2", name: "Bash", kind: .bash,
                         input: ["command": "pwd"], status: "failed"),
        ]
        let plan = try #require(CodeToolLabelPlan.make(calls: calls, cwd: nil))
        #expect(plan.phrases == [
            .init(verb: .read, unit: .files, count: 2, failed: 1),
            .init(verb: .ran, unit: .commands, count: 2, failed: 2),
        ])
    }

    @Test func repeatedFailedReadOfOneFileCountsOnce() throws {
        let calls = [
            try makeCall("r1", name: "Read", kind: .read,
                         input: ["file_path": "/repo/A.swift"], status: "failed"),
            try makeCall("r2", name: "Read", kind: .read,
                         input: ["file_path": "/repo/A.swift"], status: "failed"),
        ]
        let plan = try #require(CodeToolLabelPlan.make(calls: calls, cwd: nil))
        #expect(plan.verb == .read)
        #expect(plan.target == "/repo/A.swift")
        #expect(plan.failed == 2)
        #expect(plan.total == 2)
    }

    /// The official single-target predicate is target equality only
    /// (`0x10252df70`); the first call supplies the verb.
    @Test func differentToolsOnOneTargetKeepTheSingleTargetShape() throws {
        let calls = [
            try makeCall("r1", name: "Read", kind: .read,
                         input: ["file_path": "/repo/A.swift"]),
            try makeCall("e1", name: "Edit", kind: .edit,
                         input: ["file_path": "/repo/A.swift"]),
        ]
        let plan = try #require(CodeToolLabelPlan.make(calls: calls, cwd: nil))
        #expect(plan.verb == .read)
        #expect(plan.target == "/repo/A.swift")
        #expect(plan.phrases.isEmpty)
    }

    @Test func differentTargetsFallBackToTheSummary() throws {
        let calls = [
            try makeCall("r1", name: "Read", kind: .read,
                         input: ["file_path": "/repo/A.swift"]),
            try makeCall("e1", name: "Edit", kind: .edit,
                         input: ["file_path": "/repo/B.swift"]),
        ]
        let plan = try #require(CodeToolLabelPlan.make(calls: calls, cwd: nil))
        #expect(plan.verb == nil)
        #expect(plan.phrases == [
            .init(verb: .read, unit: .files, count: 1),
            .init(verb: .edited, unit: .files, count: 1),
        ])
    }

    /// `0x10288fa10`: a call that is neither a diff nor failed makes the
    /// whole span show no badge.
    @Test func diffBadgeIgnoresMixWithNonDiffCalls() throws {
        let read = try makeCall("r1", name: "Read", kind: .read,
                                input: ["file_path": "/repo/A.swift"])
        let editItem: V2TimelineItem = try decode([
            "id": "e1", "sessionId": "session", "type": "tool", "status": "done",
            "content": [
                "kind": "file_change", "toolName": "Edit",
                "structuredPatch": [[
                    "oldStart": 1, "oldLines": 1, "newStart": 1, "newLines": 1,
                    "lines": ["-old", "+new"],
                ]],
            ],
            "source": ["itemId": "e1"],
            "orderSeq": 2, "revision": 1, "updatedSeq": 1, "contentHash": "e1",
        ])
        let edit = CodeToolCall(item: editItem, kind: .edit)
        #expect(CodeToolLabelPlan.diffStat(for: [read, edit]) == nil)
    }

    @Test func diffBadgeSkipsFailedEdit() throws {
        let item: V2TimelineItem = try decode([
            "id": "e3", "sessionId": "session", "type": "tool", "status": "failed",
            "content": [
                "kind": "file_change", "toolName": "Edit",
                "structuredPatch": [[
                    "oldStart": 1, "oldLines": 1, "newStart": 1, "newLines": 1,
                    "lines": ["-old", "+new"],
                ]],
            ],
            "source": ["itemId": "e3"],
            "orderSeq": 1, "revision": 1, "updatedSeq": 1, "contentHash": "e3",
        ])
        let call = CodeToolCall(item: item, kind: .edit)
        #expect(CodeToolLabelPlan.diffStat(for: [call]) == nil)
    }

    @Test func diffBadgeSumsOnlyTheSettledCalls() throws {
        let failedItem: V2TimelineItem = try decode([
            "id": "e4", "sessionId": "session", "type": "tool", "status": "failed",
            "content": [
                "kind": "file_change", "toolName": "Edit",
                "structuredPatch": [[
                    "oldStart": 1, "oldLines": 1, "newStart": 1, "newLines": 1,
                    "lines": ["-a", "+b"],
                ]],
            ],
            "source": ["itemId": "e4"],
            "orderSeq": 1, "revision": 1, "updatedSeq": 1, "contentHash": "e4",
        ])
        let doneItem: V2TimelineItem = try decode([
            "id": "e5", "sessionId": "session", "type": "tool", "status": "done",
            "content": [
                "kind": "file_change", "toolName": "Edit",
                "structuredPatch": [[
                    "oldStart": 1, "oldLines": 1, "newStart": 1, "newLines": 3,
                    "lines": ["-c", "+d", "+e"],
                ]],
            ],
            "source": ["itemId": "e5"],
            "orderSeq": 2, "revision": 1, "updatedSeq": 1, "contentHash": "e5",
        ])
        #expect(CodeToolLabelPlan.diffStat(for: [
            CodeToolCall(item: failedItem, kind: .edit),
            CodeToolCall(item: doneItem, kind: .edit),
        ]) == CodeDiffStat(added: 2, removed: 1))
    }
}

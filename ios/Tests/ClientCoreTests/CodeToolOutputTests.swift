import Foundation
import Testing
@testable import ClientCore

// W4 red-team regression set for the Code page's five-case output parser.
//
// The parser is pure (`Models/Chat/Code/CodeToolOutput.swift`, ClientCore, no
// SwiftUI), so these tests pin the wire mapping without UIKit. The failure
// cases are the ones that matter most: a failed Edit/Write must never render
// its attempted patch as a successful diff, and a Codex file-change row with
// only a patch must not become an empty output.

private func makeOutput(_ content: [String: Any],
                        status: String = "done",
                        kind: CodeToolKind = .bash) throws -> CodeToolOutput {
    let item: V2TimelineItem = try decode([
        "id": "item",
        "sessionId": "session",
        "type": "tool",
        "status": status,
        "content": content,
        "source": ["itemId": "item"],
        "orderSeq": 1,
        "revision": 1,
        "updatedSeq": 1,
        "contentHash": "item",
    ])
    return CodeToolOutput(item: item, kind: kind)
}

private let unifiedPatch = "--- a/x\n+++ b/x\n@@ -1,2 +1,2 @@\n-old\n+new\n same"

@Suite("Code tool output parser")
struct CodeToolOutputTests {

    // MARK: Text aliases

    @Test func textReadsOutputField() throws {
        #expect(try makeOutput(["output": "hello"]) == .text("hello"))
    }

    @Test func textReadsOutputTextField() throws {
        #expect(try makeOutput(["outputText": "from outputText"]) == .text("from outputText"))
    }

    @Test func textReadsResultField() throws {
        #expect(try makeOutput(["result": "from result"]) == .text("from result"))
    }

    @Test func textReadsTextField() throws {
        #expect(try makeOutput(["text": "from text"]) == .text("from text"))
    }

    @Test func previewIsUsedOnlyWhenNoFullValueExists() throws {
        #expect(try makeOutput(["outputPreview": "preview"]) == .text("preview"))
        #expect(try makeOutput(["output": "full", "outputPreview": "preview"]) == .text("full"))
    }

    @Test func errorSurfacesWhenOutputIsEmpty() throws {
        #expect(try makeOutput(["output": "", "error": "boom"], status: "failed")
            == .text("boom"))
    }

    // MARK: Failed file changes (P1)

    @Test func failedEditPrefersErrorOverChangesDiff() throws {
        let output = try makeOutput([
            "error": "edit failed",
            "changes": [["path": "a.swift", "action": "update", "diff": unifiedPatch]],
        ], status: "failed", kind: .edit)
        #expect(output == .text("edit failed"))
    }

    @Test func failedWriteWithChangesButNoErrorDoesNotRenderDiff() throws {
        let output = try makeOutput([
            "changes": [["path": "a.swift", "action": "add", "diff": "line1"]],
        ], status: "failed", kind: .write)
        // Raw text is allowed when the wire has no message; a diff is not.
        #expect(output == .text("a.swift\nline1"))
    }

    @Test func failedMultiEditWithErrorAndPatchShowsError() throws {
        let output = try makeOutput([
            "error": "patch did not apply",
            "patch": unifiedPatch,
        ], status: "failed", kind: .edit)
        #expect(output == .text("patch did not apply"))
    }

    @Test func failedEditWithUnmappedKindStillSuppressesDiff() throws {
        let output = try makeOutput([
            "toolName": "MultiEdit",
            "error": "multi edit failed",
            "changes": [["path": "a.swift", "action": "update", "diff": unifiedPatch]],
        ], status: "failed", kind: .other)
        #expect(output == .text("multi edit failed"))
    }

    @Test func failedTodoDoesNotUseInputList() throws {
        let output = try makeOutput([
            "error": "todo update failed",
            "input": ["todos": [["content": "a", "status": "completed"]]],
        ], status: "failed", kind: .todo)
        #expect(output == .text("todo update failed"))
    }

    // MARK: Codex file changes (P2-1)

    @Test func codexFileChangePatchBecomesDiff() throws {
        let output = try makeOutput([
            "kind": "file_change",
            "patch": unifiedPatch,
        ], kind: .edit)
        guard case let .diff(diff) = output else {
            Issue.record("A file-change patch with a real hunk must render as a diff")
            return
        }
        #expect(diff.lines.count == 6)
        #expect(diff.added == 1)
        #expect(diff.removed == 1)
    }

    @Test func codexFileChangeMalformedPatchFallsBackToText() throws {
        let output = try makeOutput([
            "kind": "file_change",
            "patch": "not a unified diff",
        ], kind: .edit)
        #expect(output == .text("not a unified diff"))
    }

    @Test func codexFileChangeChangesPatchFallsBackToText() throws {
        let output = try makeOutput([
            "kind": "file_change",
            "changes": [["path": "a.swift", "patch": "not a unified diff"]],
        ], kind: .edit)
        #expect(output == .text("a.swift\nnot a unified diff"))
    }

    // MARK: Diff detection gate (P2-2)

    @Test func proseWithAtAtStaysText() throws {
        let output = try makeOutput([
            "output": "@@ - not a real hunk\n@@ just prose",
        ])
        #expect(output == .text("@@ - not a real hunk\n@@ just prose"))
    }

    @Test func proseStartingWithDashStaysText() throws {
        let output = try makeOutput(["output": "- item one\n- item two"])
        #expect(output == .text("- item one\n- item two"))
    }

    @Test func unifiedDiffWithOfficialHunkBecomesDiff() throws {
        let output = try makeOutput(["output": unifiedPatch], kind: .edit)
        guard case let .diff(diff) = output else {
            Issue.record("A real hunk must render as a diff")
            return
        }
        #expect(diff.lines.count == 6)
        #expect(diff.added == 1)
        #expect(diff.removed == 1)
        #expect(diff.maxLineNumber == 2)
    }

    @Test func structuredDiffUsesProvidedStatAndLineCount() throws {
        let lines: [[String: Any]] = (1...1200).map { index in
            [
                "type": index % 3 == 0 ? "remove" : "add",
                "content": "line \(index)",
                "oldLineNumber": index,
                "newLineNumber": index,
            ]
        }
        let output = try makeOutput([
            "output": [
                "kind": "diff",
                "lines": lines,
                "lineStat": ["addedLineCount": 800, "removedLineCount": 400],
            ],
        ], kind: .edit)
        guard case let .diff(diff) = output else {
            Issue.record("A structured diff must render as a diff")
            return
        }
        #expect(diff.lines.count == 1200)
        #expect(diff.added == 800)
        #expect(diff.removed == 400)
        #expect(diff.maxLineNumber == 1200)
    }

    @Test func structuredDiffWithoutStatComputesCounts() throws {
        let output = try makeOutput([
            "output": [
                "lines": [
                    ["type": "add", "content": "a", "newLineNumber": 1],
                    ["type": "remove", "content": "b", "oldLineNumber": 1],
                    ["type": "normal", "content": "c", "oldLineNumber": 2, "newLineNumber": 2],
                ],
            ],
        ], kind: .edit)
        guard case let .diff(diff) = output else {
            Issue.record("Structured lines must render as a diff")
            return
        }
        #expect(diff.added == 1)
        #expect(diff.removed == 1)
        #expect(diff.maxLineNumber == 2)
    }

    // MARK: Claude `structuredPatch` (the CLI's own hunk payload)

    @Test func structuredPatchBecomesNumberedDiff() throws {
        let output = try makeOutput([
            // The real wire keeps the result text next to structuredPatch;
            // the diff must win over the text.
            "output": "The file has been updated.",
            "structuredPatch": [[
                "oldStart": 10, "oldLines": 3,
                "newStart": 10, "newLines": 4,
                "lines": [
                    " let a = 1",
                    "-let b = 2",
                    "+let b = 3",
                    "+let c = 4",
                    " let d = 5",
                ],
            ]],
        ], kind: .edit)
        guard case let .diff(diff) = output else {
            Issue.record("structuredPatch must render as a diff")
            return
        }
        #expect(diff.lines.count == 6)
        #expect(diff.added == 2)
        #expect(diff.removed == 1)
        #expect(diff.maxLineNumber == 13)

        let header = diff.lines[0]
        #expect(header.kind == .hunk)
        #expect(header.text == "@@ -10,3 +10,4 @@")
        let delete = diff.lines[2]
        #expect(delete.kind == .delete)
        #expect(delete.text == "let b = 2")
        #expect(delete.oldLine == 11)
        #expect(delete.newLine == nil)
        let add = diff.lines[3]
        #expect(add.kind == .add)
        #expect(add.text == "let b = 3")
        #expect(add.oldLine == nil)
        #expect(add.newLine == 11)
        #expect(diff.lines[5].oldLine == 12)
        #expect(diff.lines[5].newLine == 13)
    }

    @Test func failedEditPrefersErrorOverStructuredPatch() throws {
        let output = try makeOutput([
            "error": "string not found",
            "structuredPatch": [[
                "oldStart": 1, "oldLines": 1, "newStart": 1, "newLines": 1,
                "lines": ["-old", "+new"],
            ]],
        ], status: "failed", kind: .edit)
        #expect(output == .text("string not found"))
    }

    // MARK: AA connector file-change string (bare `@@`)

    @Test func declaredChangeDiffWithBareHunkBecomesDiff() throws {
        let output = try makeOutput([
            "output": "The file has been updated.",
            "changes": [[
                "path": "a.swift", "action": "update", "toolName": "Edit",
                "diff": "--- a.swift\n+++ a.swift\n@@\n-let a = 1\n+let a = 2\n",
            ]],
        ], kind: .edit)
        guard case let .diff(diff) = output else {
            Issue.record("A declared change diff must render as a diff")
            return
        }
        // File headers and the bare `@@` are dropped; the two body lines stay.
        #expect(diff.lines.count == 2)
        #expect(diff.lines[0].kind == .delete)
        #expect(diff.lines[0].text == "let a = 1")
        #expect(diff.lines[1].kind == .add)
        #expect(diff.lines[1].text == "let a = 2")
        #expect(diff.added == 1)
        #expect(diff.removed == 1)
    }

    @Test func proseInOutputIsNotAChangeDiff() throws {
        let output = try makeOutput([
            "output": "note\n@@\n+not a diff",
        ], kind: .edit)
        #expect(output == .text("note\n@@\n+not a diff"))
    }

    // MARK: Todos

    @Test func todosEmptyArrayIsCleared() throws {
        let output = try makeOutput(["input": ["todos": []]], kind: .todo)
        #expect(output == .todos([]))
    }

    @Test func todosThreeStatesFromInput() throws {
        let output = try makeOutput([
            "input": [
                "todos": [
                    ["content": "a", "status": "completed"],
                    ["content": "b", "status": "in_progress"],
                    ["content": "c", "status": "pending"],
                ],
            ],
        ], kind: .todo)
        guard case let .todos(todos) = output else {
            Issue.record("TodoWrite input must render as todos")
            return
        }
        #expect(todos.map(\.status) == [.completed, .inProgress, .pending])
    }

    @Test func todosFromOutputArray() throws {
        let output = try makeOutput([
            "output": [["content": "a", "status": "completed"]],
        ], kind: .todo)
        #expect(output == .todos([
            CodeToolTodo(id: 0, content: "a", status: .completed),
        ]))
    }

    // MARK: Submitted answers

    @Test func answersArrayParsesPairs() throws {
        let output = try makeOutput([
            "output": [
                ["question": "Q1", "answer": "A1"],
                ["question": "Q2", "answer": "A2"],
            ],
        ], kind: .question)
        #expect(output == .submittedAnswers([
            CodeToolSubmittedAnswer(id: 0, question: "Q1", answer: "A1"),
            CodeToolSubmittedAnswer(id: 1, question: "Q2", answer: "A2"),
        ]))
    }

    @Test func answersDictionaryParsesPairs() throws {
        let output = try makeOutput([
            "output": ["answers": ["Q2": "A2", "Q1": "A1"]],
        ], kind: .question)
        // JSON objects have no order; the parser sorts the keys.
        #expect(output == .submittedAnswers([
            CodeToolSubmittedAnswer(id: 0, question: "Q1", answer: "A1"),
            CodeToolSubmittedAnswer(id: 1, question: "Q2", answer: "A2"),
        ]))
    }

    @Test func answersMultiSelectArrayJoins() throws {
        let output = try makeOutput([
            "output": ["submittedAnswers": [
                ["question": "Q", "answer": ["A", "B"]],
            ]],
        ], kind: .question)
        #expect(output == .submittedAnswers([
            CodeToolSubmittedAnswer(id: 0, question: "Q", answer: "A, B"),
        ]))
    }

    @Test func questionInputAnswersParse() throws {
        let output = try makeOutput([
            "input": ["questions": [
                ["question": "Q1", "answer": "A1"],
            ]],
        ], kind: .question)
        #expect(output == .submittedAnswers([
            CodeToolSubmittedAnswer(id: 0, question: "Q1", answer: "A1"),
        ]))
    }

    /// Device report 2026-10-23: the Edit detail showed an "Answers" section
    /// made of the call's own input fields. An Edit input is an all-scalar map
    /// with no structural key, which matched the bare question→answer
    /// heuristic. Answers must never be derived from a non-question input.
    @Test func editInputIsNeverSubmittedAnswers() throws {
        let output = try makeOutput([
            "input": [
                "file_path": "/tmp/MEMORY.md",
                "old_string": "- old",
                "new_string": "- new",
                "replace_all": false,
            ],
        ], kind: .edit)
        #expect(output == .none)
    }

    /// The explicit wrapper still names the answers case for any tool: only
    /// the *bare* map heuristic is gated.
    @Test func explicitAnswersWrapperWorksForAnyTool() throws {
        let output = try makeOutput([
            "output": ["answers": ["Q1": "A1"]],
        ], kind: .bash)
        #expect(output == .submittedAnswers([
            CodeToolSubmittedAnswer(id: 0, question: "Q1", answer: "A1"),
        ]))
    }

    @Test func explicitAnswersWrapperInInputWorksForAnyTool() throws {
        let output = try makeOutput([
            "input": ["submittedAnswers": [["question": "Q1", "answer": "A1"]]],
        ], kind: .bash)
        #expect(output == .submittedAnswers([
            CodeToolSubmittedAnswer(id: 0, question: "Q1", answer: "A1"),
        ]))
    }

    /// An explicit answers tag names the shape; the tag key is structural and
    /// must not stop a bare map from parsing.
    @Test func typedAnswersTagAllowsBareMap() throws {
        let output = try makeOutput([
            "output": ["kind": "answers", "Q1": "A1"],
        ], kind: .bash)
        #expect(output == .submittedAnswers([
            CodeToolSubmittedAnswer(id: 0, question: "Q1", answer: "A1"),
        ]))
    }

    // MARK: Plan / empty / oversized

    @Test func approvedPlanTagIsPlaceholder() throws {
        let output = try makeOutput([
            "output": ["kind": "approved_plan"],
        ], kind: .plan)
        #expect(output == .approvedPlan)
    }

    @Test func emptyContentIsNone() throws {
        #expect(try makeOutput([:]) == .none)
    }

    @Test func oversizedTextIsPreserved() throws {
        let text = String(repeating: "x", count: 300_000)
        let output = try makeOutput(["output": text])
        guard case let .text(parsed) = output else {
            Issue.record("A large text result must stay text")
            return
        }
        #expect(parsed.count == 300_000)
    }

    /// A Read result is one long whole-file text; the detail page must keep
    /// every character (the b643 blank card was a renderer failure, not a
    /// parser one).
    @Test func longReadOutputIsPreserved() throws {
        let text = (1...298).map { "row \($0) of the long read fixture" }
            .joined(separator: "\n")
        let output = try makeOutput(["output": text], kind: .read)
        guard case let .text(parsed) = output else {
            Issue.record("A long Read result must stay text")
            return
        }
        #expect(parsed.count == text.count)
        #expect(!output.isEmpty)
    }

    /// The detail page hides a text output whose body has no glyphs; a
    /// whitespace-only result would otherwise draw a header over a blank card.
    @Test func whitespaceOnlyTextIsEmpty() throws {
        let output = try makeOutput(["output": " \n\t "])
        #expect(output == .text(" \n\t "))
        #expect(output.isEmpty)
    }

    @Test func typedTextObjectIsNotPrettyPrinted() throws {
        let output = try makeOutput([
            "output": ["kind": "text", "text": "plain text"],
        ])
        #expect(output == .text("plain text"))
    }
}

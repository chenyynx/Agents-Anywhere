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

    @Test func typedTextObjectIsNotPrettyPrinted() throws {
        let output = try makeOutput([
            "output": ["kind": "text", "text": "plain text"],
        ])
        #expect(output == .text("plain text"))
    }
}

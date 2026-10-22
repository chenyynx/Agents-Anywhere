import Foundation
import Testing
@testable import ClientCore

// W2: runtime tables are data over the W1 algorithm. These tests pin the three
// ways a table can go wrong: one runtime's names leaking into another, a table
// overriding the classifier with a kind the classifier cannot express, and an
// empty Codex/DSH table inheriting Claude's skip/special rules.

private func makeCall(_ name: String, id: String? = nil, order: Int = 1,
                      wireKind: String? = nil) throws -> CodeToolCall {
    let callID = id ?? name.lowercased()
    let item: V2TimelineItem = try decode([
        "id": callID,
        "sessionId": "session",
        "type": "tool",
        "status": "done",
        "content": ["kind": wireKind ?? "tool_call", "toolName": name],
        "source": ["itemId": callID, "nativeMessageId": "msg-1", "blockIndex": order],
        "orderSeq": order,
        "revision": 1,
        "updatedSeq": order,
        "contentHash": callID,
    ])
    return CodeToolCall(item: item)
}

/// The ids of the single span in `segments`, or nil (with a recorded issue)
/// when the shape is not exactly one span.
private func singleSpanIds(_ segments: [CodeToolSegment],
                           _ context: String) -> [String]? {
    guard segments.count == 1, case let .span(calls) = segments[0] else {
        Issue.record("\(context): expected one span, got \(segments)")
        return nil
    }
    return calls.map(\.id)
}

@Suite("Code runtime tool tables")
struct CodeRuntimeToolTableTests {
    @Test func runtimeIdsResolveToTheirTables() {
        #expect(CodeRuntimeToolTable.forRuntime("claude")?.runtime == .claudeCode)
        #expect(CodeRuntimeToolTable.forRuntime("claude_code")?.runtime == .claudeCode)
        #expect(CodeRuntimeToolTable.forRuntime("claude-code")?.runtime == .claudeCode)
        #expect(CodeRuntimeToolTable.forRuntime("CODEX")?.runtime == .codex)
        #expect(CodeRuntimeToolTable.forRuntime("dsh")?.runtime == .dsh)
        #expect(CodeRuntimeToolTable.forRuntime("gemini") == nil)
        #expect(CodeRuntimeToolTable.forRuntime(nil) == nil)
    }

    @Test func tablesDoNotShareEachOthersNames() {
        // Names only one runtime's connector emits stay out of the others.
        #expect(CodeRuntimeToolTable.codex.toolKinds["EnterPlanMode"] == nil)
        #expect(CodeRuntimeToolTable.dsh.toolKinds["EnterPlanMode"] == nil)
        #expect(CodeRuntimeToolTable.claudeCode.toolKinds["apply_patch"] == nil)
        #expect(CodeRuntimeToolTable.dsh.toolKinds["apply_patch"] == nil)
        #expect(CodeRuntimeToolTable.codex.toolKinds["str_replace_editor"] == nil)
        #expect(CodeRuntimeToolTable.claudeCode.toolKinds["str_replace_editor"] == nil)
        // Skip/special rules are Claude's official rule set, not a default.
        #expect(CodeRuntimeToolTable.codex.skippedToolNames.isEmpty)
        #expect(CodeRuntimeToolTable.dsh.skippedToolNames.isEmpty)
        #expect(CodeRuntimeToolTable.codex.specialToolNames.isEmpty)
        #expect(CodeRuntimeToolTable.dsh.specialToolNames.isEmpty)
        #expect(CodeRuntimeToolTable.claudeCode.specialToolNames.count == 3)
    }

    @Test func tableKindOverridesTheSharedClassifier() {
        // A table exists to pin names the shared classifier cannot know.
        #expect(CodeToolKind.classify(name: "Git", wireKind: nil) == .other)
        #expect(CodeRuntimeToolTable.claudeCode.kind(for: "Git") == .bash)
        #expect(CodeToolKind.classify(name: "str_replace_editor", wireKind: nil) == .other)
        #expect(CodeRuntimeToolTable.dsh.kind(for: "str_replace_editor") == .edit)
        // Lookup folds case: Claude emits PascalCase, Codex/DSH lower-case.
        #expect(CodeRuntimeToolTable.claudeCode.kind(for: "read") == .read)
        #expect(CodeRuntimeToolTable.dsh.kind(for: "BASH") == .bash)
    }

    @Test func eachTableCarriesItsObservedNames() {
        // Real-value assertions: deleting a table must not stay green through
        // the shared classifier's fallback. The direct `toolKinds` checks make
        // the data itself load-bearing; the `kind(for:)` checks pin the lookup.
        let claude = CodeRuntimeToolTable.claudeCode
        #expect(claude.toolKinds["Read"] == .read)
        #expect(claude.toolKinds["Edit"] == .edit)
        #expect(claude.toolKinds["Bash"] == .bash)
        #expect(claude.kind(for: "Read") == .read)
        #expect(claude.kind(for: "Edit") == .edit)
        #expect(claude.kind(for: "Bash") == .bash)
        #expect(claude.kind(for: "SomeFutureTool") == .other)

        let codex = CodeRuntimeToolTable.codex
        #expect(codex.toolKinds["apply_patch"] == .edit)
        #expect(codex.toolKinds["file_change"] == .edit)
        #expect(codex.toolKinds["web_search"] == .search)
        #expect(codex.kind(for: "apply_patch") == .edit)
        #expect(codex.kind(for: "file_change") == .edit)
        #expect(codex.kind(for: "web_search") == .search)
        #expect(codex.kind(for: "web_search_preview") == .search)
        #expect(codex.kind(for: "SomeFutureTool") == .other)

        let dsh = CodeRuntimeToolTable.dsh
        #expect(dsh.toolKinds["pwsh"] == .bash)
        #expect(dsh.toolKinds["str_replace_editor"] == .edit)
        #expect(dsh.toolKinds["ask_user_question"] == .question)
        #expect(dsh.kind(for: "bash") == .bash)
        #expect(dsh.kind(for: "pwsh") == .bash)
        #expect(dsh.kind(for: "str_replace_editor") == .edit)
        #expect(dsh.kind(for: "ask_user_question") == .question)
        #expect(dsh.kind(for: "exit_plan_mode") == .plan)
        #expect(dsh.kind(for: "subagent") == .task)
        #expect(dsh.kind(for: "SomeFutureTool") == .other)
    }

    @Test func tableKindWinsOverTheWireKind() {
        // Codex function calls arrive marked `kind: mcp`; a real native name
        // still resolves through the table, not through the wire marker.
        #expect(CodeRuntimeToolTable.codex.kind(for: "apply_patch",
                                                wireKind: "mcp") == .edit)
    }

    @Test func unknownToolsFallBackToOther() {
        for table in CodeRuntimeToolTable.all {
            #expect(table.kind(for: "SomeFutureTool") == .other)
            #expect(table.kind(for: "SomeFutureTool", wireKind: "unknown_kind") == .other)
        }
        // The fallback still understands the wire kinds W1 normalises.
        #expect(CodeRuntimeToolTable.codex.kind(for: "future_command",
                                                wireKind: "command") == .bash)
        #expect(CodeRuntimeToolTable.dsh.kind(for: "mcp__server__tool",
                                              wireKind: "mcp") == .mcp)
        #expect(CodeRuntimeToolTable.claudeCode.kind(for: "AnyName",
                                                     wireKind: "agent_call") == .task)
    }

    @Test func claudeSkipSetDropsCallsWithoutFlushing() throws {
        let calls = [try makeCall("Read", id: "read", order: 1),
                     try makeCall("ExitPlanMode", id: "plan", order: 2),
                     try makeCall("AskUserQuestion", id: "ask", order: 3),
                     try makeCall("Bash", id: "bash", order: 4)]
        let segments = CodeRuntimeToolTable.claudeCode.segments(for: calls)
        #expect(singleSpanIds(segments, "claude skip") == ["read", "bash"])
    }

    @Test func claudeSpecialsFlushTheSpanAndMapToTheirCards() throws {
        let table = CodeRuntimeToolTable.claudeCode
        #expect(table.segmentPolicy.specialToolNames["Workflow"] == .workflow)
        #expect(table.segmentPolicy.specialToolNames["WritingDraft"] == .writingDraft)
        #expect(table.segmentPolicy.specialToolNames["Artifact"] == .artifactCard)
        // backgroundTask is a derived segment (toolUseId lookup), not a wire
        // tool name, so it must not be keyed by name.
        #expect(table.segmentPolicy.specialToolNames["BackgroundTask"] == nil)

        let calls = [try makeCall("Read", id: "read", order: 1),
                     try makeCall("Workflow", id: "workflow", order: 2),
                     try makeCall("Bash", id: "bash", order: 3)]
        let segments = table.segments(for: calls)
        guard segments.count == 3,
              case let .span(before) = segments[0],
              case let .special(kind, call) = segments[1],
              case let .span(after) = segments[2] else {
            Issue.record("expected span / workflow / span, got \(segments)")
            return
        }
        #expect(before.map(\.id) == ["read"])
        #expect(kind == .workflow)
        #expect(call.id == "workflow")
        #expect(after.map(\.id) == ["bash"])
    }

    @Test func codexAndDSHTablesKeepClaudeNamesGrouped() throws {
        // The names Claude skips or special-cases are ordinary calls to the
        // other runtimes: with an empty table they must all land in one span.
        let calls = [try makeCall("Read", id: "read", order: 1),
                     try makeCall("Workflow", id: "workflow", order: 2),
                     try makeCall("ExitPlanMode", id: "plan", order: 3),
                     try makeCall("AskUserQuestion", id: "ask", order: 4)]
        for table in [CodeRuntimeToolTable.codex, CodeRuntimeToolTable.dsh] {
            let segments = table.segments(for: calls)
            #expect(singleSpanIds(segments, "\(table.runtime) plain names")
                == ["read", "workflow", "plan", "ask"])
        }
        // DSH's own question/plan names stay plain calls too.
        let dshCalls = [try makeCall("ask_user_question", id: "ask", order: 1),
                        try makeCall("exit_plan_mode", id: "plan", order: 2)]
        let dshSegments = CodeRuntimeToolTable.dsh.segments(for: dshCalls)
        #expect(singleSpanIds(dshSegments, "dsh names") == ["ask", "plan"])
    }

    @Test func everyTableKindIsSupportedByClassify() {
        // kind -> a (name, wireKind) pair the shared classifier maps to it.
        // A table may only use kinds the classifier can express; otherwise the
        // table and the fallback would disagree about the kind vocabulary.
        let probes: [CodeToolKind: (name: String, wireKind: String?)] = [
            .read: ("Read", nil),
            .edit: ("Edit", nil),
            .write: ("Write", nil),
            .bash: ("Bash", nil),
            .search: ("Grep", nil),
            .todo: ("TodoWrite", nil),
            .task: ("Task", nil),
            .plan: ("ExitPlanMode", nil),
            .question: ("AskUserQuestion", nil),
            .mcp: ("tool", "mcp"),
            .other: ("UnknownTool", nil),
        ]
        for table in CodeRuntimeToolTable.all {
            for (name, kind) in table.toolKinds {
                guard let probe = probes[kind] else {
                    Issue.record("\(table.runtime.rawValue): \(name) uses a kind with no classifier probe")
                    continue
                }
                #expect(CodeToolKind.classify(name: probe.name, wireKind: probe.wireKind) == kind,
                        "\(table.runtime.rawValue): \(name) -> \(kind) is not a classify() kind")
            }
        }
    }

    @Test func claudeSkipSetMatchesTheSharedPolicy() {
        // W1 owns the same official skip set; the two must not drift. The
        // special maps intentionally differ: W1 still carries a
        // `BackgroundTask` name entry, while this table only keys segments the
        // official mapper derives from a tool name (see the file comment).
        let table = CodeRuntimeToolTable.claudeCode
        #expect(table.skippedToolNames
            == CodeToolSegmentPolicy.claudeCode.skippedToolNames)
        for (name, special) in table.specialToolNames {
            #expect(CodeToolSegmentPolicy.claudeCode.specialToolNames[name] == special,
                    "\(name) is not a special in the shared policy")
        }
    }
}

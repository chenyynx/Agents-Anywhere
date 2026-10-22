import Foundation
import Testing
@testable import ClientCore

// W2b: the profile is the runtime-facing composition of W1's algorithm and
// W2's tables. These tests pin the contract: runtime id -> profile selection,
// the generic fallback for anything unknown, no rule leaking between the
// three runtimes, and the one product-level Codex analogy staying inside the
// Codex profile.

private func makeCall(_ name: String, id: String? = nil, order: Int = 1,
                      wireKind: String? = "tool_call",
                      status: String = "done") throws -> CodeToolCall {
    let callID = id ?? name.lowercased()
    var content: [String: Any] = ["toolName": name]
    if let wireKind { content["kind"] = wireKind }
    let item: V2TimelineItem = try decode([
        "id": callID,
        "sessionId": "session",
        "type": "tool",
        "status": status,
        "content": content,
        "source": ["itemId": callID, "nativeMessageId": "msg-1", "blockIndex": order],
        "orderSeq": order,
        "revision": 1,
        "updatedSeq": order,
        "contentHash": callID,
    ])
    return CodeToolCall(item: item)
}

/// The segment sequence in a form that keeps both shape and call order.
private func descriptors(_ segments: [CodeToolSegment]) -> [String] {
    segments.map { segment in
        switch segment {
        case let .span(calls):
            return "span(" + calls.map(\.id).joined(separator: ",") + ")"
        case let .special(kind, call):
            return "special(\(kind),\(call.id))"
        }
    }
}

@Suite("Code runtime profiles")
struct CodeRuntimeProfileTests {
    @Test func runtimeIdsSelectTheirProfiles() {
        #expect(CodeRuntimeProfile(runtime: "claude") == .claudeCode)
        #expect(CodeRuntimeProfile(runtime: "claude_code") == .claudeCode)
        #expect(CodeRuntimeProfile(runtime: "claude-code") == .claudeCode)
        #expect(CodeRuntimeProfile(runtime: "CLAUDE") == .claudeCode)
        #expect(CodeRuntimeProfile(runtime: "codex") == .codex)
        #expect(CodeRuntimeProfile(runtime: "CODEX") == .codex)
        #expect(CodeRuntimeProfile(runtime: "dsh") == .dsh)
        #expect(CodeRuntimeProfile(runtime: "DSH") == .dsh)
    }

    @Test func unknownRuntimeFallsBackToGenericWithoutATable() {
        for runtime in [nil, "", "gemini", "opencode", "  claude"] as [String?] {
            let profile = CodeRuntimeProfile(runtime: runtime)
            #expect(profile == .generic, "runtime \(String(describing: runtime))")
            #expect(profile.family == .generic)
            #expect(profile.toolTable == nil)
            #expect(profile.skippedToolNames.isEmpty)
            #expect(profile.specialToolNames.isEmpty)
            #expect(profile.subagentShape == .unspecified)
            #expect(profile.toolRowRole == .unspecified)
        }
    }

    @Test func sessionMetaResolvesTheDeclaredRuntimeTypeFirst() throws {
        // `runtimeType` is the connector's declared type; `runtime` is the
        // session creation type. The server defaults the former to the
        // latter, so preferring the declared one is an alias pick.
        let base = try fixtureObject("snapshot")["session"] as! [String: Any]

        var declared = base
        declared["runtime"] = "claude"
        declared["runtimeType"] = "codex"
        let codexMeta: V2SessionMeta = try decode(declared)
        #expect(CodeRuntimeProfile(meta: codexMeta).family == .codex)

        var fallback = base
        fallback["runtime"] = "dsh"
        fallback.removeValue(forKey: "runtimeType")
        let dshMeta: V2SessionMeta = try decode(fallback)
        #expect(CodeRuntimeProfile(meta: dshMeta).family == .dsh)
    }

    @Test func eachProfileCarriesItsOwnPolicy() {
        #expect(CodeRuntimeProfile.claudeCode.skippedToolNames
            == ["ExitPlanMode", "AskUserQuestion"])
        #expect(CodeRuntimeProfile.claudeCode.specialToolNames["Workflow"] == .workflow)
        #expect(CodeRuntimeProfile.claudeCode.specialToolNames["WritingDraft"] == .writingDraft)
        #expect(CodeRuntimeProfile.claudeCode.specialToolNames["Artifact"] == .artifactCard)
        // `backgroundTask` (and `threadSessionCard`) are derived segments, not
        // wire tool names, so they must not be keyed by name.
        #expect(CodeRuntimeProfile.claudeCode.specialToolNames["BackgroundTask"] == nil)
        #expect(CodeRuntimeProfile.claudeCode.specialToolNames.count == 3)

        #expect(CodeRuntimeProfile.codex.skippedToolNames == ["request_user_input"])
        #expect(CodeRuntimeProfile.codex.specialToolNames.isEmpty)

        #expect(CodeRuntimeProfile.dsh.segmentPolicy == .dsh)
        #expect(CodeRuntimeProfile.dsh.skippedToolNames.isEmpty)
        #expect(CodeRuntimeProfile.dsh.specialToolNames.isEmpty)

        #expect(CodeRuntimeProfile.generic.segmentPolicy == .generic)
    }

    @Test func codexQuestionnaireSkipOnlyAppliesToCodex() throws {
        // [I] product decision: Codex's request_user_input is treated like
        // Claude's AskUserQuestion, so it produces no segment and does not
        // flush the open span. The same name is an ordinary call everywhere
        // else — this is the rule that must not leak.
        let calls = [try makeCall("Read", id: "read", order: 1),
                     try makeCall("request_user_input", id: "ask", order: 2),
                     try makeCall("Bash", id: "bash", order: 3)]

        #expect(descriptors(CodeRuntimeProfile.codex.segments(for: calls))
            == ["span(read,bash)"])
        for profile in [CodeRuntimeProfile.claudeCode, .dsh, .generic] {
            #expect(descriptors(profile.segments(for: calls))
                == ["span(read,ask,bash)"], "\(profile.family)")
        }
    }

    @Test func claudeSpecialsStayInTheClaudeProfile() throws {
        let calls = [try makeCall("Read", id: "read", order: 1),
                     try makeCall("Workflow", id: "workflow", order: 2),
                     try makeCall("Bash", id: "bash", order: 3)]

        #expect(descriptors(CodeRuntimeProfile.claudeCode.segments(for: calls))
            == ["span(read)", "special(workflow,workflow)", "span(bash)"])
        // Workflow is not a Codex/DSH/generic concept: it groups as a plain
        // call there instead of being guessed into a dedicated card.
        for profile in [CodeRuntimeProfile.codex, .dsh, .generic] {
            #expect(descriptors(profile.segments(for: calls))
                == ["span(read,workflow,bash)"], "\(profile.family)")
        }
    }

    @Test func threeRuntimesDoNotShareToolNames() {
        // Names only one runtime's connector emits stay out of the others.
        #expect(CodeRuntimeProfile.claudeCode.kind(for: "str_replace_editor") == .other)
        #expect(CodeRuntimeProfile.codex.kind(for: "str_replace_editor") == .other)
        #expect(CodeRuntimeProfile.dsh.kind(for: "str_replace_editor") == .edit)

        // `Git` is a Claude-table-only name: the shared classifier does not
        // know it, so the other profiles must not inherit the kind.
        #expect(CodeRuntimeProfile.claudeCode.kind(for: "Git") == .bash)
        #expect(CodeRuntimeProfile.codex.kind(for: "Git") == .other)
        #expect(CodeRuntimeProfile.dsh.kind(for: "Git") == .other)

        #expect(CodeRuntimeProfile.claudeCode.kind(for: "request_user_input") == .other)
        #expect(CodeRuntimeProfile.dsh.kind(for: "request_user_input") == .other)

        // Table membership, not the shared classifier, is what a table adds.
        #expect(CodeRuntimeProfile.codex.toolTable?.toolKinds["apply_patch"] == .edit)
        #expect(CodeRuntimeProfile.claudeCode.toolTable?.toolKinds["apply_patch"] == nil)
        #expect(CodeRuntimeProfile.dsh.toolTable?.toolKinds["apply_patch"] == nil)
        #expect(CodeRuntimeProfile.codex.toolTable?.toolKinds["web_search"] == .search)
        #expect(CodeRuntimeProfile.dsh.toolTable?.toolKinds["web_search"] == .search)
        #expect(CodeRuntimeProfile.claudeCode.toolTable?.toolKinds["web_search"] == nil)
    }

    @Test func codexObservedToolKinds() {
        // connector/connector/runtimes/codex/timeline/raw_content.py:145,165;
        // commandExecution carries `content.kind = command`
        // (projection.py:272-279), which the shared classifier reads as bash.
        #expect(CodeRuntimeProfile.codex.kind(for: "apply_patch") == .edit)
        #expect(CodeRuntimeProfile.codex.kind(for: "file_change") == .edit)
        #expect(CodeRuntimeProfile.codex.kind(for: "web_search") == .search)
        #expect(CodeRuntimeProfile.codex.kind(for: "shell") == .bash)
        #expect(CodeRuntimeProfile.codex.kind(for: "any_future_command",
                                               wireKind: "command") == .bash)
        #expect(CodeRuntimeProfile.codex.kind(for: "SomeFutureTool") == .other)
    }

    @Test func dshObservedToolKinds() {
        // dsh-bridge-next/src/host/dsh-runtime/tools.ts:11-33.
        #expect(CodeRuntimeProfile.dsh.kind(for: "bash") == .bash)
        #expect(CodeRuntimeProfile.dsh.kind(for: "pwsh") == .bash)
        #expect(CodeRuntimeProfile.dsh.kind(for: "web_search", wireKind: "web_search") == .search)
        #expect(CodeRuntimeProfile.dsh.kind(for: "ask_user_question") == .question)
        #expect(CodeRuntimeProfile.dsh.kind(for: "exit_plan_mode") == .plan)
        #expect(CodeRuntimeProfile.dsh.kind(for: "subagent") == .task)
        #expect(CodeRuntimeProfile.dsh.kind(for: "subagent_fork") == .task)
        #expect(CodeRuntimeProfile.dsh.kind(for: "mcp__server__tool", wireKind: "mcp") == .mcp)
        #expect(CodeRuntimeProfile.dsh.kind(for: "run_code", wireKind: "tool_call") == .other)
    }

    @Test func genericProfileKeepsTheSharedClassifier() {
        #expect(CodeRuntimeProfile.generic.kind(for: "Read") == .read)
        #expect(CodeRuntimeProfile.generic.kind(for: "apply_patch") == .edit)
        #expect(CodeRuntimeProfile.generic.kind(for: "future_command",
                                                wireKind: "command") == .bash)
        #expect(CodeRuntimeProfile.generic.kind(for: "mcp__server__tool",
                                                wireKind: "mcp") == .mcp)
        #expect(CodeRuntimeProfile.generic.kind(for: "str_replace_editor") == .other)
    }

    @Test func subagentShapesArePerRuntime() {
        #expect(CodeRuntimeProfile.claudeCode.subagentShape == .claudeAgentCard)
        #expect(CodeRuntimeProfile.codex.subagentShape == .codexCollabAgent)
        #expect(CodeRuntimeProfile.dsh.subagentShape == .dshAgentTools)
        #expect(CodeRuntimeProfile.generic.subagentShape == .unspecified)
    }

    @Test func toolRowRolesArePerRuntime() {
        // DSH projects tool rows as `role = assistant`
        // (dsh-bridge-next/src/host/dsh-runtime/history.ts:92); Claude/Codex
        // use `role = tool`. The page must group by message identity, never by
        // role, or DSH tool rows would read as message bodies.
        #expect(CodeRuntimeProfile.claudeCode.toolRowRole == .tool)
        #expect(CodeRuntimeProfile.codex.toolRowRole == .tool)
        #expect(CodeRuntimeProfile.dsh.toolRowRole == .assistant)
        #expect(CodeRuntimeProfile.generic.toolRowRole == .unspecified)
    }
}

import Foundation

// Per-runtime tool tables for the Code page.
//
// The grouping algorithm is runtime-neutral and lives in CodeToolSegments.swift.
// What differs between Claude Code, Codex and DSH is data: which names are
// skipped, which names render as a dedicated card, and which icon/title family
// a name belongs to. Those tables live here so the algorithm never learns a
// runtime name.
//
// Kind lookup is table first, `CodeToolKind.classify` second, then `.other`.
// A table only lists names observed in that runtime's connector/projection
// code (source line next to the entry); `[I]` marks a kind inferred from the
// official client's category/title table where the connector does not spell
// the mapping out. Names nobody has observed are never guessed — they take
// the classifier's answer or fall through to `.other`.

nonisolated enum CodeRuntime: String, Hashable, Sendable, CaseIterable {
    case claudeCode = "claude"
    case codex
    case dsh

    /// The runtime ids AA publishes in `runtime` / `runtimeType`. The two
    /// underscore/hyphen spellings are aliases, matching
    /// `CodeToolSegmentPolicy.forRuntime`.
    init?(wireValue: String?) {
        switch wireValue?.lowercased() {
        case "claude", "claude_code", "claude-code": self = .claudeCode
        case "codex": self = .codex
        case "dsh": self = .dsh
        default: return nil
        }
    }
}

nonisolated struct CodeRuntimeToolTable: Hashable, Sendable {
    let runtime: CodeRuntime

    /// The runtime's own tool names, exactly as its wire emits them.
    ///
    /// Lookup folds case (Claude emits `Read`, Codex/DSH emit lower-case
    /// names), while `skippedToolNames` / `specialToolNames` stay exact
    /// because the segmenter compares them against the raw wire name.
    let toolKinds: [String: CodeToolKind]

    /// Calls that produce no segment at all (official rule: they neither
    /// render nor split the open span).
    let skippedToolNames: Set<String>

    /// Calls that flush the open span and render as their own card.
    let specialToolNames: [String: CodeToolSegmentPolicy.Special]

    private let normalizedToolKinds: [String: CodeToolKind]

    init(runtime: CodeRuntime,
         toolKinds: [String: CodeToolKind] = [:],
         skippedToolNames: Set<String> = [],
         specialToolNames: [String: CodeToolSegmentPolicy.Special] = [:]) {
        self.runtime = runtime
        self.toolKinds = toolKinds
        self.skippedToolNames = skippedToolNames
        self.specialToolNames = specialToolNames
        var normalized: [String: CodeToolKind] = [:]
        for (name, kind) in toolKinds { normalized[name.lowercased()] = kind }
        normalizedToolKinds = normalized
    }

    /// The table in the segmenter's vocabulary.
    var segmentPolicy: CodeToolSegmentPolicy {
        CodeToolSegmentPolicy(skippedToolNames: skippedToolNames,
                              specialToolNames: specialToolNames)
    }

    /// Table override first, shared classifier second, `.other` last.
    /// `wireKind` is the connector's normalised `content.kind`, which the
    /// classifier understands but a name table does not need in its keys.
    func kind(for name: String, wireKind: String? = nil) -> CodeToolKind {
        if let kind = normalizedToolKinds[name.lowercased()] { return kind }
        return CodeToolKind.classify(name: name, wireKind: wireKind)
    }

    func segments(for calls: [CodeToolCall]) -> [CodeToolSegment] {
        CodeToolSegmenter.segments(calls, policy: segmentPolicy)
    }
}

extension CodeRuntimeToolTable {
    static let all: [CodeRuntimeToolTable] = [.claudeCode, .codex, .dsh]

    static func table(for runtime: CodeRuntime) -> CodeRuntimeToolTable {
        switch runtime {
        case .claudeCode: return .claudeCode
        case .codex: return .codex
        case .dsh: return .dsh
        }
    }

    /// `nil` means the runtime is not one of the three tables; callers fall
    /// back to `CodeToolSegmentPolicy.generic` and the shared classifier.
    static func forRuntime(_ runtime: String?) -> CodeRuntimeToolTable? {
        guard let runtime = CodeRuntime(wireValue: runtime) else { return nil }
        return table(for: runtime)
    }

    // MARK: - Claude Code

    // The connector forwards the SDK's `tool_name` unchanged for every call
    // (connector/connector/runtimes/claude/timeline/messages.py:2564-2568), so
    // these are the exact wire names. Kinds follow the official client's
    // 12-category table and title table (CANONICAL/04-tool-calls.md §7.2/§8);
    // W1 collapses the official grep/glob/web categories into `.search`.
    static let claudeCode = CodeRuntimeToolTable(
        runtime: .claudeCode,
        toolKinds: [
            // connector/connector/runtimes/claude/timeline/messages.py:2568
            "Read": .read,
            // connector/connector/runtimes/claude/timeline/messages.py:2598
            "Edit": .edit,
            "MultiEdit": .edit,
            "NotebookEdit": .edit,
            "Write": .write,
            // connector/connector/runtimes/claude/timeline/messages.py:2582
            "Bash": .bash,
            // [I] CANONICAL/04-tool-calls.md §7.2: tag 4 (BashOutput) maps to
            // category 11 (other) in the official 38→12 table.
            "BashOutput": .other,
            // [I] CANONICAL/04-tool-calls.md §7.2 glob/grep/web; connector passes
            // them through unchanged (messages.py:2568), W1 maps them to search.
            "Glob": .search,
            "Grep": .search,
            // connector/connector/runtimes/claude/timeline/messages.py:2606
            "WebFetch": .search,
            "WebSearch": .search,
            // [I] CANONICAL/04-tool-calls.md §7.2 todo; pass-through 2568.
            "TodoWrite": .todo,
            // [I] CANONICAL/04-tool-calls.md §7.2/§8 (Task/Agent -> ran_agent);
            // exact "Task" is not hidden by is_task_event_tool_name
            // (connector/connector/runtimes/claude/timeline/messages.py:2838-2845).
            "Task": .task,
            // connector/connector/runtimes/claude/timeline/messages.py:2626
            "Agent": .task,
            // connector/connector/runtimes/claude/timeline/agent_calls.py:225-234
            // (sub-agent message target). [I] §7.2: SendUserMessage tag 22 maps
            // to category 11 (other); `SendMessage` itself has no tag entry.
            "SendMessage": .other,
            // [I] CANONICAL/04-tool-calls.md §7.2 exitPlanMode (tag 7); skipped
            // below, kept so a reused/aged segment still renders the plan icon.
            "ExitPlanMode": .plan,
            // [I] CANONICAL/04-tool-calls.md §7.2: EnterPlanMode tag 35 maps to
            // category 11 (other); only the title table gives it a verb (§8).
            "EnterPlanMode": .other,
            // connector/connector/runtimes/claude/timeline/messages.py:2617
            "AskUserQuestion": .question,
            // [I] CANONICAL/04-tool-calls.md §7.2: the 38-tag table has no LS
            // entry, so its category is 11 (other).
            "LS": .other,
            // [I] CANONICAL/04-tool-calls.md §8 (Bash / Git -> ran).
            "Git": .bash,
        ],
        // [E] CANONICAL/04-tool-calls.md §3: the mapper drops these two calls
        // before emitting any segment (`ExitPlanMode` tag 7, `AskUserQuestion`
        // tag 2). A skipped call does not flush the open span.
        skippedToolNames: ["ExitPlanMode", "AskUserQuestion"],
        // [I] Official segment types (CANONICAL/04-tool-calls.md §2/§3):
        // workflow / writingDraft / backgroundTask / threadSessionCard /
        // artifactCard. Only name-derived segments are listed.
        // `backgroundTask` and `threadSessionCard` are derived segments, not
        // wire tool names: the official mapper looks them up by toolUseId /
        // Agent dispatch data, so they have no name entry here.
        specialToolNames: [
            "Workflow": .workflow,
            "WritingDraft": .writingDraft,
            "Artifact": .artifactCard,
        ])
}

extension CodeRuntimeToolTable {
    // MARK: - Codex

    // Codex's SDK delivers tool calls as `function_call` / `custom_tool_call`
    // raw items (connector/connector/runtimes/codex/timeline/projection.py:287-366).
    // Only names the connector branches on are listed; any other function name
    // keeps the connector's `kind: mcp` marker and the shared classifier's
    // answer instead of a guessed kind.
    static let codex = CodeRuntimeToolTable(
        runtime: .codex,
        toolKinds: [
            // connector/connector/runtimes/codex/timeline/raw_content.py:165
            "apply_patch": .edit,
            "file_change": .edit,
            // connector/connector/runtimes/codex/timeline/raw_content.py:145
            "web_search": .search,
            "web_search_preview": .search,
        ])
}

extension CodeRuntimeToolTable {
    // MARK: - DSH

    // DSH's plugin projects native `tool/call` names into canonical items
    // (dsh-bridge-next/src/host/dsh-runtime/tools.ts:4-36; RUNTIME_READS.md:54-60).
    // Dynamic MCP registration names (`mcp__<server>__<tool>`) stay out of a
    // name table; the connector marks them `kind: mcp`, which the classifier
    // already turns into `.mcp`.
    static let dsh = CodeRuntimeToolTable(
        runtime: .dsh,
        toolKinds: [
            // dsh-bridge-next/src/host/dsh-runtime/tools.ts:11; RUNTIME_READS.md:54
            "bash": .bash,
            "pwsh": .bash,
            // dsh-bridge-next/src/host/dsh-runtime/tools.ts:14; RUNTIME_READS.md:56
            "web_search": .search,
            // dsh-bridge-next/src/host/dsh-runtime/tools.ts:17; RUNTIME_READS.md:59
            "ask_user_question": .question,
            "exit_plan_mode": .plan,
            // dsh-bridge-next/src/host/dsh-runtime/tools.ts:55/67; RUNTIME_READS.md:55
            "write": .write,
            "edit": .edit,
            "str_replace_editor": .edit,
            // dsh-bridge-next/src/host/dsh-runtime/tools.ts:26-27; RUNTIME_READS.md:57
            "subagent": .task,
            "subagent_fork": .task,
            "send_message": .task,
            "wait_agent": .task,
            "interrupt_agent": .task,
            "list_agents": .task,
            // [I] RUNTIME_READS.md:60 / dsh-bridge-next/tests/unit/runtime-history.test.ts:149.
            // CodeMode root call; no dedicated kind, its children carry the work.
            "run_code": .other,
        ])
}

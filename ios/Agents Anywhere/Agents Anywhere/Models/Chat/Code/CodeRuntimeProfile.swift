import Foundation

// The Code page's runtime entry point.
//
// W1 owns the grouping algorithm (`CodeToolSegments.swift`) and W2 owns each
// runtime's observed name/kind table (`CodeRuntimeAdapters.swift`). This type
// joins them to the session's wire runtime, so consumers never switch on a
// runtime string themselves: one profile answers "which segment policy, which
// name table, which sub-agent shape" for the rest of the page.
//
// Unknown runtime ids resolve to `.generic`. Generic keeps the shared
// classifier and the empty policy: a call is never guessed into a special card
// or a skip just because another runtime uses that name.

nonisolated struct CodeRuntimeProfile: Hashable, Sendable {
    /// The runtimes AA drives. `generic` is the fallback for ids this client
    /// does not know (and for a missing id); it is not a runtime.
    nonisolated enum Family: String, Hashable, Sendable {
        case claudeCode
        case codex
        case dsh
        case generic
    }

    /// How the runtime surfaces a dispatched sub-agent.
    nonisolated enum SubagentShape: String, Hashable, Sendable {
        /// Claude Code: an `Agent` call is minted as an `agent_call` card
        /// (connector/connector/runtimes/claude/timeline/messages.py:2626).
        /// The official page's `threadSessionCard` segment is derived from
        /// that card, not from a tool name.
        case claudeAgentCard
        /// Codex: collab tool calls (`spawnAgent` / `sendInput` / ...) and
        /// sub-agent activity become `agent_call` cards
        /// (connector/connector/runtimes/codex/timeline/projection.py:243-247,
        /// agent_calls.py:12-32).
        case codexCollabAgent
        /// DSH: the native `subagent*` / `*_agent` tools become `agent_call`
        /// cards (dsh-bridge-next/src/host/dsh-runtime/tools.ts:24-33), and a
        /// child tool row names its card through `content.parentItemId`
        /// (dsh-bridge-next/src/host/dsh-runtime/history.ts:236).
        case dshAgentTools
        /// The runtime is unknown; make no claim about its sub-agent surface.
        case unspecified
    }

    /// The wire `role` the runtime puts on the rows it types as `tool`.
    nonisolated enum ToolRowRole: String, Hashable, Sendable {
        /// Claude Code and Codex tag tool rows `role = "tool"`
        /// (connector/connector/runtimes/claude/timeline/messages.py:666;
        /// connector/connector/runtimes/codex/timeline/raw_item.py:97-127).
        case tool
        /// DSH's plugin tags tool rows `role = "assistant"`
        /// (dsh-bridge-next/src/host/dsh-runtime/history.ts:92), so role must
        /// not be used as the tool/message discriminator on the Code page.
        case assistant
        /// The runtime is unknown; make no claim.
        case unspecified
    }

    let family: Family
    let segmentPolicy: CodeToolSegmentPolicy
    /// The runtime's observed name/kind table; nil for `.generic`, which uses
    /// only the shared classifier.
    let toolTable: CodeRuntimeToolTable?
    let subagentShape: SubagentShape
    let toolRowRole: ToolRowRole

    /// Resolve a session's runtime id (`V2SessionMeta.runtime`, or the
    /// declared `runtimeType`) to its profile.
    ///
    /// `CodeRuntime(wireValue:)` owns the id aliases, so this type never keeps
    /// a second copy of them. Anything it does not resolve — including nil and
    /// an empty string — is `.generic`.
    init(runtime: V2RuntimeID?) {
        guard let runtime, let known = CodeRuntime(wireValue: runtime) else {
            self = .generic
            return
        }
        switch known {
        case .claudeCode: self = .claudeCode
        case .codex: self = .codex
        case .dsh: self = .dsh
        }
    }

    /// The session's effective type: the connector-declared `runtimeType`
    /// when present, else `runtime` (same rule the chat surface already uses
    /// in `Models/Chat/SessionChatModel.swift:100`; the server defaults
    /// `runtimeType` to `runtime`, so this is an alias pick, not a guess).
    init(meta: V2SessionMeta) {
        self.init(runtime: meta.runtimeType ?? meta.runtime)
    }

    var skippedToolNames: Set<String> { segmentPolicy.skippedToolNames }
    var specialToolNames: [String: CodeToolSegmentPolicy.Special] {
        segmentPolicy.specialToolNames
    }

    /// Table first, shared classifier second, `.other` last. The generic
    /// profile has no table and goes straight to the classifier.
    func kind(for name: String, wireKind: String? = nil) -> CodeToolKind {
        toolTable?.kind(for: name, wireKind: wireKind)
            ?? CodeToolKind.classify(name: name, wireKind: wireKind)
    }

    /// One message's tool block → segments, using this runtime's policy.
    func segments(for calls: [CodeToolCall]) -> [CodeToolSegment] {
        CodeToolSegmenter.segments(calls, policy: segmentPolicy)
    }

    // MARK: - Profiles

    static let claudeCode = CodeRuntimeProfile(
        family: .claudeCode,
        // W2's Claude table is the official rule set: `ExitPlanMode` /
        // `AskUserQuestion` are skipped; `Workflow` / `WritingDraft` /
        // `Artifact` are name-mapped dedicated segments; `backgroundTask` and
        // `threadSessionCard` are derived segments (by toolUseId / Agent
        // dispatch data), not wire tool names
        // (CANONICAL/04-tool-calls.md §3; CodeRuntimeAdapters.swift:162-174).
        segmentPolicy: CodeRuntimeToolTable.claudeCode.segmentPolicy,
        toolTable: .claudeCode,
        subagentShape: .claudeAgentCard,
        toolRowRole: .tool)

    /// Codex shares W2's observed table, plus one product rule.
    ///
    /// [I] Product decision, NOT official evidence: Codex's
    /// `request_user_input` is the analogue of Claude's `AskUserQuestion`
    /// (both are questionnaires answered through a `SessionNotice`:
    /// connector/connector/runtimes/codex/domain/input_requests.py:130-170;
    /// notifications/notices.py:78-110), so the Code page gives it the same
    /// treatment — no transcript segment.
    ///
    /// The connector currently publishes the request only as a notice and
    /// never mints a tool row for it, so this entry guards against a future
    /// row that would duplicate the notice; it is not a rule observed in
    /// Codex output. Codex has no observed dedicated segment, so the special
    /// table stays W2's empty one.
    private static let codexPolicy = CodeToolSegmentPolicy(
        skippedToolNames: CodeRuntimeToolTable.codex.skippedToolNames
            .union(["request_user_input"]),
        specialToolNames: CodeRuntimeToolTable.codex.specialToolNames)

    static let codex = CodeRuntimeProfile(
        family: .codex,
        segmentPolicy: codexPolicy,
        toolTable: .codex,
        subagentShape: .codexCollabAgent,
        toolRowRole: .tool)

    /// DSH keeps W2's table unchanged: its own `ask_user_question` /
    /// `exit_plan_mode` tools are `input_request` rows
    /// (dsh-bridge-next/src/host/dsh-runtime/tools.ts:17-19) and no DSH skip or
    /// special segment has been observed, so every call is a plain call.
    static let dsh = CodeRuntimeProfile(
        family: .dsh,
        segmentPolicy: CodeRuntimeToolTable.dsh.segmentPolicy,
        toolTable: .dsh,
        subagentShape: .dshAgentTools,
        toolRowRole: .assistant)

    /// The fallback for an unknown runtime: no skip, no special, no table.
    static let generic = CodeRuntimeProfile(
        family: .generic,
        segmentPolicy: .generic,
        toolTable: nil,
        subagentShape: .unspecified,
        toolRowRole: .unspecified)

    private init(family: Family,
                 segmentPolicy: CodeToolSegmentPolicy,
                 toolTable: CodeRuntimeToolTable?,
                 subagentShape: SubagentShape,
                 toolRowRole: ToolRowRole) {
        self.family = family
        self.segmentPolicy = segmentPolicy
        self.toolTable = toolTable
        self.subagentShape = subagentShape
        self.toolRowRole = toolRowRole
    }
}

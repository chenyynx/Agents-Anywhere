import Foundation

// The Code page's tool-call model, runtime-neutral.
//
// The official page (CANONICAL/04-tool-calls.md §2/§3) renders a message's
// tool calls as segments: consecutive plain calls gather into one `span`, a
// special call flushes the span and renders as its own card, and two Claude
// tools produce no segment at all. The grouping is a client rule over one
// message's tool block — it never crosses a block, has no count threshold, and
// the server summary only changes the label. It lives here as a pure function
// so the rules can be tested without UIKit and shared by every runtime.

nonisolated enum CodeToolStatus: Hashable {
    /// The official model has three states. AA's wire also has pending /
    /// waiting-approval / cancelled / interrupted / hidden / unknown; a call
    /// that has not finished is running, and one that ended without completing
    /// is failed. `hidden` and `unknown` read as running rather than being
    /// guessed as success or failure: a hidden row is filtered upstream, and
    /// an unknown status proves neither outcome.
    case running
    case complete
    case failed

    init(_ status: V2TimelineItemStatus) {
        switch status {
        case .done: self = .complete
        case .failed, .cancelled, .interrupted: self = .failed
        case .pending, .running, .waitingApproval, .hidden, .unknown: self = .running
        }
    }
}

nonisolated enum CodeToolKind: Hashable {
    case read, edit, write, bash, search, todo, task, plan, question, mcp, other

    /// Name first, wire kind second: runtimes share tool shapes but not always
    /// names, and some connectors stamp a coarse kind on every call (Codex
    /// marks every non-`web_search` function call `kind: "mcp"`), so a known
    /// name must win. Anything neither table recognises is `other`, never
    /// guessed.
    static func classify(name: String, wireKind: String?) -> CodeToolKind {
        kind(forName: name) ?? kind(forWireKind: wireKind) ?? .other
    }

    private static func kind(forName name: String) -> CodeToolKind? {
        switch name.lowercased() {
        case "read", "notebookread", "view": return .read
        case "write", "create": return .write
        case "edit", "multiedit", "notebookedit", "apply_patch", "patch": return .edit
        case "bash", "shell", "run_command", "command": return .bash
        case "grep", "glob", "websearch", "web_search", "webfetch", "web-fetch", "search": return .search
        case "todowrite", "todo_write", "update_plan": return .todo
        case "task", "agent", "dispatch": return .task
        case "exitplanmode", "exit_plan_mode", "plan": return .plan
        case "askuserquestion", "ask_user_question": return .question
        default: return nil
        }
    }

    private static func kind(forWireKind wireKind: String?) -> CodeToolKind? {
        switch wireKind {
        case "command": return .bash
        case "web_search": return .search
        case "mcp": return .mcp
        case "agent_call": return .task
        default: return nil
        }
    }
}

/// One tool call in the form the Code page renders.
///
/// `item` is kept as the wire truth: the detail page reads input, output and
/// diffs from it instead of re-modelling five payload shapes here.
nonisolated struct CodeToolCall: Hashable, Identifiable {
    let id: String
    /// The runtime's raw tool name; the segment policy keys on it.
    let name: String
    let kind: CodeToolKind
    let status: CodeToolStatus
    let item: V2TimelineItem

    /// The call's index inside its message's content, when the connector
    /// declares it. The server orders a message's tool rows by this value and
    /// refuses to reorder a group that lacks it.
    var blockIndex: Int? { item.source["blockIndex"]?.intValue }

    /// Runtime-resolved construction: the profile's observed name table (W2)
    /// has already decided the kind, so it wins over the shared classifier.
    /// W7 must use this initializer — the classifier-only one below cannot
    /// see a runtime-specific mapping.
    init(item: V2TimelineItem, kind: CodeToolKind) {
        self.init(item: item, name: Self.wireName(for: item), kind: kind)
    }

    /// Classifier-only fallback for callers that have no runtime profile
    /// (W2's adapter tests read single calls). Not for timeline construction:
    /// W7 must use `init(item:kind:)` with `CodeRuntimeProfile.kind(for:)`.
    init(item: V2TimelineItem) {
        let name = Self.wireName(for: item)
        self.init(item: item, name: name,
                  kind: CodeToolKind.classify(name: name, wireKind: Self.wireKind(for: item)))
    }

    private init(item: V2TimelineItem, name: String, kind: CodeToolKind) {
        self.item = item
        id = item.id
        self.name = name
        self.kind = kind
        status = CodeToolStatus(item.status)
    }

    /// The runtime's raw tool name, else its wire kind, else `"tool"`.
    static func wireName(for item: V2TimelineItem) -> String {
        TimelineText.first(
            item.raw["content"]?["toolName"],
            item.raw["content"]?["name"],
            item.raw["content"]?["tool"],
            item.raw["content"]?["title"])
            ?? item.raw["content"]?["kind"]?.stringValue
            ?? "tool"
    }

    /// The connector's normalised `content.kind`, when it declares one.
    static func wireKind(for item: V2TimelineItem) -> String? {
        item.raw["content"]?["kind"]?.stringValue
    }
}

/// Which calls flush a span or disappear, per runtime.
///
/// The official rules are Claude's (CANONICAL/04-tool-calls.md §3): the two
/// skipped names are `ExitPlanMode` and `AskUserQuestion`; the special segment
/// kinds are workflow / writingDraft / backgroundTask / threadSessionCard /
/// artifactCard, of which only the name-derived ones can appear in a table.
/// Other runtimes keep the same algorithm and supply their own tables; an
/// empty table means every call is plain — a special is never guessed from a
/// name we have not observed. `backgroundTask` and `threadSessionCard` are
/// derived from tool-use / Agent-dispatch data in the official client, not
/// from a wire tool name, so no name table can produce them.
///
/// Runtime selection lives in `CodeRuntimeProfile` (W2b); this file only holds
/// the policy type and the shared algorithm.
nonisolated struct CodeToolSegmentPolicy: Hashable, Sendable {
    nonisolated enum Special: Hashable, Sendable {
        case workflow
        case writingDraft
        case backgroundTask
        case threadSessionCard
        case artifactCard
    }

    let skippedToolNames: Set<String>
    let specialToolNames: [String: Special]

    static let claudeCode = CodeToolSegmentPolicy(
        skippedToolNames: ["ExitPlanMode", "AskUserQuestion"],
        // Only name-derived segments live here. `backgroundTask` and
        // `threadSessionCard` are derived from tool-use/dispatch data, not
        // wire tool names (and the connector has no such names), so neither
        // has an entry.
        specialToolNames: [
            "Workflow": .workflow,
            "WritingDraft": .writingDraft,
            "Artifact": .artifactCard,
        ])

    /// Neither Codex nor DSH has an observed skip or dedicated segment yet, so
    /// their policy tables stay empty: every call is a plain call and groups
    /// exactly as the algorithm says. Filling them is data, not code.
    static let codex = CodeToolSegmentPolicy(skippedToolNames: [], specialToolNames: [:])
    static let dsh = CodeToolSegmentPolicy(skippedToolNames: [], specialToolNames: [:])
    static let generic = CodeToolSegmentPolicy(skippedToolNames: [], specialToolNames: [:])
}

nonisolated enum CodeToolSegment: Hashable {
    case span([CodeToolCall])
    case special(CodeToolSegmentPolicy.Special, CodeToolCall)
}

nonisolated enum CodeToolSegmenter {
    /// One message's tool block → its segments.
    ///
    /// The argument is the calls of a single `Block.toolCalls`; a caller with
    /// several blocks segments each block separately (the official rule never
    /// merges across blocks, so concatenating two blocks would invent a span
    /// the page does not render).
    ///
    /// Skip first (a skipped call neither renders nor flushes), then a special
    /// flushes the open span and renders alone, otherwise the call joins the
    /// span. The trailing span flushes at the end. A single call is a span of
    /// one — the official page has no separate single-call component.
    static func segments(_ calls: [CodeToolCall],
                         policy: CodeToolSegmentPolicy) -> [CodeToolSegment] {
        var result: [CodeToolSegment] = []
        var span: [CodeToolCall] = []
        func flush() {
            guard !span.isEmpty else { return }
            result.append(.span(span))
            span.removeAll()
        }
        for call in calls {
            if policy.skippedToolNames.contains(call.name) { continue }
            if let special = policy.specialToolNames[call.name] {
                flush()
                result.append(.special(special, call))
            } else {
                span.append(call)
            }
        }
        flush()
        return result
    }
}

import Foundation

// The collapsed tool row's label, runtime-neutral.
//
// The official label comes from `ToolCall.toolInput` plus the verified verb
// table (CANONICAL/04-tool-calls.md §8) for a single call, and from the
// server's span summary for several calls. AA's wire carries no
// `serverSummary`, so a span composes its summary from the calls it has. The
// composition rules here are the official plural forms
// (`EVIDENCE/resources-r6.md` §3.3 `ccr_summary_*`):
//
// - file operations count distinct files, not calls: six edits to one file
//   read as "Edited that file", never "Edited 6 files";
// - Bash counts commands, Task counts agents, MCP/other counts tools;
// - a span whose calls all target one file keeps the single-call shape
//   ("Edited MEMORY.md"), which is what the server summary would say.
//
// This type stays free of SwiftUI and of localized strings: it returns
// semantic verbs and counts, the view maps them to `String(localized:)`.

/// A line-diff summary for a collapsed tool row.
///
/// Both counts are line counts: zero means "no lines", never a negative value.
nonisolated struct CodeDiffStat: Hashable, Sendable {
    let added: Int
    let removed: Int

    /// A badge exists only when there is something to count; an all-zero stat
    /// would draw an empty pill.
    var hasCounts: Bool { added > 0 || removed > 0 }
}

nonisolated struct CodeToolLabelPlan: Hashable, Sendable {
    /// The verb shown before the target (single call), or the first verb of a
    /// summary phrase. `used` is the official `Used %@` form.
    nonisolated enum Verb: Hashable, Sendable {
        case read, edited, created, ran, searched, searchedWeb, fetched
        case clearedTodos, updatedTodos, ranAgent, proposedPlan, asked, used
        /// Span-summary-only forms (no single-call use).
        case searchedCode, foundFiles, browsedWeb
    }

    /// What a phrase's count counts. `.none` is a fixed phrase
    /// ("Searched code", "Updated todos") whose count is always 1.
    nonisolated enum Unit: Hashable, Sendable {
        case none, files, notebooks, commands, agents, tools, times
    }

    nonisolated struct Phrase: Hashable, Sendable {
        let verb: Verb
        let unit: Unit
        let count: Int
    }

    /// The single-call / shared-target verb. Nil for a multi-kind summary.
    let verb: Verb?
    /// The single call's target (or the one file a span operated on).
    let target: String?
    /// The span summary when `verb` is nil, in first-seen order.
    let phrases: [Phrase]
    let diff: CodeDiffStat?
    let isRunning: Bool

    private init(verb: Verb?, target: String?, phrases: [Phrase],
                 diff: CodeDiffStat?, isRunning: Bool) {
        self.verb = verb
        self.target = target
        self.phrases = phrases
        self.diff = diff
        self.isRunning = isRunning
    }

    /// One segment's calls → its label plan. Nil for an empty span (the
    /// segmenter never produces one, but a caller may hand an empty array).
    static func make(calls: [CodeToolCall], cwd: String?) -> CodeToolLabelPlan? {
        guard let first = calls.first else { return nil }
        let running = calls.contains { $0.status == .running }
        let diff = diffStat(for: calls)

        if calls.count == 1 {
            return CodeToolLabelPlan(verb: singleVerb(for: first),
                                     target: rawTarget(for: first, cwd: cwd),
                                     phrases: [], diff: diff, isRunning: running)
        }

        // A span of identical file operations on one file is that operation
        // on that file. The official server summary would name the file; the
        // client can derive the same shape from its inputs, and it avoids the
        // false "Edited 6 files" when six edits hit one file.
        if let shared = sharedSingleFileTarget(calls: calls, cwd: cwd) {
            return CodeToolLabelPlan(verb: shared.verb, target: shared.target,
                                     phrases: [], diff: diff, isRunning: running)
        }

        return CodeToolLabelPlan(verb: nil, target: nil,
                                 phrases: phrases(for: calls),
                                 diff: diff, isRunning: running)
    }

    // MARK: - Single call

    private static func singleVerb(for call: CodeToolCall) -> Verb {
        switch call.kind {
        case .read: return .read
        case .edit: return .edited
        case .write: return .created
        case .bash: return .ran
        case .search: return searchVerb(for: call)
        case .todo: return todoIsEmpty(call) ? .clearedTodos : .updatedTodos
        case .task: return .ranAgent
        case .plan: return .proposedPlan
        case .question: return .asked
        case .mcp, .other: return .used
        }
    }

    private static func searchVerb(for call: CodeToolCall) -> Verb {
        switch call.name.lowercased() {
        case "websearch", "web_search": return .searchedWeb
        case "webfetch", "web-fetch", "fetch": return .fetched
        default: return .searched
        }
    }

    /// The call's visible target: a shortened file path, the shell command, a
    /// search query, or the agent/tool name.
    static func rawTarget(for call: CodeToolCall, cwd: String?) -> String? {
        let content = call.item.raw["content"] ?? .object([:])
        let input = content["input"] ?? content["arguments"]
        switch call.kind {
        case .read, .edit, .write:
            let path = filePath(in: content, input: input)
            return path.map { TimelineText.displayPath($0, cwd: cwd) }
        case .bash:
            return TimelineText.command(content["command"])
                ?? TimelineText.command(input?["command"])
                ?? TimelineText.command(input?["cmd"])
        case .search:
            return TimelineText.first(input?["query"], input?["pattern"],
                                      content["query"], input?["url"], content["url"])
        case .task:
            return TimelineText.first(input?["description"], input?["prompt"],
                                      content["description"], content["title"])
        case .plan, .question:
            return TimelineText.first(content["question"], input?["question"])
        case .todo:
            return nil
        case .mcp:
            return TimelineText.first(content["tool"], input?["tool"],
                                      content["server"], input?["server"]) ?? call.name
        case .other:
            return call.name
        }
    }

    /// The unshortened file path, used for counting distinct files. The
    /// display path is relative to the session cwd, so two calls in the same
    /// session would compare correctly either way; the raw path keeps the
    /// count independent of the presentation.
    private static func filePath(in content: JSONValue, input: JSONValue?) -> String? {
        TimelineText.first(input?["file_path"], input?["notebook_path"],
                           input?["path"], content["path"], content["file_path"])
            ?? content["changes"]?.arrayValue?.first.flatMap { TimelineText.path($0) }
    }

    private static func todoIsEmpty(_ call: CodeToolCall) -> Bool {
        let content = call.item.raw["content"] ?? .object([:])
        let todos = content["input"]?["todos"]?.arrayValue
            ?? content["arguments"]?["todos"]?.arrayValue
            ?? content["todos"]?.arrayValue
        return todos?.isEmpty == true
    }

    // MARK: - Span summary

    private struct FileTarget {
        let verb: Verb
        let target: String
    }

    /// All calls are the same file operation and resolve to one target.
    private static func sharedSingleFileTarget(calls: [CodeToolCall],
                                               cwd: String?) -> FileTarget? {
        guard let first = calls.first, let verb = fileVerb(for: first) else { return nil }
        var target: String?
        for call in calls {
            guard fileVerb(for: call) == verb else { return nil }
            guard let path = filePath(for: call) else { return nil }
            if let target, target != path { return nil }
            target = path
        }
        return target.map { FileTarget(verb: verb,
                                       target: TimelineText.displayPath($0, cwd: cwd)) }
    }

    private static func fileVerb(for call: CodeToolCall) -> Verb? {
        switch call.kind {
        case .read: return .read
        case .edit: return .edited
        case .write: return .created
        default: return nil
        }
    }

    private static func filePath(for call: CodeToolCall) -> String? {
        let content = call.item.raw["content"] ?? .object([:])
        return filePath(in: content, input: content["input"] ?? content["arguments"])
    }

    private static func isNotebookCall(_ call: CodeToolCall) -> Bool {
        switch call.name.lowercased() {
        case "notebookedit", "notebook_edit": return true
        default: return false
        }
    }

    /// One file operation per (verb, notebook-ness): the official summary
    /// counts distinct files, so a set of targets is kept per group and a
    /// call without a target still contributes one (an unknown file is not
    /// silently dropped).
    private struct FileGroupKey: Hashable {
        let verb: Verb
        let notebook: Bool
    }

    private static func phrases(for calls: [CodeToolCall]) -> [Phrase] {
        var order: [PhraseKey] = []
        var fileTargets: [FileGroupKey: Set<String>] = [:]
        var fileUntargeted: [FileGroupKey: Int] = [:]
        var counters: [PhraseKey: Int] = [:]

        for call in calls {
            if let verb = fileVerb(for: call) {
                let key = FileGroupKey(verb: verb, notebook: isNotebookCall(call))
                if !order.contains(.file(key)) { order.append(.file(key)) }
                if let path = filePath(for: call) {
                    fileTargets[key, default: []].insert(path)
                } else {
                    fileUntargeted[key, default: 0] += 1
                }
                continue
            }
            let key = PhraseKey.forCall(call)
            if !order.contains(key) { order.append(key) }
            counters[key, default: 0] += 1
        }

        return order.compactMap { key -> Phrase? in
            switch key {
            case .file(let group):
                let count = (fileTargets[group]?.count ?? 0)
                    + (fileUntargeted[group] ?? 0)
                guard count > 0 else { return nil }
                return Phrase(verb: group.verb,
                              unit: group.notebook ? .notebooks : .files,
                              count: count)
            case .other(let phraseKey):
                let count = counters[.other(phraseKey)] ?? 1
                return phraseKey.phrase(count: count)
            }
        }
    }

    /// A non-file phrase's identity. Fixed official summary forms keep their
    /// own key; generic search/tool counts keep `times` / `tools`.
    private enum PhraseKey: Hashable {
        case file(FileGroupKey)
        case other(OtherKey)

        static func forCall(_ call: CodeToolCall) -> PhraseKey {
            switch call.kind {
            case .bash: return .other(.bash)
            case .task: return .other(.task)
            case .search:
                switch call.name.lowercased() {
                case "grep": return .other(.searchedCode)
                case "glob": return .other(.foundFiles)
                case "websearch", "web_search": return .other(.browsedWeb)
                case "webfetch", "web-fetch", "fetch": return .other(.fetched)
                default: return .other(.searched)
                }
            case .todo:
                return .other(todoIsEmpty(call) ? .clearedTodos : .updatedTodos)
            case .plan: return .other(.proposedPlan)
            case .question: return .other(.asked)
            case .mcp, .other: return .other(.tools)
            case .read, .edit, .write:
                // Handled by the file branch; a file kind without a target
                // still reaches that branch. This return is unreachable.
                return .other(.tools)
            }
        }
    }

    private enum OtherKey: Hashable {
        case bash, task, searched, searchedCode, foundFiles, browsedWeb, fetched
        case clearedTodos, updatedTodos, proposedPlan, asked, tools

        func phrase(count: Int) -> Phrase {
            switch self {
            case .bash: return Phrase(verb: .ran, unit: .commands, count: count)
            case .task: return Phrase(verb: .ranAgent, unit: .agents, count: count)
            case .searched: return Phrase(verb: .searched, unit: .times, count: count)
            case .searchedCode: return Phrase(verb: .searchedCode, unit: .none, count: 1)
            case .foundFiles: return Phrase(verb: .foundFiles, unit: .none, count: 1)
            case .browsedWeb: return Phrase(verb: .browsedWeb, unit: .none, count: 1)
            case .fetched: return Phrase(verb: .fetched, unit: .none, count: 1)
            case .clearedTodos: return Phrase(verb: .clearedTodos, unit: .none, count: 1)
            case .updatedTodos: return Phrase(verb: .updatedTodos, unit: .none, count: 1)
            case .proposedPlan: return Phrase(verb: .proposedPlan, unit: .none, count: 1)
            case .asked: return Phrase(verb: .asked, unit: .none, count: 1)
            case .tools: return Phrase(verb: .used, unit: .tools, count: count)
            }
        }
    }

    // MARK: - Diff stat

    /// The collapsed row's badge, read from the wire's line counts.
    ///
    /// Claude's own `tool_use_result.structuredPatch` carries no aggregate
    /// count, so when the wire omits `lineStat` the exact hunk lines are
    /// counted instead (the same lines the official server counts into
    /// `lineCounts`). Parsing the full diff model here would be heavy for a
    /// one-line badge, so this only scans prefixes.
    static func diffStat(for calls: [CodeToolCall]) -> CodeDiffStat? {
        var added = 0
        var removed = 0
        var found = false
        for call in calls {
            guard let stat = diffStat(for: call.item) else { continue }
            added += stat.added
            removed += stat.removed
            found = true
        }
        guard found, added > 0 || removed > 0 else { return nil }
        return CodeDiffStat(added: max(0, added), removed: max(0, removed))
    }

    private static func diffStat(for item: V2TimelineItem) -> CodeDiffStat? {
        // A failed change did not land; its attempted patch is not a diff.
        guard CodeToolStatus(item.status) != .failed else { return nil }
        let content = item.raw["content"] ?? .object([:])
        let output = content["output"]?.objectValue
        let stat = output?["lineStat"]?.objectValue
        let added = stat?["addedLineCount"]?.intValue
            ?? stat?["added"]?.intValue
            ?? output?["addedLineCount"]?.intValue
            ?? content["lineStat"]?["addedLineCount"]?.intValue
        let removed = stat?["removedLineCount"]?.intValue
            ?? stat?["removed"]?.intValue
            ?? output?["removedLineCount"]?.intValue
            ?? content["lineStat"]?["removedLineCount"]?.intValue
        if added != nil || removed != nil {
            let addedCount = max(0, added ?? 0)
            let removedCount = max(0, removed ?? 0)
            guard addedCount > 0 || removedCount > 0 else { return nil }
            return CodeDiffStat(added: addedCount, removed: removedCount)
        }
        return countedDiffStat(in: content)
    }

    /// Exact counts from the change lines the wire already carries.
    ///
    /// `structuredPatch[].lines` are `' '` / `'+'` / `'-'` prefixed body
    /// lines; `changes[].diff` is a unified-diff string whose `--- ` / `+++ `
    /// file headers are not body lines. Both are counted by prefix only.
    private static func countedDiffStat(in content: JSONValue) -> CodeDiffStat? {
        var added = 0
        var removed = 0
        var found = false
        for hunk in content["structuredPatch"]?.arrayValue ?? [] {
            for line in hunk["lines"]?.arrayValue ?? [] {
                guard let text = line.stringValue else { continue }
                if text.hasPrefix("+") { added += 1; found = true }
                else if text.hasPrefix("-") { removed += 1; found = true }
            }
        }
        if !found {
            for change in content["changes"]?.arrayValue ?? [] {
                guard let diff = (change["diff"] ?? change["patch"])?.stringValue else { continue }
                for line in diff.components(separatedBy: "\n") {
                    if line.hasPrefix("+"), !line.hasPrefix("+++ ") { added += 1; found = true }
                    else if line.hasPrefix("-"), !line.hasPrefix("--- ") { removed += 1; found = true }
                }
            }
        }
        guard found, added > 0 || removed > 0 else { return nil }
        return CodeDiffStat(added: added, removed: removed)
    }
}

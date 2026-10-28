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
// - summary groups follow the official 13 `ToolCallCategory` values
//   (round27 §4.1): WebSearch and WebFetch share `web`, cleared and updated
//   todos share `todo`, and AskUserQuestion falls into `other`; SendMessage
//   is the `sessionMessage` category;
// - a span whose calls all resolve to one target keeps the single-call shape
//   ("Edited MEMORY.md"); the 1023 predicate behind that choice is still
//   undecoded (round27 A3, TODO(round28));
// - four or more category groups keep at most three: categories with a
//   failure first, then the clean ones, printed in first-seen order
//   (`0x10313fdf4`);
// - a category whose distinct entries all failed is marked `whole`: the row
//   paints it red instead of writing the failed suffix (the official code
//   does so when `differentiateWithoutColor` is off).
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

/// The official `ToolCall.fileWriteKind` (`swift_types.csv` 49470–49471):
/// a `fileWrite` either created a file or replaced one. The official model
/// carries it as a field; AA's wire has no such field, so it is derived from
/// the tool's own result text.
nonisolated enum CodeFileWriteKind: Hashable, Sendable {
    case create
    case update
}

nonisolated struct CodeToolLabelPlan: Hashable, Sendable {
    /// The verb shown before the target (single call), or the first verb of a
    /// summary phrase. `used` is the official `Used %@` form.
    nonisolated enum Verb: Hashable, Sendable {
        case read, edited, created, ran, searched, searchedWeb, fetched
        case clearedTodos, updatedTodos, ranAgent, proposedPlan, asked, used
        /// A `fileWrite` that replaced an existing file (`fileWriteKind ==
        /// update`): `ccr_write_updated` / `ccr_running_editing`.
        case updated
        /// Span-summary-only forms (no single-call use).
        case searchedCode, foundFiles, browsedWeb
    }

    /// What a phrase's count counts. `.none` is a fixed phrase
    /// ("Searched code", "Updated todos") whose count is always 1.
    nonisolated enum Unit: Hashable, Sendable {
        case none, files, notebooks, commands, agents, tools, times
        /// Official `sessionMessage`: distinct SendMessage calls.
        case sessions
    }

    nonisolated struct Phrase: Hashable, Sendable {
        let verb: Verb
        let unit: Unit
        let count: Int
        /// The category's failed entries: same distinct-key rule as `count`
        /// (`0x10288e3c0` counts `status == failed` in the same dictionary).
        let failed: Int
        /// The official `whole` mark (round21 §1.11/§3.4): every distinct
        /// entry in this category failed. The row paints the phrase in the
        /// failure colour when `differentiateWithoutColor` is off and appends
        /// the failed suffix otherwise. `count` cannot decide this: a fixed
        /// phrase ("Searched code") always reads 1 while its category may
        /// hold several calls.
        let whole: Bool

        init(verb: Verb, unit: Unit, count: Int, failed: Int = 0,
             whole: Bool = false) {
            self.verb = verb
            self.unit = unit
            self.count = count
            self.failed = failed
            self.whole = whole
        }
    }

    /// The single-call / shared-target verb. Nil for a multi-kind summary.
    let verb: Verb?
    /// The single call's target (or the one file a span operated on).
    let target: String?
    /// The span summary when `verb` is nil, in first-seen order.
    let phrases: [Phrase]
    let diff: CodeDiffStat?
    let isRunning: Bool
    /// The single-target path's failed calls. The official single-call suffix
    /// is fixed N=1 (`0x1028904a0`); a shared-target span keeps the real count.
    let failed: Int
    /// Calls in the single-target path; the phrase path carries its own
    /// per-category totals instead.
    let total: Int

    private init(verb: Verb?, target: String?, phrases: [Phrase],
                 diff: CodeDiffStat?, isRunning: Bool,
                 failed: Int = 0, total: Int = 0) {
        self.verb = verb
        self.target = target
        self.phrases = phrases
        self.diff = diff
        self.isRunning = isRunning
        self.failed = failed
        self.total = total
    }

    /// One segment's calls → its label plan. Nil for an empty span (the
    /// segmenter never produces one, but a caller may hand an empty array).
    static func make(calls: [CodeToolCall], cwd: String?) -> CodeToolLabelPlan? {
        guard let first = calls.first else { return nil }
        let running = calls.contains { $0.status == .running }
        let diff = diffStat(for: calls)
        let failed = calls.filter { $0.status == .failed }.count

        if calls.count == 1 {
            return CodeToolLabelPlan(verb: singleVerb(for: first),
                                     target: rawTarget(for: first, cwd: cwd),
                                     phrases: [], diff: diff, isRunning: running,
                                     failed: failed, total: calls.count)
        }

        // AA keeps its current single-target rule: every call's extracted
        // target is the same string, whatever the tools are. This also avoids
        // the false "Edited 6 files" when six edits hit one file. The 1023
        // predicate is undecoded, so the 1005 "count == 1 or all same target"
        // rule must not replace this.
        // TODO(round28: official predicate UNKNOWN)
        if let shared = sharedTarget(calls: calls, cwd: cwd) {
            return CodeToolLabelPlan(verb: shared.verb, target: shared.target,
                                     phrases: [], diff: diff, isRunning: running,
                                     failed: failed, total: calls.count)
        }

        return CodeToolLabelPlan(verb: nil, target: nil,
                                 phrases: phrases(for: calls),
                                 diff: diff, isRunning: running,
                                 failed: failed, total: calls.count)
    }

    // MARK: - Single call

    private static func singleVerb(for call: CodeToolCall) -> Verb {
        switch call.kind {
        case .read: return .read
        case .edit: return .edited
        case .write:
            // Official Write has two verbs (`0x102891924`): create and
            // update. Only an explicit update marker overrides Created.
            return fileWriteKind(for: call) == .update ? .updated : .created
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

    // MARK: - Write kind

    /// The official `fileWriteKind` for a Write call.
    ///
    /// AA's timeline has no such field; the Claude Code Write result text does
    /// name both cases, verified against the production timeline
    /// (2026-10-25: 1110 "File created successfully at:…" / 24 "The file …
    /// has been updated successfully…"). Only these exact markers are
    /// trusted: an unknown or missing result keeps today's Created +
    /// diff-counted behaviour instead of guessing. Only `fileWrite` reads
    /// this: Edit shares the "has been updated successfully" wording, so a
    /// non-write call must never be classified here.
    static func fileWriteKind(for call: CodeToolCall) -> CodeFileWriteKind? {
        // Only fileWrite reads this field. Edit shares the "has been updated
        // successfully" result text but is a different tool (and does count
        // its diff); never classify it here.
        guard call.kind == .write else { return nil }
        let content = call.item.raw["content"] ?? .object([:])
        guard let text = writeResultText(in: content) else { return nil }
        if text.hasPrefix("File created successfully at:") { return .create }
        if text.hasPrefix("The file "), text.contains(" has been updated successfully") {
            return .update
        }
        return nil
    }

    private static func writeResultText(in content: JSONValue) -> String? {
        for key in ["text", "outputText"] {
            if let value = content[key]?.stringValue, !value.isEmpty { return value }
        }
        if let value = content["result"]?.stringValue, !value.isEmpty { return value }
        if let value = content["output"]?.stringValue, !value.isEmpty { return value }
        return nil
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

    /// AA's single-target predicate: every call resolves to the same target
    /// string, whatever the tool. The first call supplies the verb; a call
    /// without a target breaks the predicate and the row falls back to the
    /// category summary.
    ///
    /// TODO(round28: official predicate UNKNOWN) — 1023 has no equivalent of
    /// the 1005 `count == 1 || all same target` function (round27 A3); keep
    /// this behaviour until the mode byte is decoded.
    private static func sharedTarget(calls: [CodeToolCall],
                                     cwd: String?) -> FileTarget? {
        guard let first = calls.first,
              let target = rawTarget(for: first, cwd: cwd),
              !target.isEmpty else { return nil }
        for call in calls.dropFirst() {
            guard let candidate = rawTarget(for: call, cwd: cwd),
                  candidate == target else { return nil }
        }
        return FileTarget(verb: singleVerb(for: first), target: target)
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
        var fileFailedTargets: [FileGroupKey: Set<String>] = [:]
        var fileUntargeted: [FileGroupKey: Int] = [:]
        var fileFailedUntargeted: [FileGroupKey: Int] = [:]
        var callIDs: [PhraseKey: Set<String>] = [:]
        var failedIDs: [PhraseKey: Set<String>] = [:]

        for call in calls {
            let failed = call.status == .failed
            if let verb = fileVerb(for: call) {
                let key = FileGroupKey(verb: verb, notebook: isNotebookCall(call))
                if !order.contains(.file(key)) { order.append(.file(key)) }
                if let path = filePath(for: call) {
                    fileTargets[key, default: []].insert(path)
                    if failed { fileFailedTargets[key, default: []].insert(path) }
                } else {
                    fileUntargeted[key, default: 0] += 1
                    if failed { fileFailedUntargeted[key, default: 0] += 1 }
                }
                continue
            }
            let key = PhraseKey.forCall(call)
            if !order.contains(key) { order.append(key) }
            // Official non-file categories count distinct `ToolCall.id`s
            // (round21 §1.3); a repeated id must not double the count.
            callIDs[key, default: []].insert(call.id)
            if failed { failedIDs[key, default: []].insert(call.id) }
        }

        let built = order.compactMap { key -> Phrase? in
            switch key {
            case .file(let group):
                let count = (fileTargets[group]?.count ?? 0)
                    + (fileUntargeted[group] ?? 0)
                guard count > 0 else { return nil }
                let failed = (fileFailedTargets[group]?.count ?? 0)
                    + (fileFailedUntargeted[group] ?? 0)
                return Phrase(verb: group.verb,
                              unit: group.notebook ? .notebooks : .files,
                              count: count,
                              failed: failed,
                              whole: failed > 0 && failed == count)
            case .other(let phraseKey):
                let count = callIDs[.other(phraseKey)]?.count ?? 1
                return phraseKey.phrase(count: count,
                                        failed: failedIDs[.other(phraseKey)]?.count ?? 0)
            }
        }
        return capped(built)
    }

    /// The official category cap (`0x10313fdf4`): fewer than four category
    /// groups show every phrase; four or more keep at most three — categories
    /// with a failure first, then the clean ones, each in first-seen order —
    /// and the kept phrases still print in their original first-seen order.
    /// Dropped categories are not summarized as "and N more".
    private static func capped(_ phrases: [Phrase]) -> [Phrase] {
        guard phrases.count >= 4 else { return phrases }
        var priority: [Int] = []
        priority.reserveCapacity(phrases.count)
        for (index, phrase) in phrases.enumerated() where phrase.failed > 0 {
            priority.append(index)
        }
        for (index, phrase) in phrases.enumerated() where phrase.failed == 0 {
            priority.append(index)
        }
        let kept = Set(priority.prefix(3))
        return phrases.enumerated()
            .filter { kept.contains($0.offset) }
            .map(\.element)
    }

    /// A non-file phrase's identity. Each case is one official summary
    /// category; file operations are grouped by the file branch above.
    private enum PhraseKey: Hashable {
        case file(FileGroupKey)
        case other(OtherKey)

        static func forCall(_ call: CodeToolCall) -> PhraseKey {
            // Official `sessionMessage` is the SendMessage tool (`ToolInput`
            // tag 0x16=22). AA has no such kind, and the runtime may stamp it
            // `mcp`, so the tool name is the only signal.
            switch call.name.lowercased() {
            case "sendmessage", "send_message", "send-message":
                return .other(.sessionMessage)
            default:
                break
            }
            switch call.kind {
            case .bash: return .other(.bash)
            case .task: return .other(.task)
            case .search:
                // Official `grep` / `glob` / `web` categories; a search tool
                // that names neither has no official category, so it falls
                // into `other`.
                switch call.name.lowercased() {
                case "grep": return .other(.searchedCode)
                case "glob": return .other(.foundFiles)
                case "websearch", "web_search", "webfetch", "web_fetch",
                     "web-fetch", "fetch":
                    return .other(.browsedWeb)
                default: return .other(.tools)
                }
            case .todo:
                // Official `todo` has one fixed phrase whether the list was
                // cleared or updated (`ccr_summary_updated_todos`).
                return .other(.updatedTodos)
            case .plan: return .other(.proposedPlan)
            case .question:
                // AskUserQuestion has no category: answered calls are lifted
                // out of the span, and a transient one renders alone.
                return .other(.tools)
            case .mcp, .other: return .other(.tools)
            case .read, .edit, .write:
                // Handled by the file branch; a file kind without a target
                // still reaches that branch. This return is unreachable.
                return .other(.tools)
            }
        }
    }

    /// The official non-file summary categories (round27 §4.1). Every case
    /// here maps to one of the 13 `ToolCallCategory` values; AA-only groups
    /// (webfetch, cleared todos, AskUserQuestion, unnamed search) are folded
    /// into `web`, `todo` and `other` instead of inventing phrases.
    private enum OtherKey: Hashable {
        case bash, task, searchedCode, foundFiles, browsedWeb
        case updatedTodos, proposedPlan, sessionMessage, tools

        func phrase(count: Int, failed: Int) -> Phrase {
            // `count` is the category's distinct-key total even for fixed
            // phrases, whose displayed count stays 1; `whole` needs the real
            // total (the official code compares failed against the category's
            // distinct dictionary, round21 §1.11).
            let whole = failed > 0 && failed == count
            switch self {
            case .bash: return Phrase(verb: .ran, unit: .commands, count: count, failed: failed, whole: whole)
            case .task: return Phrase(verb: .ranAgent, unit: .agents, count: count, failed: failed, whole: whole)
            case .searchedCode: return Phrase(verb: .searchedCode, unit: .none, count: 1, failed: failed, whole: whole)
            case .foundFiles: return Phrase(verb: .foundFiles, unit: .none, count: 1, failed: failed, whole: whole)
            case .browsedWeb: return Phrase(verb: .browsedWeb, unit: .none, count: 1, failed: failed, whole: whole)
            case .updatedTodos: return Phrase(verb: .updatedTodos, unit: .none, count: 1, failed: failed, whole: whole)
            case .proposedPlan: return Phrase(verb: .proposedPlan, unit: .none, count: 1, failed: failed, whole: whole)
            // `used` is only the neutral verb slot: adding a `Verb` case
            // would break the app target's exhaustive switches. The row keys
            // on `.sessions` for `ccr_summary_session_message_*`.
            case .sessionMessage: return Phrase(verb: .used, unit: .sessions, count: count, failed: failed, whole: whole)
            case .tools: return Phrase(verb: .used, unit: .tools, count: count, failed: failed, whole: whole)
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
    ///
    /// Official span aggregation (1019 `0x10288fa10`, 1023
    /// `0x103140704..0x103140898`): failed calls and `fileWriteKind == update`
    /// calls are skipped; a call that is neither a diff nor skippable makes
    /// the whole span show no indicator, and an all-zero sum shows none
    /// either. The write kind comes from `fileWriteKind(for:)`; a Write with
    /// an unrecognised result stays an ordinary call instead of being guessed
    /// as an update.
    static func diffStat(for calls: [CodeToolCall]) -> CodeDiffStat? {
        var added = 0
        var removed = 0
        var found = false
        for call in calls {
            // A failed change did not land; its attempted patch is not a diff.
            if call.status == .failed { continue }
            // Official `0x10288fa10`: an update write is skipped entirely;
            // its replacement diff is not a change to count.
            if fileWriteKind(for: call) == .update { continue }
            guard let stat = diffStat(for: call.item) else { return nil }
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

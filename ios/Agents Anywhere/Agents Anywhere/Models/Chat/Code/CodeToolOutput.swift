import Foundation

// The Code page's five-case tool-output model and its wire parser.
//
// The official model carries `DisplayMessage.ToolCall.Output` as a five-case
// enum (text / todos / diff / submittedAnswers / approvedPlan). AA's wire
// carries no such type: a tool row's `content` holds the raw result (Claude:
// `output` / `outputText` / `result` / `text`; Codex: `output` / `result`; file
// changes: `patch` / `changes`) and the connector never tags which of the five
// views it means. This parser reads the wire truth and maps it to the official
// five cases: an explicit tag wins, then the tool kind and the payload shape,
// and anything unrecognised falls back to `text` instead of guessing a richer
// view.
//
// Deliberately no SwiftUI import: this file belongs to the ClientCore target
// (`ios/Package.swift` includes `Models`) so the five-way decision is testable
// without UIKit. `Views/Chat/Code/CodeToolOutputViews.swift` only switches on
// the result.
//
// Failure rules:
// - A failed Edit/Write call never renders its attempted change as a diff
//   (the change did not land); the error text wins, and a raw patch is shown
//   as text only when the wire has no failure message.
// - A file-change payload that is not a valid unified patch still shows its
//   raw patch as text rather than an empty output.

nonisolated struct CodeToolTodo: Identifiable, Hashable {
    nonisolated enum Status: Hashable {
        case pending
        case inProgress
        case completed
    }

    let id: Int
    let content: String
    let status: Status
}

nonisolated struct CodeToolSubmittedAnswer: Identifiable, Hashable {
    let id: Int
    let question: String
    let answer: String
}

/// The official `DiffOutput`: lines plus the two counts and the gutter width
/// seed. `TimelineDiff.Line` is reused as the line type: its parser already
/// handles unified diffs, and its `oldLine` / `newLine` are exactly the two
/// gutters the official row draws.
nonisolated struct CodeToolDiff: Hashable {
    let lines: [TimelineDiff.Line]
    let added: Int
    let removed: Int
    let maxLineNumber: Int

    /// Copy payload for the diff header button. Rebuilt in unified-diff shape
    /// so a pasted diff stays readable even when the wire carried structured
    /// lines.
    var unifiedText: String {
        lines.map { line in
            switch line.kind {
            case .add: "+" + line.text
            case .delete: "-" + line.text
            case .context: " " + line.text
            case .hunk, .file, .annotation: line.text
            }
        }.joined(separator: "\n")
    }
}

nonisolated enum CodeToolOutput: Hashable {
    case text(String)
    case todos([CodeToolTodo])
    case diff(CodeToolDiff)
    case submittedAnswers([CodeToolSubmittedAnswer])
    /// The official case has no payload and renders `EmptyView`; this client
    /// renders the conditional container described in
    /// `docs/perf-6b-c5-code-profile-task.md` §4 ([I]).
    case approvedPlan
    case none

    /// True when there is nothing to render; the detail page hides its whole
    /// output section for this case instead of drawing an empty card.
    var isEmpty: Bool {
        if case .none = self { return true }
        return false
    }

    init(item: V2TimelineItem, kind: CodeToolKind) {
        let content = item.raw["content"] ?? .object([:])
        let payload = Self.outputPayload(in: content)
        let failed = CodeToolStatus(item.status) == .failed
        // Kind is profile-resolved; the wire name is the fallback so a runtime
        // table that maps Edit/Write to `.other` still gets the failure rule.
        let fileChanging = Self.isFileChanging(kind)
            || Self.isFileChangingName(CodeToolCall.wireName(for: item))

        // A failed file change did not land. Never draw its attempted patch
        // as a successful diff: show the failure reason first, and only fall
        // back to the raw patch text when the wire carries no message.
        if failed, fileChanging {
            if let failure = Self.failureText(in: content, payload: payload) {
                self = .text(failure)
                return
            }
            if let raw = Self.rawPatchText(in: content) {
                self = .text(raw)
                return
            }
            self = .none
            return
        }

        if let typed = Self.typedKind(payload) {
            switch typed {
            case "todos", "todo":
                if let todos = Self.todos(from: payload) {
                    self = .todos(todos)
                    return
                }
            case "diff", "patch":
                if let diff = Self.diff(from: payload) {
                    self = .diff(diff)
                    return
                }
            case "submittedanswers", "submitted_answers", "answers":
                if let answers = Self.answers(from: payload) {
                    self = .submittedAnswers(answers)
                    return
                }
            case "approvedplan", "approved_plan":
                self = .approvedPlan
                return
            case "text", "plain":
                if let text = Self.text(from: payload) {
                    self = .text(text)
                    return
                }
            default:
                break
            }
        }

        // TodoWrite's list travels in the tool input on AA's wire; the official
        // page renders that same list as `Output.todos`. Reading the input here
        // is a mapping of the same truth, not a guess at a result the engine
        // never sent.
        if kind == .todo, !failed,
           let todos = Self.todos(from: payload)
            ?? Self.todos(from: content["input"])
            ?? Self.todos(from: content["arguments"]) {
            self = .todos(todos)
            return
        }

        // File-change rows and Edit results carry the patch outside `output`;
        // a unified diff string is recognised only by an official hunk header,
        // so Bash/Read prose that happens to contain `@@` stays text.
        if let diff = Self.diff(from: payload) ?? Self.diff(from: content) {
            self = .diff(diff)
            return
        }

        // AskUserQuestion results and structured submitted-answer payloads.
        // Input questions without an answer do not qualify (answers are never
        // invented).
        if let answers = Self.answers(from: payload)
            ?? Self.answers(from: content["input"])
            ?? Self.answers(from: content["arguments"]) {
            self = .submittedAnswers(answers)
            return
        }

        if kind == .plan, Self.isApprovedPlan(payload) {
            self = .approvedPlan
            return
        }

        if let text = Self.text(from: payload) {
            self = .text(text)
            return
        }

        // Codex file-change rows may carry only `patch` / `changes`; a patch
        // the diff parser rejected is still content the user needs to see.
        if let raw = Self.rawPatchText(in: content) {
            self = .text(raw)
            return
        }

        self = .none
    }

    // MARK: Wire reads

    /// `output` is the one field the task names; the rest are the connector's
    /// own aliases for the same result (Claude stamps several, Codex only
    /// `output` / `result`). Full values come first; `outputPreview` is the
    /// truncated fallback and is used only when no full value exists. Empty
    /// values are skipped so a failed call's `error` can still surface.
    private static func outputPayload(in content: JSONValue) -> JSONValue? {
        for key in ["output", "outputText", "result", "text", "outputPreview", "error"] {
            guard let value = content[key], value != .null else { continue }
            switch value {
            case let .string(text) where text.isEmpty:
                continue
            case let .array(items) where items.isEmpty:
                continue
            case let .object(fields) where fields.isEmpty:
                continue
            default:
                return value
            }
        }
        return nil
    }

    /// The first recognised five-case tag on the payload. `tool_result` and
    /// `file_change` are wire kinds, not output kinds, so they are ignored.
    private static func typedKind(_ value: JSONValue?) -> String? {
        guard let object = value?.objectValue else { return nil }
        let tokens = ["outputType", "kind", "type"]
            .compactMap { object[$0]?.stringValue?.lowercased() }
        let known = ["todos", "todo", "diff", "patch",
                     "submittedanswers", "submitted_answers", "answers",
                     "approvedplan", "approved_plan", "text", "plain"]
        return tokens.first { known.contains($0) }
    }

    /// Edit, Write, MultiEdit and NotebookEdit all classify to `.edit` /
    /// `.write` (`CodeToolSegment.swift`'s name table).
    private static func isFileChanging(_ kind: CodeToolKind) -> Bool {
        switch kind {
        case .edit, .write: return true
        default: return false
        }
    }

    /// Edit / Write / MultiEdit / NotebookEdit by wire name, independent of
    /// the runtime profile's kind mapping.
    private static func isFileChangingName(_ name: String) -> Bool {
        ["edit", "multiedit", "notebookedit", "write", "create",
         "apply_patch", "patch"].contains(name.lowercased())
    }

    /// The failure reason a failed call must surface. `error` is the explicit
    /// field; `isError` calls may only carry `text`; a string payload is the
    /// engine's own message. A structured payload contributes only its
    /// message-like keys, never a diff object's contents.
    private static func failureText(in content: JSONValue, payload: JSONValue?) -> String? {
        if let error = content["error"]?.stringValue, !error.isEmpty {
            return error
        }
        if content["isError"]?.boolValue == true,
           let text = TimelineText.first(content["text"], content["output"],
                                         content["outputText"], content["result"]),
           !text.isEmpty {
            return text
        }
        if let text = payload?.stringValue, !text.isEmpty {
            return text
        }
        if let object = payload?.objectValue,
           let text = TimelineText.first(object["message"], object["detail"],
                                         object["error"]) {
            return text
        }
        return nil
    }

    /// The raw patch text for file changes whose patch is not a parseable
    /// unified diff (Codex artifact rows often have no `output`).
    private static func rawPatchText(in content: JSONValue) -> String? {
        if let patch = content["patch"]?.stringValue, !patch.isEmpty {
            return patch
        }
        if let diff = content["diff"]?.stringValue, !diff.isEmpty {
            return diff
        }
        guard let changes = content["changes"]?.arrayValue else { return nil }
        var parts: [String] = []
        for change in changes {
            guard let text = change["patch"]?.stringValue
                ?? change["diff"]?.stringValue,
                  !text.isEmpty else { continue }
            if let path = TimelineText.first(change["path"], change["filePath"],
                                             change["file"]),
               !path.isEmpty {
                parts.append("\(path)\n\(text)")
            } else {
                parts.append(text)
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    // MARK: Todos

    /// An explicit empty `todos` array means "cleared", not "no todos data":
    /// the official TodoWrite branch has a dedicated cleared state. A value
    /// with no todo container at all returns nil.
    private static func todos(from value: JSONValue?) -> [CodeToolTodo]? {
        guard let value else { return nil }
        let array: [JSONValue]?
        if let direct = value.arrayValue {
            array = direct
        } else if let object = value.objectValue {
            array = object["todos"]?.arrayValue
                ?? object["items"]?.arrayValue
                ?? object["tasks"]?.arrayValue
                // DSH's `update_plan` carries its steps under `plan`.
                ?? object["plan"]?.arrayValue
        } else {
            array = nil
        }
        guard let array else { return nil }
        guard !array.isEmpty else { return [] }

        let parsed = array.enumerated().compactMap { index, entry -> CodeToolTodo? in
            guard let object = entry.objectValue else {
                guard let text = entry.stringValue, !text.isEmpty else { return nil }
                return CodeToolTodo(id: index, content: text, status: .pending)
            }
            guard let content = TimelineText.first(object["content"],
                                                   object["text"],
                                                   object["title"],
                                                   object["subject"],
                                                   object["step"]),
                  !content.isEmpty else { return nil }
            return CodeToolTodo(id: index,
                                content: content,
                                status: todoStatus(object))
        }
        return parsed.isEmpty ? nil : parsed
    }

    private static func todoStatus(_ object: [String: JSONValue]) -> CodeToolTodo.Status {
        let raw = TimelineText.first(object["status"], object["state"])?
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        switch raw {
        case "completed", "complete", "done", "checked": return .completed
        case "in_progress", "inprogress", "active", "running", "current", "started":
            return .inProgress
        default:
            return .pending
        }
    }

    // MARK: Submitted answers

    private static func answers(from value: JSONValue?) -> [CodeToolSubmittedAnswer]? {
        guard let value else { return nil }
        if let direct = value.arrayValue {
            return answerPairs(direct)
        }
        guard let object = value.objectValue else { return nil }

        // Wrapped arrays and dictionaries.
        for key in ["submittedAnswers", "submitted_answers", "answers"] {
            if let array = object[key]?.arrayValue, let parsed = answerPairs(array) {
                return parsed
            }
            if let dictionary = object[key]?.objectValue,
               let parsed = answerDictionary(dictionary) {
                return parsed
            }
        }
        if let questions = object["questions"]?.arrayValue,
           let parsed = answerPairs(questions) {
            return parsed
        }

        // A bare question -> answer map. Structural keys are excluded so an
        // input question object (`question` / `answer` / `options`) is not
        // split into two fake pairs.
        if looksLikeAnswerDictionary(object),
           let parsed = answerDictionary(object) {
            return parsed
        }
        return nil
    }

    private static func answerPairs(_ array: [JSONValue]) -> [CodeToolSubmittedAnswer]? {
        guard !array.isEmpty else { return nil }
        let parsed = array.enumerated().compactMap { index, entry -> CodeToolSubmittedAnswer? in
            guard let object = entry.objectValue else { return nil }
            let question = TimelineText.first(object["question"],
                                              object["prompt"],
                                              object["header"],
                                              object["title"]) ?? ""
            // An answer is mandatory: `AskUserQuestion` input without a
            // response must not render as an answered question.
            guard let answer = answerText(object["answer"]
                                          ?? object["response"]
                                          ?? object["value"]
                                          ?? object["selected"]),
                  !answer.isEmpty else { return nil }
            return CodeToolSubmittedAnswer(id: index, question: question, answer: answer)
        }
        return parsed.isEmpty ? nil : parsed
    }

    /// A dictionary of question -> answer. JSON objects have no order, so the
    /// keys are sorted for a stable render; a `questions` array (handled
    /// above) remains the ordered form when the wire provides one.
    private static func answerDictionary(_ object: [String: JSONValue]) -> [CodeToolSubmittedAnswer]? {
        guard !object.isEmpty else { return nil }
        let parsed = object.keys.sorted().enumerated().compactMap { index, key -> CodeToolSubmittedAnswer? in
            guard let answer = answerText(object[key]), !answer.isEmpty else { return nil }
            return CodeToolSubmittedAnswer(id: index, question: key, answer: answer)
        }
        return parsed.isEmpty ? nil : parsed
    }

    private static func looksLikeAnswerDictionary(_ object: [String: JSONValue]) -> Bool {
        guard !object.isEmpty else { return false }
        let structural: Set<String> = [
            "kind", "type", "outputType", "todos", "items", "tasks", "plan",
            "questions", "submittedAnswers", "submitted_answers", "answers",
            "lines", "lineStat", "maxLineNumber", "patch", "diff", "changes",
            "error", "text", "output", "outputText", "result", "outputPreview",
            "content", "value", "question", "answer", "prompt", "response",
            "title", "header", "selected", "label", "options",
        ]
        guard !object.keys.contains(where: { structural.contains($0) }) else {
            return false
        }
        return object.values.allSatisfy { answerText($0) != nil }
    }

    private static func answerText(_ value: JSONValue?) -> String? {
        guard let value, value != .null else { return nil }
        if let text = value.stringValue { return text.isEmpty ? nil : text }
        if let array = value.arrayValue {
            let parts = array.compactMap { item in
                item.stringValue
                    ?? TimelineText.first(item["label"], item["text"],
                                          item["value"], item["answer"])
            }
            return parts.isEmpty ? nil : parts.joined(separator: ", ")
        }
        if let object = value.objectValue {
            return TimelineText.first(object["label"], object["text"],
                                      object["value"], object["answer"])
        }
        return nil
    }

    // MARK: Diff

    private static func diff(from value: JSONValue?) -> CodeToolDiff? {
        guard let value else { return nil }

        if let object = value.objectValue {
            if let lineValues = object["lines"]?.arrayValue, !lineValues.isEmpty,
               looksLikeDiffPayload(object, lines: lineValues) {
                let lines = structuredLines(lineValues)
                if !lines.isEmpty { return makeDiff(lines: lines, from: object) }
            }
            if let nested = object["diff"], let parsed = diff(from: nested) { return parsed }
            if let nested = object["patch"], let parsed = diff(from: nested) { return parsed }

            // Codex/Claude file-change rows publish one entry per file.
            if let changes = object["changes"]?.arrayValue {
                var lines: [TimelineDiff.Line] = []
                for change in changes {
                    let action = TimelineText.first(change["action"],
                                                    change["kind"]?["type"])?
                        .lowercased()
                    if let nested = change["diff"] ?? change["patch"] {
                        if let parsed = diff(from: nested) {
                            lines.append(contentsOf: parsed.lines)
                        } else if let text = nested.stringValue,
                                  isAddAction(action) {
                            // A created file's `diff` is the whole new file,
                            // not a unified patch; every line is an addition.
                            lines.append(contentsOf: addedLines(text))
                        }
                    } else if let nestedLines = change["lines"]?.arrayValue {
                        lines.append(contentsOf: structuredLines(nestedLines))
                    }
                }
                if !lines.isEmpty {
                    return makeDiff(lines: reindexed(lines), from: object)
                }
            }
        }

        if let text = value.stringValue, isUnifiedDiff(text) {
            return makeDiff(lines: reindexed(TimelineDiff(text).lines), from: nil)
        }
        return nil
    }

    private static func isAddAction(_ action: String?) -> Bool {
        guard let action else { return false }
        return ["add", "added", "create", "created", "new"].contains(action)
    }

    /// A created file's `diff` field is its full content, so represent it as
    /// an all-add page rather than pretending it is a unified patch.
    private static func addedLines(_ text: String) -> [TimelineDiff.Line] {
        var parts = text.components(separatedBy: "\n")
        if parts.last == "" { parts.removeLast() }
        return parts.enumerated().map { index, line in
            TimelineDiff.Line(id: index, kind: .add, text: line,
                              oldLine: nil, newLine: index + 1)
        }
    }

    /// A bare `lines` array is not enough to claim a diff: a generic JSON tool
    /// result may contain one. Require a diff stat / max-line key, a tagged
    /// payload, or at least one line that actually carries a diff prefix or
    /// kind. Anything weaker stays text.
    private static func looksLikeDiffPayload(_ object: [String: JSONValue],
                                             lines: [JSONValue]) -> Bool {
        if object["lineStat"] != nil || object["maxLineNumber"] != nil
            || object["addedLineCount"] != nil || object["removedLineCount"] != nil {
            return true
        }
        if let tag = TimelineText.first(object["type"], object["kind"])?.lowercased(),
           tag == "diff" || tag == "patch" {
            return true
        }
        return lines.contains { value in
            if let text = value.stringValue {
                return text.hasPrefix("+") || text.hasPrefix("-")
                    || text.hasPrefix("@@") || text.hasPrefix("diff --git")
            }
            guard let line = value.objectValue else { return false }
            let kind = TimelineText.first(line["type"], line["kind"])?.lowercased() ?? ""
            return ["add", "added", "insert", "insertion",
                    "remove", "removed", "delete", "deleted", "deletion",
                    "hunk", "header"].contains(kind)
        }
    }

    /// `DiffOutput.lines` from the official model, or the same shape as JSON.
    private static func structuredLines(_ values: [JSONValue]) -> [TimelineDiff.Line] {
        values.enumerated().compactMap { index, value -> TimelineDiff.Line? in
            if let text = value.stringValue, !text.isEmpty {
                let kind = prefixKind(text)
                let content = (kind == .add || kind == .delete
                    || (kind == .context && text.hasPrefix(" ")))
                    ? String(text.dropFirst()) : text
                return TimelineDiff.Line(id: index, kind: kind, text: content,
                                         oldLine: nil, newLine: nil)
            }
            guard let object = value.objectValue else { return nil }
            let rawKind = TimelineText.first(object["type"], object["kind"])?
                .lowercased() ?? "normal"
            let kind: TimelineDiff.Line.Kind
            switch rawKind {
            case "add", "added", "insert", "insertion": kind = .add
            case "remove", "removed", "delete", "deleted", "deletion": kind = .delete
            case "hunk", "header", "@@": kind = .hunk
            case "file", "meta", "metadata": kind = .file
            case "annotation", "note": kind = .annotation
            default: kind = .context
            }
            guard let text = TimelineText.first(object["content"],
                                                object["text"],
                                                object["value"],
                                                object["line"]) else { return nil }
            return TimelineDiff.Line(
                id: index,
                kind: kind,
                text: text,
                oldLine: object["oldLineNumber"]?.intValue
                    ?? object["oldLine"]?.intValue
                    ?? object["old"]?.intValue,
                newLine: object["newLineNumber"]?.intValue
                    ?? object["newLine"]?.intValue
                    ?? object["new"]?.intValue)
        }
    }

    private static func prefixKind(_ text: String) -> TimelineDiff.Line.Kind {
        if text.hasPrefix("@@") { return .hunk }
        if ["diff --git", "index ", "--- ", "+++ "].contains(where: text.hasPrefix) {
            return .file
        }
        if text.hasPrefix("\\") { return .annotation }
        if text.hasPrefix("+") { return .add }
        if text.hasPrefix("-") { return .delete }
        return .context
    }

    /// A plain string becomes a diff only with the official hunk header
    /// (`^@@ -\d`). Bash/Read output containing a stray `@@` line must stay
    /// text; a `diff --git` header alone proves no hunk.
    private static func isUnifiedDiff(_ code: String) -> Bool {
        code.components(separatedBy: "\n").contains { line in
            guard line.hasPrefix("@@ -") else { return false }
            return line.dropFirst(4).first?.isNumber == true
        }
    }

    /// Duplicate ids appear when several files' patches are concatenated;
    /// `ForEach` requires one id per row.
    private static func reindexed(_ lines: [TimelineDiff.Line]) -> [TimelineDiff.Line] {
        lines.enumerated().map { index, line in
            TimelineDiff.Line(id: index, kind: line.kind, text: line.text,
                              oldLine: line.oldLine, newLine: line.newLine)
        }
    }

    private static func makeDiff(lines: [TimelineDiff.Line],
                                 from object: [String: JSONValue]?) -> CodeToolDiff {
        let stat = object?["lineStat"]?.objectValue
        let added = stat?["addedLineCount"]?.intValue
            ?? stat?["added"]?.intValue
            ?? object?["addedLineCount"]?.intValue
            ?? lines.filter { $0.kind == .add }.count
        let removed = stat?["removedLineCount"]?.intValue
            ?? stat?["removed"]?.intValue
            ?? object?["removedLineCount"]?.intValue
            ?? lines.filter { $0.kind == .delete }.count
        let maxLineNumber = object?["maxLineNumber"]?.intValue
            ?? lines.compactMap { line in
                [line.oldLine, line.newLine].compactMap { $0 }.max()
            }.max()
            ?? 0
        return CodeToolDiff(lines: lines,
                            added: added,
                            removed: removed,
                            maxLineNumber: maxLineNumber)
    }

    // MARK: Approved plan

    private static func isApprovedPlan(_ value: JSONValue?) -> Bool {
        guard let object = value?.objectValue else { return false }
        if object["approvedPlan"]?.boolValue == true { return true }
        if object["approved"]?.boolValue == true { return true }
        let typed = typedKind(value)
        return typed == "approvedplan" || typed == "approved_plan"
    }

    // MARK: Text

    private static func text(from value: JSONValue?) -> String? {
        guard let value, value != .null else { return nil }
        if let text = value.stringValue { return text.isEmpty ? nil : text }
        if let object = value.objectValue {
            // Claude's tool result may wrap text blocks in an envelope; show
            // the text rather than pretty-printing the envelope.
            if let blocks = object["content"]?.arrayValue {
                let texts = blocks.compactMap { block -> String? in
                    guard block["type"]?.stringValue == "text" else { return nil }
                    return block["text"]?.stringValue
                }
                if !texts.isEmpty { return texts.joined(separator: "\n") }
            }
            if let text = TimelineText.first(object["text"], object["content"],
                                             object["value"], object["output"]) {
                return text
            }
        }
        let json = value.formattedJSON
        return json.isEmpty ? nil : json
    }
}

import SwiftUI
import UIKit

// The Code page's five tool-output renderers (`CANONICAL/04-tool-calls.md`
// §5.2). The official model carries `DisplayMessage.ToolCall.Output` as a
// five-case enum; AA's wire carries no such type. A tool row's `content` holds
// the raw result (Claude: `output` / `outputText` / `result` / `text`; Codex:
// `output` / `result`; file changes: `patch` / `changes`) and the connector
// never tags which of the five views it means. The parser below reads the wire
// truth and maps it to the official five cases: an explicit tag wins, then the
// tool kind and the payload shape, and anything unrecognised falls back to the
// `text` view instead of guessing a richer one.
//
// Visual constants the shared theme does not carry yet live in
// `CodeToolCardMetrics` at the bottom of this file. Every one is tagged
// `[E]` / `[I]` / `[U]` with its source (`docs/code-page-visual-evidence.md`
// V-numbers, or the CANONICAL section) so they can be folded into
// `CodePageTheme` once the detail page's visual gate is closed.

// MARK: - Output model

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

    /// Copy payload for the header button. Rebuilt in unified-diff shape so a
    /// pasted diff stays readable even when the wire carried structured lines.
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

    init(item: V2TimelineItem, kind: CodeToolKind) {
        let content = item.raw["content"] ?? .object([:])
        let payload = Self.outputPayload(in: content)
        // A failed TodoWrite never applied its input list; falling back to that
        // list would show work that did not happen and hide the error text.
        let failed = CodeToolStatus(item.status) == .failed

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
        // a unified diff string is recognised only by strong headers, so Bash
        // prose that happens to start with a dash stays text.
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
        self = .none
    }

    // MARK: Wire reads

    /// `output` is the one field the task names; the rest are the connector's
    /// own aliases for the same result (Claude stamps all of them, Codex only
    /// `output` / `result`). Empty values are skipped so a failed call's
    /// `error` can still surface.
    private static func outputPayload(in content: JSONValue) -> JSONValue? {
        // Full values first; `outputPreview` is the connector's truncated
        // fallback and is used only when no full value exists.
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

    // MARK: Todos

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
        guard let array, !array.isEmpty else { return nil }

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
        let array: [JSONValue]?
        if let direct = value.arrayValue {
            array = direct
        } else if let object = value.objectValue {
            array = object["submittedAnswers"]?.arrayValue
                ?? object["submitted_answers"]?.arrayValue
                ?? object["answers"]?.arrayValue
                ?? object["questions"]?.arrayValue
        } else {
            array = nil
        }
        guard let array, !array.isEmpty else { return nil }

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

    /// A plain string becomes a diff only with a real unified-diff header.
    /// Prose that begins with `-` (a bullet list in Bash output) must stay text.
    private static func isUnifiedDiff(_ code: String) -> Bool {
        let lines = code.components(separatedBy: "\n")
        if lines.contains(where: { $0.hasPrefix("diff --git") || $0.hasPrefix("@@") }) {
            return true
        }
        return lines.contains(where: { $0.hasPrefix("--- ") })
            && lines.contains(where: { $0.hasPrefix("+++ ") })
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

// MARK: - Output switcher

struct CodeToolOutputView: View {
    let output: CodeToolOutput

    var body: some View {
        switch output {
        case let .text(text):
            CodeToolCodeCard(title: String(localized: "Output"), code: text)
        case let .todos(todos):
            CodeToolTodosOutputView(todos: todos)
        case let .diff(diff):
            CodeToolDiffOutputView(diff: diff)
        case let .submittedAnswers(answers):
            CodeToolSubmittedAnswersOutputView(answers: answers)
        case .approvedPlan:
            CodeToolApprovedPlanOutputView()
        case .none:
            CodeToolEmptyOutputView()
        }
    }
}

// MARK: - Text output (official `CodeBlockContent`)

/// The official code-card chrome: 44 pt header, 13/20.8 mono title, 24 pt
/// continuous corners, 16 pt content inset, 1 physical-pixel border and
/// divider (`docs/code-page-visual-evidence.md` V61-V69). The text is a
/// monospaced block that scrolls horizontally; the page scrolls vertically, so
/// this view does not nest a second vertical scroller.
///
/// The rendered prefix is capped at 200 000 characters, the same guard
/// `TimelineCodePanel` uses (`Views/Chat/SessionTimelineEventView.swift:327`);
/// copying always takes the full string.
struct CodeToolCodeCard: View {
    let title: String
    let code: String

    private let displayCode: String
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale
    @ScaledMetric(relativeTo: .footnote) private var codeFontSize =
        CodeToolCardMetrics.codeFontSize
    @ScaledMetric(relativeTo: .caption) private var titleFontSize =
        CodeToolCardMetrics.titleFontSize

    init(title: String, code: String) {
        self.title = title
        self.code = code
        displayCode = String(code.prefix(CodeToolCardMetrics.previewLimit))
    }

    private var surface: Color {
        CodeToolCardMetrics.surface.resolved(for: colorScheme)
    }

    private var border: Color {
        CodeToolCardMetrics.border.resolved(for: colorScheme)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle()
                .fill(border)
                .frame(height: 1 / displayScale)
            codeBody
            if displayCode.count < code.count {
                Text(String(localized: "预览已截断，复制可获取完整内容"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, CodeToolCardMetrics.contentInset)
                    .padding(.bottom, 12)
            }
        }
        .background(surface)
        .clipShape(RoundedRectangle(cornerRadius: CodeToolCardMetrics.cornerRadius,
                                    style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: CodeToolCardMetrics.cornerRadius,
                             style: .continuous)
                .stroke(border, lineWidth: 1 / displayScale)
                .allowsHitTesting(false)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(verbatim: title)
                .font(.system(size: titleFontSize,
                              weight: .regular,
                              design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(minHeight: CodeToolCardMetrics.titleLineHeight)
                .lineLimit(1)
            Spacer(minLength: 8)
            CodeToolCopyButton(text: { code },
                               label: String(localized: "复制代码"),
                               size: 44)
        }
        .padding(.horizontal, CodeToolCardMetrics.headerHorizontalPadding)
        .frame(height: CodeToolCardMetrics.headerHeight)
    }

    private var codeBody: some View {
        ScrollView(.horizontal) {
            Text(verbatim: displayCode)
                .font(.system(size: codeFontSize, design: .monospaced))
                .lineSpacing(CodeToolCardMetrics.codeLineSpacing)
                .textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: false)
                .padding(CodeToolCardMetrics.contentInset)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
    }
}

// MARK: - Todos (official `TodoListView`)

private struct CodeToolTodosOutputView: View {
    let todos: [CodeToolTodo]

    @ScaledMetric(relativeTo: .body) private var todoFontSize =
        CodeToolCardMetrics.todoFontSize

    private var copyText: String {
        todos.map { todo in
            let mark: String
            switch todo.status {
            case .pending: mark = "[ ]"
            case .inProgress: mark = "[~]"
            case .completed: mark = "[x]"
            }
            return "\(mark) \(todo.content)"
        }.joined(separator: "\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CodeToolSectionHeader(title: String(localized: "Todos"), copyText: copyText)
            VStack(alignment: .leading, spacing: CodeToolCardMetrics.todoRowSpacing) {
                ForEach(todos) { todo in
                    row(todo)
                }
            }
        }
    }

    /// Three states, two inks: the official `TodoRow` only branches on
    /// `completed` versus the rest (`CANONICAL/04-tool-calls.md` §5.2); the
    /// three states stay distinguishable by glyph. The two RGB slots are
    /// unknown ([U], V71), so semantic primary/secondary stand in.
    private func row(_ todo: CodeToolTodo) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol(todo.status))
                .font(.system(size: todoFontSize))
                .foregroundStyle(todo.status == .completed ? Color.secondary : Color.primary)
                .frame(width: 18, height: 20)
                .accessibilityHidden(true)
            Text(verbatim: todo.content)
                .font(.system(size: todoFontSize))
                .foregroundStyle(todo.status == .completed ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: "\(statusLabel(todo.status)): \(todo.content)"))
    }

    private func symbol(_ status: CodeToolTodo.Status) -> String {
        switch status {
        case .pending: return "circle"
        case .inProgress: return "circle.lefthalf.filled"
        case .completed: return "checkmark.circle.fill"
        }
    }

    private func statusLabel(_ status: CodeToolTodo.Status) -> String {
        switch status {
        case .pending: return String(localized: "待处理")
        case .inProgress: return String(localized: "进行中")
        case .completed: return String(localized: "已完成")
        }
    }
}

// MARK: - Diff (official `PagedDiffRows`, 300 rows per page)

private struct CodeToolDiffOutputView: View {
    let diff: CodeToolDiff

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale
    @State private var visibleCount = CodeToolCardMetrics.diffPageSize
    @ScaledMetric(relativeTo: .caption) private var titleFontSize =
        CodeToolCardMetrics.titleFontSize
    @ScaledMetric(relativeTo: .caption) private var diffFontSize =
        CodeToolCardMetrics.diffFontSize
    @ScaledMetric(relativeTo: .caption) private var diffStatFontSize =
        CodeToolCardMetrics.diffStatFontSize

    private var visibleLines: [TimelineDiff.Line] {
        Array(diff.lines.prefix(visibleCount))
    }

    private var gutterDigits: Int {
        max(1, String(max(0, diff.maxLineNumber)).count)
    }

    private var gutterWidth: CGFloat {
        // SF Mono advances ~0.6 em per digit; deriving from the scaled font
        // keeps the gutter aligned when Dynamic Type grows the code.
        CGFloat(gutterDigits) * diffFontSize * CodeToolCardMetrics.diffGutterDigitRatio
    }

    private var surface: Color {
        CodeToolCardMetrics.surface.resolved(for: colorScheme)
    }

    private var border: Color {
        CodeToolCardMetrics.border.resolved(for: colorScheme)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle()
                .fill(border)
                .frame(height: 1 / displayScale)
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(visibleLines) { line in
                    row(line)
                }
            }
            if visibleCount < diff.lines.count {
                Rectangle()
                    .fill(border)
                    .frame(height: 1 / displayScale)
                loadMore
            }
        }
        .background(surface)
        .clipShape(RoundedRectangle(cornerRadius: CodeToolCardMetrics.cornerRadius,
                                    style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: CodeToolCardMetrics.cornerRadius,
                             style: .continuous)
                .stroke(border, lineWidth: 1 / displayScale)
                .allowsHitTesting(false)
        }
        .onChange(of: diff) { _, _ in
            visibleCount = CodeToolCardMetrics.diffPageSize
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(String(localized: "Diff"))
                .font(.system(size: titleFontSize,
                              weight: .regular,
                              design: .monospaced))
                .foregroundStyle(.secondary)
            if diff.added > 0 {
                Text(verbatim: "+\(diff.added)")
                    .font(.system(size: diffStatFontSize,
                                  design: .monospaced))
                    .foregroundStyle(CodePageTheme.diffAdd.resolved(for: colorScheme))
            }
            if diff.removed > 0 {
                Text(verbatim: "−\(diff.removed)")
                    .font(.system(size: diffStatFontSize,
                                  design: .monospaced))
                    .foregroundStyle(CodePageTheme.diffRemove.resolved(for: colorScheme))
            }
            Spacer(minLength: 8)
            CodeToolCopyButton(text: { diff.unifiedText },
                               label: String(localized: "复制 Diff"),
                               size: 44)
        }
        .padding(.horizontal, CodeToolCardMetrics.headerHorizontalPadding)
        .frame(height: CodeToolCardMetrics.headerHeight)
    }

    private var loadMore: some View {
        Button {
            visibleCount = min(visibleCount + CodeToolCardMetrics.diffPageSize,
                               diff.lines.count)
        } label: {
            Text(String(localized: "加载更多"))
                .font(.system(size: 13, weight: .medium))
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tint)
    }

    @ViewBuilder
    private func row(_ line: TimelineDiff.Line) -> some View {
        if isMetadata(line.kind) {
            Text(verbatim: line.text.isEmpty ? " " : line.text)
                .font(.system(size: diffFontSize, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.leading, CodeToolCardMetrics.contentInset)
                .padding(.trailing, CodeToolCardMetrics.contentInset)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(minHeight: CodeToolCardMetrics.diffLineHeight)
        } else {
            HStack(alignment: .top, spacing: 4) {
                // CANONICAL/04-tool-calls.md §5.2 ([I]): an added line shows
                // its new number, a removed line its old one; context shows
                // both. The wire may stamp both numbers, so blank the side the
                // official rule does not show.
                Text(verbatim: number(line.kind == .add ? nil : line.oldLine))
                    .frame(width: gutterWidth, alignment: .trailing)
                Text(verbatim: number(line.kind == .delete ? nil : line.newLine))
                    .frame(width: gutterWidth, alignment: .trailing)
                Text(verbatim: sign(line.kind))
                    .frame(width: 8, alignment: .leading)
                Text(verbatim: line.text.isEmpty ? " " : line.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.system(size: diffFontSize, design: .monospaced))
            .monospacedDigit()
            .foregroundStyle(.primary)
            .padding(.leading, CodeToolCardMetrics.contentInset)
            .padding(.trailing, CodeToolCardMetrics.contentInset)
            .frame(minHeight: CodeToolCardMetrics.diffLineHeight)
            .background(fill(line.kind))
            .overlay(alignment: .leading) {
                if let bar = barColor(line.kind) {
                    Rectangle()
                        .fill(bar)
                        .frame(width: CodeToolCardMetrics.diffBarWidth)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func isMetadata(_ kind: TimelineDiff.Line.Kind) -> Bool {
        kind == .hunk || kind == .file || kind == .annotation
    }

    private func number(_ value: Int?) -> String {
        value.map(String.init) ?? ""
    }

    private func sign(_ kind: TimelineDiff.Line.Kind) -> String {
        switch kind {
        case .add: return "+"
        case .delete: return "−"
        default: return " "
        }
    }

    private func barColor(_ kind: TimelineDiff.Line.Kind) -> Color? {
        switch kind {
        case .add: return CodePageTheme.diffAdd.resolved(for: colorScheme)
        case .delete: return CodePageTheme.diffRemove.resolved(for: colorScheme)
        default: return nil
        }
    }

    private func fill(_ kind: TimelineDiff.Line.Kind) -> Color {
        switch kind {
        case .add: return CodeToolCardMetrics.diffAddRowFill.resolved(for: colorScheme)
        case .delete: return CodeToolCardMetrics.diffRemoveRowFill.resolved(for: colorScheme)
        default: return .clear
        }
    }
}

// MARK: - Submitted answers (official `AskUserQuestionSubmittedView`, [I])

private struct CodeToolSubmittedAnswersOutputView: View {
    let answers: [CodeToolSubmittedAnswer]

    @ScaledMetric(relativeTo: .caption) private var questionFontSize =
        CodeToolCardMetrics.answerQuestionFontSize
    @ScaledMetric(relativeTo: .body) private var answerFontSize =
        CodeToolCardMetrics.answerFontSize

    private var copyText: String {
        answers.map { pair in
            pair.question.isEmpty
                ? pair.answer
                : "Q: \(pair.question)\nA: \(pair.answer)"
        }.joined(separator: "\n\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CodeToolSectionHeader(title: String(localized: "Answers"), copyText: copyText)
            VStack(alignment: .leading, spacing: CodeToolCardMetrics.answerPairSpacing) {
                ForEach(answers) { pair in
                    VStack(alignment: .leading, spacing: 4) {
                        if !pair.question.isEmpty {
                            Text(verbatim: pair.question)
                                .font(.system(size: questionFontSize,
                                              weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        Text(verbatim: pair.answer)
                            .font(.system(size: answerFontSize))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}

// MARK: - Approved plan (conditional container, [I])

/// The official `approvedPlan` case carries no payload and mounts `EmptyView`
/// (`CANONICAL/04-tool-calls.md` §5.2, inference). Until a real capture closes
/// the container's contents, this draws an explicit placeholder rather than
/// inventing a plan body.
private struct CodeToolApprovedPlanOutputView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CodeToolSectionHeader(title: String(localized: "Plan"), copyText: nil)
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "checkmark.seal")
                    .font(.system(size: 17))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(String(localized: "已批准的计划"))
                        .font(.system(size: 15, weight: .medium))
                    Text(String(localized: "计划正文暂不在本页展示"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemBackground),
                        in: RoundedRectangle(cornerRadius: CodeToolCardMetrics.planCornerRadius,
                                             style: .continuous))
            .accessibilityElement(children: .combine)
        }
    }
}

// MARK: - Empty output

private struct CodeToolEmptyOutputView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CodeToolSectionHeader(title: String(localized: "Output"), copyText: nil)
            Text(String(localized: "暂无输出"))
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Shared pieces

/// The copy control shared by the code card, the diff header and the list
/// section headers. Same 2-second confirmation `TimelineCodePanel` and
/// `ChatMarkdownCodeBlock` use.
private struct CodeToolCopyButton: View {
    /// Built only on tap: a long diff's unified text must not be rebuilt on
    /// every body evaluation.
    let text: () -> String
    let label: String
    var size: CGFloat = 44

    @State private var copied = false

    var body: some View {
        Button {
            UIPasteboard.general.string = text()
            copied = true
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: size >= 44 ? 15 : 13, weight: .medium))
                .foregroundStyle(copied ? Color.green : Color.secondary)
                .frame(width: size, height: size)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(copied ? String(localized: "已复制") : label)
        .task(id: copied) {
            guard copied else { return }
            do {
                try await Task.sleep(for: .seconds(2))
                copied = false
            } catch {}
        }
    }
}

private struct CodeToolSectionHeader: View {
    let title: String
    let copyText: String?

    @ScaledMetric(relativeTo: .caption) private var titleFontSize =
        CodeToolCardMetrics.titleFontSize

    var body: some View {
        HStack(spacing: 8) {
            Text(verbatim: title)
                .font(.system(size: titleFontSize,
                              weight: .regular,
                              design: .monospaced))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            if let copyText {
                CodeToolCopyButton(text: { copyText },
                                   label: String(localized: "复制内容"),
                                   size: 32)
            }
        }
        .frame(minHeight: 32)
    }
}

// MARK: - Detail-page-only metrics

/// Values the shared `CodePageTheme` does not carry yet. Sources:
/// - `[E]` = `CANONICAL/06-visuals-assets.md` §1.3/§3.2/§3.3 and
///   `DATA/tokens.json`, mirrored as V61-V69 in
///   `docs/code-page-visual-evidence.md`.
/// - `[I]` = measured from the reference frames listed in that document.
/// - `[U]` = no evidence; the stand-in is labelled.
///
/// Suggested follow-up: move the code-card block (V61-V69), the diff metrics
/// (V74/V78) and the todo/answer typography into `CodePageTheme` once the
/// detail-page visual gate has real-device captures.
private enum CodeToolCardMetrics {

    // MARK: Code card (official `CodeBlockContent`)

    /// [E] V61 / CANONICAL/06-visuals-assets.md §3.3 — header height 44 pt.
    static let headerHeight: CGFloat = 44

    /// [E] V62 / tokens.json `codeCard.title.typography` — 13 pt.
    static let titleFontSize: CGFloat = 13

    /// [E] V62 — title line height 20.8 pt.
    static let titleLineHeight: CGFloat = 20.8

    /// [E] V66 — 24 pt, `.continuous`.
    static let cornerRadius: CGFloat = 24

    /// [E] V67 — content inset 16 pt on all four sides.
    static let contentInset: CGFloat = 16

    /// [E] V68 — header padding 16 pt (value proven; edge direction is [U]).
    static let headerHorizontalPadding: CGFloat = 16

    /// [E] V64 — light `#FFFFFF`, dark `#20201F`.
    static let surface = CodePageTheme.SchemeColor(
        light: Color(.sRGB, red: 1, green: 1, blue: 1),
        dark: Color(.sRGB, red: 32.0 / 255.0,
                    green: 32.0 / 255.0,
                    blue: 31.0 / 255.0))

    /// [E] V65 — light `rgba(0.118,0.118,0.114,0.3)`,
    /// dark `rgba(0.882,0.878,0.851,0.3)`.
    static let border = CodePageTheme.SchemeColor(
        light: Color(.sRGB, red: 0.118, green: 0.118, blue: 0.114, opacity: 0.3),
        dark: Color(.sRGB, red: 0.882, green: 0.878, blue: 0.851, opacity: 0.3))

    /// [E] V63 — monospaced body 15 pt / 24 pt line height.
    static let codeFontSize: CGFloat = 15
    static let codeLineHeight: CGFloat = 24

    /// [I] Derived from the [E] 24 pt line height: SF Mono at 15 pt has a
    /// ~17.9 pt default line box, so SwiftUI needs ~6.1 pt extra spacing.
    static let codeLineSpacing: CGFloat = 6

    /// Existing `TimelineCodePanel` guard (rendered prefix capped at 200 000
    /// characters; copy still takes the full value). Reused here so a huge
    /// tool result cannot stall layout.
    static let previewLimit = 200_000

    // MARK: Diff (official `DiffView` / `PagedDiffRows`)

    /// [E] CANONICAL/04-tool-calls.md §5.2 — 2 pt colour bar.
    static let diffBarWidth: CGFloat = 2

    /// [I] V78 — code body ≈12 pt with ≈15 pt line height; the official token
    /// is not closed.
    static let diffFontSize: CGFloat = 12
    static let diffLineHeight: CGFloat = 15

    /// [I] Derived: SF Mono advances ~0.6 em per digit (12 pt -> ~7.2 pt).
    static let diffGutterDigitRatio: CGFloat = 0.6

    /// [E] CANONICAL/04-tool-calls.md §5.2 — `rowsPerPage = 300`.
    static let diffPageSize = 300

    /// [I] V77 — diff stats use the code-card title preset (13 pt mono).
    static let diffStatFontSize: CGFloat = 13

    /// [I] V79 — light add-row fill `#E0F1DE`. There is no dark capture, so the
    /// dark row derives the same tint from the [E] add colour at 14 %.
    static let diffAddRowFill = CodePageTheme.SchemeColor(
        light: Color(.sRGB, red: 224.0 / 255.0,
                    green: 241.0 / 255.0,
                    blue: 222.0 / 255.0),
        dark: CodePageTheme.diffAdd.dark.opacity(0.14))

    /// [U] V79 gives no remove-row fill; the row derives it from the [E]
    /// remove colour (10 % light, 14 % dark) so add/remove stay symmetric.
    static let diffRemoveRowFill = CodePageTheme.SchemeColor(
        light: CodePageTheme.diffRemove.light.opacity(0.10),
        dark: CodePageTheme.diffRemove.dark.opacity(0.14))

    // MARK: Todos / answers / plan

    /// [U] V70-V72 — no sampled row spacing; 10 pt matches the timeline's
    /// inter-message rhythm.
    static let todoRowSpacing: CGFloat = 10

    /// [U] V72 — no sampled todo text size; 15 pt matches the Code page's
    /// tool-row text size and keeps the list aligned with the tool rows.
    static let todoFontSize: CGFloat = 15

    /// [U] V72 — no sampled answer typography; question uses the 13 pt
    /// caption size, answer the 15 pt body size.
    static let answerQuestionFontSize: CGFloat = 13
    static let answerFontSize: CGFloat = 15

    /// [U] V72 — pair spacing sampled at 16 pt (same as block spacing).
    static let answerPairSpacing: CGFloat = 16

    /// [E] CANONICAL/04-tool-calls.md §6.2 — the 16 pt shell used by
    /// WritingDraft / PlanUsage-style cards (the tool-row shell is 8 pt).
    static let planCornerRadius: CGFloat = 16
}

// MARK: - Previews

#Preview("Tool output — todos") {
    CodeToolOutputView(output: .todos([
        CodeToolTodo(id: 0, content: "Inspect the failing test", status: .completed),
        CodeToolTodo(id: 1, content: "Patch the reducer", status: .inProgress),
        CodeToolTodo(id: 2, content: "Run the Code gate", status: .pending),
    ]))
    .padding(CodePageTheme.rowMarginLeading)
}

#Preview("Tool output — diff") {
    CodeToolOutputView(output: .diff(CodeToolDiff(
        lines: [
            TimelineDiff.Line(id: 0, kind: .hunk, text: "@@ -1,3 +1,4 @@",
                              oldLine: nil, newLine: nil),
            TimelineDiff.Line(id: 1, kind: .context, text: "let a = 1",
                              oldLine: 1, newLine: 1),
            TimelineDiff.Line(id: 2, kind: .delete, text: "let b = 2",
                              oldLine: 2, newLine: nil),
            TimelineDiff.Line(id: 3, kind: .add, text: "let b = 3",
                              oldLine: nil, newLine: 2),
        ],
        added: 1,
        removed: 1,
        maxLineNumber: 3)))
    .padding(CodePageTheme.rowMarginLeading)
}

#Preview("Tool output — approved plan placeholder") {
    CodeToolOutputView(output: .approvedPlan)
        .padding(CodePageTheme.rowMarginLeading)
}

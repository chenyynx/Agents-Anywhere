import SwiftUI
import UIKit

// The Code page's message row: one persisted message = one row, with its
// reasoning / body / tool blocks stacked inside it
// (CANONICAL/01-architecture.md §2, 04-tool-calls.md §1).
//
// W7 wires the frozen Wave 1 model (`CodeMessageBuilder`) into the collection
// timeline. This view owns no grouping rule of its own: the group already
// carries exactly one message's rows, and the builder turns them into the
// block stack in declared RBT order. Every visual value comes from
// `CodePageTheme`; this file adds none of its own.

/// The adapter's paced snapshot for the row that is currently streaming.
///
/// The Code page has no per-character reveal; the publisher emits full-text
/// snapshots (W6). `rowID` is the wire row the text belongs to, so the view
/// substitutes the snapshot in exactly that text block instead of guessing
/// which block is live.
nonisolated struct CodeStreamingText: Equatable {
    let rowID: String
    let text: String
}

struct CodeMessageRowView: View {
    let group: ChatTimelineGroup
    let profile: CodeRuntimeProfile
    /// The session's working directory, used to shorten paths in tool labels.
    var cwd: String?
    /// The paced streaming snapshot while this message's body is still growing.
    var streaming: CodeStreamingText?
    /// A collapsed tool row's tap. Navigation belongs to the page: a sheet
    /// owned by this row would sit inside a hosting cell that every streaming
    /// reconfigure rebuilds, and could dismiss an open detail.
    var onToolDetail: (CodeToolDetailRequest) -> Void

    init(group: ChatTimelineGroup,
         profile: CodeRuntimeProfile,
         cwd: String? = nil,
         streaming: CodeStreamingText? = nil,
         onToolDetail: @escaping (CodeToolDetailRequest) -> Void = { _ in }) {
        self.group = group
        self.profile = profile
        self.cwd = cwd
        self.streaming = streaming
        self.onToolDetail = onToolDetail
    }

    var body: some View {
        let rows = renderRows
        VStack(alignment: .leading, spacing: CodePageTheme.blockSpacing) {
            ForEach(rows) { row in
                if row.role == .user {
                    userRow(row)
                } else {
                    blockStack(row)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One message's blocks in declared order; the assistant path.
    private func blockStack(_ row: RenderedRow) -> some View {
        VStack(alignment: .leading, spacing: CodePageTheme.segmentVerticalPadding) {
            ForEach(Array(row.blocks.enumerated()), id: \.offset) { _, block in
                blockView(block, statuses: row.statuses)
                    .padding(.vertical, CodePageTheme.segmentVerticalPadding)
            }
        }
    }

    /// A user message renders as one right-aligned bubble. AA publishes one
    /// message's body as several text rows, so every `.text` block joins in
    /// block order instead of stacking as separate paragraphs. A non-text
    /// block on a user row does not occur today; it keeps the generic path
    /// rather than being dropped.
    private func userRow(_ row: RenderedRow) -> some View {
        var texts: [String] = []
        var others: [CodeMessageRow.Block] = []
        for block in row.blocks {
            switch block {
            case let .text(id, text):
                let value = displayedText(id: id, fallback: text)
                if !value.isEmpty { texts.append(value) }
            default:
                others.append(block)
            }
        }
        return VStack(alignment: .leading, spacing: CodePageTheme.segmentVerticalPadding) {
            if !texts.isEmpty {
                CodeUserBubble(text: texts.joined(separator: "\n\n"))
                    .padding(.vertical, CodePageTheme.segmentVerticalPadding)
            }
            ForEach(Array(others.enumerated()), id: \.offset) { _, block in
                blockView(block, statuses: row.statuses)
                    .padding(.vertical, CodePageTheme.segmentVerticalPadding)
            }
        }
    }

    // MARK: - Blocks

    @ViewBuilder
    private func blockView(_ block: CodeMessageRow.Block,
                           statuses: [String: V2TimelineItemStatus]) -> some View {
        switch block {
        case let .reasoning(id, _):
            // The official `Block.thinking` is a status line, not a body
            // (CANONICAL/02-transcript-model.md §4.2 tag 3; task sheet §71).
            // It exists only while the row is working; a settled reasoning row
            // has no status to show. `renderRows` already dropped inactive
            // reasoning blocks, so reaching here means the status is active.
            if statuses[id]?.isActive == true {
                CodeThinkingStatusLine()
            } else {
                EmptyView()
            }

        case let .text(id, text):
            // First packet: the existing Markdown view. The Code page has no
            // reveal, so the text is always the settled full snapshot.
            ChatMarkdownView(text: displayedText(id: id, fallback: text),
                             isStreaming: false,
                             resolvesFileReferences: true)

        case let .toolCalls(segments):
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    toolRow(segment)
                }
            }

        case let .other(_, type):
            otherRow(type)
        }
    }

    private func toolRow(_ segment: CodeToolSegment) -> some View {
        let calls = CodeToolLabels.calls(in: segment)
        let label = CodeToolLabels.label(for: calls, cwd: cwd)
        return CodeCollapsedToolRow(verb: label.verb,
                                    target: label.target,
                                    // A settled row carries no leading glyph
                                    // in the official screenshot; a running
                                    // row shows its category icon
                                    // (CANONICAL/04-tool-calls.md §4.1/§7.3).
                                    icon: label.isRunning
                                        ? CodeToolLabels.icon(for: calls.first?.kind ?? .other)
                                        : nil,
                                    diff: label.diff,
                                    isRunning: label.isRunning) {
            if let request = CodeToolDetailRequest(calls: calls) { onToolDetail(request) }
        }
    }

    /// The generic row for a block the Code page has no dedicated view for.
    /// `codeGroups` never puts such a row into a message group today, but
    /// dropping the case would make the builder's `other` block render nothing.
    private func otherRow(_ type: String) -> some View {
        HStack(spacing: CodePageTheme.toolRowButtonPadding) {
            Image(systemName: "square.dashed")
                .font(.system(size: CodePageTheme.toolRowFontSize))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(verbatim: type)
                .font(.system(size: CodePageTheme.toolRowFontSize))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(minHeight: CodePageTheme.toolRowLineHeight, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Row projection

    /// One builder row plus the statuses of the blocks it kept. Computing this
    /// once per body keeps the status dictionary out of every block view.
    private struct RenderedRow: Identifiable {
        let id: String
        let role: V2MessageRole
        let blocks: [CodeMessageRow.Block]
        let statuses: [String: V2TimelineItemStatus]
    }

    /// Builder rows with inactive reasoning blocks removed. Reasoning text is
    /// not part of the Code transcript (the block is a status line), so a
    /// settled reasoning row contributes no height at all.
    private var renderRows: [RenderedRow] {
        let statuses = Dictionary(group.rows.map { ($0.id, $0.value.status) },
                                  uniquingKeysWith: { first, _ in first })
        return CodeMessageBuilder.rows(for: group.rows.map(\.value), profile: profile)
            .compactMap { row in
                let blocks = row.blocks.filter { block in
                    guard case let .reasoning(id, _) = block else { return true }
                    return statuses[id]?.isActive == true
                }
                guard !blocks.isEmpty else { return nil }
                return RenderedRow(id: row.id, role: row.role,
                                   blocks: blocks, statuses: statuses)
            }
    }

    private func displayedText(id: String, fallback: String) -> String {
        guard let streaming, streaming.rowID == id else { return fallback }
        return streaming.text
    }
}

// MARK: - Running status line

/// `••• Computing...` — the official working row
/// (CANONICAL/20-working-mark.md §1–§4): the 20×20 flipbook mark with the
/// `.connecting` verb table, rotated once a second. The mark is decorative and
/// hidden from accessibility; the verb text carries the announcement.
private struct CodeThinkingStatusLine: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        TimelineView(.periodic(from: .now,
                               by: CodePageTheme.runningStatusVerbRotationInterval)) { context in
            let second = max(0, Int(context.date.timeIntervalSinceReferenceDate))
            let verb = CodeWorkingStatusVerbs.all[second % CodeWorkingStatusVerbs.all.count]
            HStack(spacing: CodePageTheme.toolRowButtonPadding) {
                WorkingMarkView(body: .think, isRunning: true)
                Text(verbatim: verb + "...")
                    .font(.system(size: CodePageTheme.runningStatusFontSize))
                    .foregroundStyle(CodePageTheme.runningStatusColor.resolved(for: colorScheme))
            }
            .frame(minHeight: CodePageTheme.workingMarkSize, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(verbatim: verb + "..."))
        }
    }
}

/// The official `.connecting` working-status verbs: 20 entries rotated by
/// `timeIntervalSinceReferenceDate % 20`
/// (CANONICAL/20-working-mark.md §4; `EVIDENCE/round15/working-mark.json`).
nonisolated enum CodeWorkingStatusVerbs {
    static let all = ["Clauding", "Cogitating", "Computing", "Contemplating",
                      "Cooking", "Deliberating", "Generating", "Imagining",
                      "Musing", "Noodling", "Pondering", "Processing",
                      "Scheming", "Synthesizing", "Thinking", "Tinkering",
                      "Working", "Ruminating", "Percolating", "Brewing"]
}

// MARK: - Tool row labels

/// One collapsed tool row's text and decorations.
nonisolated struct CodeToolRowLabel {
    let verb: String
    let target: String?
    let diff: CodeDiffStat?
    let isRunning: Bool
}

/// Maps a segment's calls to the official collapsed-row label.
///
/// The official label comes from `ToolCall.toolInput` (verified-verb table,
/// CANONICAL/04-tool-calls.md §8) plus the input target, or from the server
/// summary for a span. AA's wire carries no `serverSummary`, so a multi-call
/// span composes its label from the calls' kinds and counts in first-seen
/// order — the shape the reference video shows ("Created a file, edited 2
/// files", REFERENCES/video-mining-r3.md 03:19–03:38). Single calls keep the
/// verb + target form from the official screenshot ("Edited
/// validate-email.ts").
nonisolated enum CodeToolLabels {
    static func calls(in segment: CodeToolSegment) -> [CodeToolCall] {
        switch segment {
        case let .span(calls): return calls
        case let .special(_, call): return [call]
        }
    }

    /// The label text alone, for the collection's height estimate.
    static func text(for segment: CodeToolSegment, cwd: String?) -> String {
        let label = label(for: calls(in: segment), cwd: cwd)
        return [label.verb, label.target].compactMap { $0 }.joined(separator: " ")
    }

    static func label(for calls: [CodeToolCall], cwd: String?) -> CodeToolRowLabel {
        let running = calls.contains { $0.status == .running }
        var added = 0
        var removed = 0
        var hasDiff = false
        for call in calls {
            guard let stat = diffStat(for: call.item) else { continue }
            added += stat.added
            removed += stat.removed
            hasDiff = true
        }
        let diff = hasDiff ? CodeDiffStat(added: added, removed: removed) : nil

        if calls.count == 1, let call = calls.first {
            let single = singleLabel(for: call, cwd: cwd)
            return CodeToolRowLabel(verb: single.verb, target: single.target,
                                    diff: diff, isRunning: running)
        }
        return CodeToolRowLabel(verb: spanSummary(for: calls), target: nil,
                                diff: diff, isRunning: running)
    }

    static func icon(for kind: CodeToolKind) -> String {
        switch kind {
        case .read: "eye"
        case .edit: "pencil"
        case .write: "doc"
        case .bash: "terminal"
        case .search: "magnifyingglass"
        case .todo: "checklist"
        case .task: "person.2"
        case .plan: "list.bullet.clipboard"
        case .question: "questionmark.bubble"
        case .mcp: "wrench.and.screwdriver"
        case .other: "wrench"
        }
    }

    // MARK: - Single call

    private static func singleLabel(for call: CodeToolCall,
                                    cwd: String?) -> (verb: String, target: String?) {
        let target = rawTarget(for: call, cwd: cwd)
        switch call.kind {
        case .read: return ("Read", target)
        case .edit: return ("Edited", target)
        // The official split (created vs. updated) needs `fileWriteKind`,
        // which AA's wire does not carry; "Created" is the observed case in
        // the reference video.
        case .write: return ("Created", target)
        case .bash: return ("Ran", target)
        case .search: return ("Searched", target)
        case .todo: return (todoIsEmpty(call) ? "Cleared todos" : "Updated todos", nil)
        case .task: return ("Ran agent", target)
        case .plan: return ("Proposed plan", target)
        case .question: return ("Asked", target)
        case .mcp, .other: return ("Used", target ?? call.name)
        }
    }

    /// The call's visible target: a shortened file path, the shell command, a
    /// search query, or the agent/tool name.
    private static func rawTarget(for call: CodeToolCall, cwd: String?) -> String? {
        let content = call.item.raw["content"] ?? .object([:])
        let input = content["input"] ?? content["arguments"]
        switch call.kind {
        case .read, .edit, .write:
            let path = TimelineText.first(input?["file_path"], input?["notebook_path"],
                                          input?["path"], content["path"],
                                          content["file_path"])
                ?? content["changes"]?.arrayValue?.first.flatMap { TimelineText.path($0) }
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

    private static func todoIsEmpty(_ call: CodeToolCall) -> Bool {
        let content = call.item.raw["content"] ?? .object([:])
        let todos = content["input"]?["todos"]?.arrayValue
            ?? content["arguments"]?["todos"]?.arrayValue
            ?? content["todos"]?.arrayValue
        return todos?.isEmpty == true
    }

    // MARK: - Span summary

    private static func spanSummary(for calls: [CodeToolCall]) -> String {
        var kinds: [CodeToolKind] = []
        var counts: [CodeToolKind: Int] = [:]
        for call in calls {
            if counts[call.kind] == nil { kinds.append(call.kind) }
            counts[call.kind, default: 0] += 1
        }
        return kinds.enumerated().map { index, kind in
            let phrase = phrase(for: kind, count: counts[kind] ?? 0)
            return index == 0 ? phrase : decapitalized(phrase)
        }.joined(separator: ", ")
    }

    private static func phrase(for kind: CodeToolKind, count: Int) -> String {
        switch kind {
        case .read: return "Read " + files(count)
        case .edit: return "Edited " + files(count)
        case .write: return "Created " + files(count)
        case .bash: return count == 1 ? "Ran a command" : "Ran \(count) commands"
        case .search: return count == 1 ? "Searched" : "Searched \(count) times"
        case .todo: return "Updated todos"
        case .task: return count == 1 ? "Ran an agent" : "Ran \(count) agents"
        case .plan: return "Proposed a plan"
        case .question: return "Asked a question"
        case .mcp, .other: return count == 1 ? "Used a tool" : "Used \(count) tools"
        }
    }

    private static func files(_ count: Int) -> String {
        count == 1 ? "a file" : "\(count) files"
    }

    /// "Read 2 files, edited 1 file": only the first phrase is capitalised,
    /// as in the reference video's span summary.
    private static func decapitalized(_ phrase: String) -> String {
        guard let first = phrase.first else { return phrase }
        return first.lowercased() + String(phrase.dropFirst())
    }

    // MARK: - Diff stat

    /// A collapsed row's badge, read straight from the wire's line counts.
    /// Parsing the whole diff here (W4's `CodeToolOutput`) would be heavy for
    /// a one-line decorative stat; a payload without counts shows no badge
    /// rather than guessing from the lines.
    private static func diffStat(for item: V2TimelineItem) -> CodeDiffStat? {
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
        guard added != nil || removed != nil else { return nil }
        let addedCount = max(0, added ?? 0)
        let removedCount = max(0, removed ?? 0)
        guard addedCount > 0 || removedCount > 0 else { return nil }
        return CodeDiffStat(added: addedCount, removed: removedCount)
    }
}

// MARK: - Sheet identity

/// One detail request: the tapped segment's first call plus its followers, in
/// official order (`ToolCallDetail{call, followingCalls}`). The row reports it
/// upward; `TimelineChatTimelineView` owns the sheet.
struct CodeToolDetailRequest: Identifiable {
    let id: String
    let call: CodeToolCall
    let following: [CodeToolCall]

    init?(calls: [CodeToolCall]) {
        guard let first = calls.first else { return nil }
        id = first.id
        call = first
        following = Array(calls.dropFirst())
    }
}

// MARK: - Previews

private func codeMessagePreviewItem(_ json: String) -> V2TimelineItem {
    guard let item = try? JSONDecoder().decode(V2TimelineItem.self, from: Data(json.utf8)) else {
        preconditionFailure("Invalid preview timeline item")
    }
    return item
}

private func codeMessagePreviewGroup(_ items: [V2TimelineItem]) -> ChatTimelineGroup {
    let rows = items.map { ChatTimelineRowModel($0) }
    return ChatTimelineGroup(kind: .single, rows: rows, explicitID: "preview-message")
}

private struct CodeMessageRowPreview: View {
    let items: [V2TimelineItem]
    let profile: CodeRuntimeProfile

    var body: some View {
        CodeMessageRowView(group: codeMessagePreviewGroup(items),
                           profile: profile,
                           cwd: nil)
            .padding(.horizontal, CodePageTheme.rowMarginLeading)
            .padding(.vertical, 12)
            .background(Color(.systemBackground))
    }
}

#Preview("Code message — reasoning, body, tool span") {
    CodeMessageRowPreview(items: [
        codeMessagePreviewItem(#"""
        {"id":"r1","sessionId":"s","type":"reasoning","status":"running","orderSeq":1,
         "content":{"kind":"reasoning","rawText":"Checking the package layout."},
         "source":{"itemId":"m1"}}
        """#),
        codeMessagePreviewItem(#"""
        {"id":"t1","sessionId":"s","type":"message","status":"done","role":"assistant","orderSeq":2,
         "content":{"text":"The package builds after two edits. `Package.swift` now pins 6.0."},
         "source":{"itemId":"m1"}}
        """#),
        codeMessagePreviewItem(#"""
        {"id":"c1","sessionId":"s","type":"tool","status":"done","orderSeq":3,
         "content":{"toolName":"Read","input":{"file_path":"Sources/App/Package.swift"},
                    "output":{"lineStat":{"addedLineCount":2,"removedLineCount":1}}},
         "source":{"nativeMessageId":"m1","blockIndex":0}}
        """#),
        codeMessagePreviewItem(#"""
        {"id":"c2","sessionId":"s","type":"tool","status":"done","orderSeq":4,
         "content":{"toolName":"Edit","input":{"file_path":"Sources/App/validate-email.ts"}},
         "source":{"nativeMessageId":"m1","blockIndex":1}}
        """#),
    ], profile: .claudeCode)
}

#Preview("Code message — body only") {
    CodeMessageRowPreview(items: [
        codeMessagePreviewItem(#"""
        {"id":"t2","sessionId":"s","type":"message","status":"done","role":"assistant","orderSeq":1,
         "content":{"text":"Done. `isValidEmail` trims the value before it tests it."},
         "source":{"itemId":"m2"}}
        """#),
    ], profile: .codex)
}

#Preview("Code message — user bubble") {
    // Two body rows of the same user message: the row joins them into one
    // bubble, in block order.
    CodeMessageRowPreview(items: [
        codeMessagePreviewItem(#"""
        {"id":"u1","sessionId":"s","type":"message","status":"done","role":"user","orderSeq":1,
         "content":{"text":"The email check should trim the value before it tests it."},
         "source":{"itemId":"m3"}}
        """#),
        codeMessagePreviewItem(#"""
        {"id":"u2","sessionId":"s","type":"message","status":"done","role":"user","orderSeq":2,
         "content":{"text":"Keep the existing error message."},
         "source":{"itemId":"m3"}}
        """#),
    ], profile: .claudeCode)
}

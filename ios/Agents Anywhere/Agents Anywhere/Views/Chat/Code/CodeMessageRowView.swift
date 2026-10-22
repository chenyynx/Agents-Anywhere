import Foundation
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
        // Official `rowMargins` top/bottom 5 pt
        // (CANONICAL/05-layout-scroll.md §3.1). The horizontal 16 pt comes
        // from the collection column's inset, which equals it on phones. The
        // list's own item gap is zeroed for these rows (adapter
        // `itemSpacing(after:)`), so this margin is the whole inter-row gap.
        .padding(.vertical, CodePageTheme.rowMarginTop)
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
struct CodeThinkingStatusLine: View {
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
/// The label's shape (verb, target, counts) is decided by the pure
/// `CodeToolLabelPlan` in the model layer; this enum only turns its semantic
/// verbs and counts into localized text. The official zh-Hans values come
/// from the app's `ccr_verb_*` / `ccr_summary_*` tables
/// (`EVIDENCE/resources-r6.md` §3.1-§3.3).
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
        guard let plan = CodeToolLabelPlan.make(calls: calls, cwd: cwd) else {
            return CodeToolRowLabel(verb: "", target: nil, diff: nil, isRunning: false)
        }
        if let verb = plan.verb {
            // The official row swaps to the present-participle while the call
            // runs (`ccr_running_*`), the way the German capture reads
            // "Web wird …"; a settled row keeps `ccr_verb_*`.
            let text = plan.isRunning ? runningVerbText(verb) : verbText(verb)
            return CodeToolRowLabel(verb: text,
                                    target: plan.target,
                                    diff: plan.diff,
                                    isRunning: plan.isRunning)
        }
        return CodeToolRowLabel(verb: phraseText(plan.phrases),
                                target: nil,
                                diff: plan.diff,
                                isRunning: plan.isRunning)
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

    // MARK: - Localized text

    private static let phraseSeparator = String(localized: "ccr_summary_separator")

    private static func verbText(_ verb: CodeToolLabelPlan.Verb) -> String {
        switch verb {
        case .read: return String(localized: "ccr_verb_read")
        case .edited: return String(localized: "ccr_verb_edited")
        // No `ccr_verb_*` entry exists for Write in the official tables; the
        // summary form is "Created a file", so the single verb stays "Created".
        case .created: return String(localized: "ccr_verb_created")
        case .ran: return String(localized: "ccr_verb_ran")
        case .searched: return String(localized: "ccr_verb_searched")
        case .searchedWeb: return String(localized: "ccr_verb_searched_web")
        case .fetched: return String(localized: "ccr_verb_fetched")
        case .clearedTodos: return String(localized: "ccr_verb_cleared_todos")
        case .updatedTodos: return String(localized: "ccr_verb_updated_todos")
        case .ranAgent: return String(localized: "ccr_verb_ran_agent")
        case .proposedPlan: return String(localized: "ccr_verb_proposed_plan")
        case .asked: return String(localized: "ccr_verb_asked")
        // The official MCP form is "Used %@"; the row keeps its two-run
        // (verb + target) shape, so the verb is the bare "Used".
        case .used: return String(localized: "ccr_verb_used")
        case .searchedCode: return String(localized: "ccr_summary_searched_code")
        case .foundFiles: return String(localized: "ccr_summary_found_files")
        case .browsedWeb: return String(localized: "ccr_summary_browsed_web")
        }
    }

    /// In-progress verbs, official `ccr_running_*` (`resources-r6.md` §3.1).
    /// A span summary has no running form in the official table, so only the
    /// single-call / shared-target shape uses these.
    private static func runningVerbText(_ verb: CodeToolLabelPlan.Verb) -> String {
        switch verb {
        case .read: return String(localized: "ccr_running_reading")
        case .edited: return String(localized: "ccr_running_editing")
        case .created: return String(localized: "ccr_running_creating")
        case .ran: return String(localized: "ccr_running_running")
        case .searched: return String(localized: "ccr_running_searching")
        case .searchedWeb: return String(localized: "ccr_running_searching_web")
        case .fetched: return String(localized: "ccr_running_fetching")
        case .clearedTodos, .updatedTodos:
            return String(localized: "ccr_running_updating_todos")
        case .ranAgent: return String(localized: "ccr_running_running_agent")
        case .proposedPlan: return String(localized: "ccr_running_proposing_plan")
        case .asked: return String(localized: "ccr_running_asking")
        case .used: return String(localized: "ccr_running_using")
        case .searchedCode, .foundFiles, .browsedWeb:
            return verbText(verb)
        }
    }

    /// "Read 2 files, edited 1 file": only the first phrase is capitalised in
    /// English, as in the reference video's span summary.
    private static func phraseText(_ phrases: [CodeToolLabelPlan.Phrase]) -> String {
        phrases.enumerated().map { index, phrase in
            let text = phraseText(phrase)
            return index == 0 ? text : decapitalized(text)
        }.joined(separator: phraseSeparator)
    }

    private static func phraseText(_ phrase: CodeToolLabelPlan.Phrase) -> String {
        switch (phrase.verb, phrase.unit) {
        case (.read, .files): return plural(.read, count: phrase.count)
        case (.edited, .files): return plural(.edit, count: phrase.count)
        case (.edited, .notebooks): return plural(.notebookEdit, count: phrase.count)
        case (.created, .files): return plural(.write, count: phrase.count)
        case (.ran, .commands): return plural(.bash, count: phrase.count)
        case (.ranAgent, .agents): return plural(.task, count: phrase.count)
        case (.searched, .times): return plural(.searchTimes, count: phrase.count)
        case (.used, .tools): return plural(.other, count: phrase.count)
        case (.searchedCode, _): return String(localized: "ccr_summary_searched_code")
        case (.foundFiles, _): return String(localized: "ccr_summary_found_files")
        case (.browsedWeb, _): return String(localized: "ccr_summary_browsed_web")
        case (.fetched, _): return String(localized: "ccr_verb_fetched")
        case (.clearedTodos, _): return String(localized: "ccr_verb_cleared_todos")
        case (.updatedTodos, _): return String(localized: "ccr_summary_updated_todos")
        case (.proposedPlan, _): return String(localized: "ccr_summary_proposed_plan")
        case (.asked, _): return String(localized: "ccr_verb_asked")
        default: return verbText(phrase.verb)
        }
    }

    private enum PluralKey {
        case read, edit, notebookEdit, write, bash, task, searchTimes, other
    }

    /// English plural forms are separate keys (`_one` / `_other`) because the
    /// official table is a stringsdict with "a file" / "%lld files"; Chinese
    /// has only the "other" form, so its `_one` value spells the count 1.
    private static func plural(_ key: PluralKey, count: Int) -> String {
        let format: String
        switch key {
        case .read:
            format = count == 1 ? String(localized: "ccr_summary_read_one")
                                : String(localized: "ccr_summary_read_other")
        case .edit:
            format = count == 1 ? String(localized: "ccr_summary_edit_one")
                                : String(localized: "ccr_summary_edit_other")
        case .notebookEdit:
            format = count == 1 ? String(localized: "ccr_summary_notebook_edit_one")
                                : String(localized: "ccr_summary_notebook_edit_other")
        case .write:
            format = count == 1 ? String(localized: "ccr_summary_write_one")
                                : String(localized: "ccr_summary_write_other")
        case .bash:
            format = count == 1 ? String(localized: "ccr_summary_bash_one")
                                : String(localized: "ccr_summary_bash_other")
        case .task:
            format = count == 1 ? String(localized: "ccr_summary_task_one")
                                : String(localized: "ccr_summary_task_other")
        case .searchTimes:
            format = count == 1 ? String(localized: "ccr_summary_search_times_one")
                                : String(localized: "ccr_summary_search_times_other")
        case .other:
            format = count == 1 ? String(localized: "ccr_summary_other_one")
                                : String(localized: "ccr_summary_other_other")
        }
        return String(format: format, count)
    }

    /// "Read 2 files, edited 1 file": only the first phrase is capitalised.
    private static func decapitalized(_ phrase: String) -> String {
        guard let first = phrase.first else { return phrase }
        return first.lowercased() + String(phrase.dropFirst())
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

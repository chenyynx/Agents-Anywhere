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

/// The adapter's published snapshots for the rows that are currently live.
///
/// The Code page has no per-character reveal; each publisher emits whole-text
/// snapshots on the official 0.1 s leading-edge throttle
/// (CANONICAL/03-streaming.md §5.1). Snapshots are keyed by the wire row id of
/// the block they belong to, so the view substitutes text in exactly that
/// block instead of guessing which row is live (several blocks of one message
/// may stream at the same time, P2-11).
nonisolated struct CodeStreamingText: Equatable {
    let textsByRowID: [String: String]

    init(rowID: String, text: String) {
        textsByRowID = [rowID: text]
    }

    init(textsByRowID: [String: String]) {
        self.textsByRowID = textsByRowID
    }

    func text(for rowID: String) -> String? { textsByRowID[rowID] }
}

struct CodeMessageRowView: View {
    let group: ChatTimelineGroup
    let profile: CodeRuntimeProfile
    /// The session's working directory, used to shorten paths in tool labels.
    var cwd: String?
    /// The paced streaming snapshot while this message's body is still growing.
    var streaming: CodeStreamingText?
    /// Pre-parsed Markdown snapshots, keyed by `ChatMarkdownPrepared.key(for:)`
    /// of the text the row will draw. The adapter supplies them so a freshly
    /// configured cell paints its body on the first frame instead of waiting
    /// for `ChatMarkdownView`'s async parse (and so the measurer can lay the
    /// real view out synchronously).
    var preparedBlocks: [String: [MarkdownBlockSnapshot]]?
    /// The adapter's typography snapshot. The text leaf measures and draws
    /// with it; production passes it so the leaf and
    /// `CodeMessageHeightMeasurer` use identical metrics.
    var typography: TimelineTypographySnapshot?
    /// The turn's copy text when this message group ends a finished turn.
    /// Non-nil draws the official turn action bar after the message.
    var turnActionCopyText: String?
    /// A collapsed tool row's tap. Navigation belongs to the page: a sheet
    /// owned by this row would sit inside a hosting cell that every streaming
    /// reconfigure rebuilds, and could dismiss an open detail.
    var onToolDetail: (CodeToolDetailRequest) -> Void
    /// A `思考过程` row's tap; same page-level presentation as a tool detail.
    var onThinkingDetail: (CodeThinkingDetailRequest) -> Void
    /// Turns the wire attachments of one `.attachments` block into the
    /// page's cached attachments. The page owns `ChatAttachmentStore` and the
    /// send correlation id, so the adapter passes its
    /// `resolve(contents, clientID:)` here; the default builds a cacheless
    /// attachment that still draws the official layout.
    var attachmentResolver: ([V2AttachmentContent], String?) -> [ChatMessageAttachment]
    /// One attachment's official display state. A settled message's wire
    /// attachment is complete; the pending row supplies its upload state.
    var attachmentState: (V2AttachmentContent) -> CodeAttachmentDisplayState
    /// Fetches one thumbnail when the cache has no preview bytes.
    var loadThumbnail: (V2AttachmentContent) async throws -> Data?
    /// A tap on an image tile or a successful file tile. The page owns the
    /// viewer/QuickLook routing.
    var onAttachment: (V2AttachmentContent, UIImage?) -> Void

    init(group: ChatTimelineGroup,
         profile: CodeRuntimeProfile,
         cwd: String? = nil,
         streaming: CodeStreamingText? = nil,
         preparedBlocks: [String: [MarkdownBlockSnapshot]]? = nil,
         typography: TimelineTypographySnapshot? = nil,
         turnActionCopyText: String? = nil,
         onToolDetail: @escaping (CodeToolDetailRequest) -> Void = { _ in },
         onThinkingDetail: @escaping (CodeThinkingDetailRequest) -> Void = { _ in },
         attachmentResolver: @escaping ([V2AttachmentContent], String?) -> [ChatMessageAttachment] = { contents, _ in
             contents.enumerated().map { index, content in
                 // The index keeps the identity unique inside the block; the
                 // page's resolver supplies the store's file-id-based id.
                 ChatMessageAttachment(id: content.fileId ?? "attachment:\(index)",
                                       content: content,
                                       previewData: nil,
                                       previewPixelSize: nil,
                                       previewVersion: 0)
             }
         },
         attachmentState: @escaping (V2AttachmentContent) -> CodeAttachmentDisplayState = { _ in .complete },
         loadThumbnail: @escaping (V2AttachmentContent) async throws -> Data? = { _ in nil },
         onAttachment: @escaping (V2AttachmentContent, UIImage?) -> Void = { _, _ in }) {
        self.group = group
        self.profile = profile
        self.cwd = cwd
        self.streaming = streaming
        self.preparedBlocks = preparedBlocks
        self.typography = typography
        self.turnActionCopyText = turnActionCopyText
        self.onToolDetail = onToolDetail
        self.onThinkingDetail = onThinkingDetail
        self.attachmentResolver = attachmentResolver
        self.attachmentState = attachmentState
        self.loadThumbnail = loadThumbnail
        self.onAttachment = onAttachment
    }

    var body: some View {
        let rows = renderRows
        Group {
            if rows.isEmpty {
                // A message whose only blocks are reasoning contributes no
                // height at all; the turn's working status is its own row.
                // The turn action bar is still the turn's final row, so it
                // renders even when the last message drew no blocks.
                if let turnActionCopyText {
                    CodeTurnActionBar(copyText: turnActionCopyText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, CodePageTheme.rowMarginTop)
                } else {
                    Color.clear.frame(height: 0)
                }
            } else {
                // Official stacks a message's blocks with `interBlockSpacing`
                // (nil → SwiftUI default; carried here as `blockGap`). Two
                // messages in one cell keep the pair of 5 pt row margins, so
                // their gap is `interMessageSpacing` (10 pt), not the 16 pt
                // Markdown-internal block spacing
                // (EVIDENCE/round19/bubble-layout.md:84-85).
                VStack(alignment: .leading, spacing: CodePageTheme.interMessageSpacing) {
                    ForEach(rows) { row in
                        if row.role == .user {
                            userRow(row)
                        } else {
                            blockStack(row)
                        }
                    }
                    if let turnActionCopyText {
                        CodeTurnActionBar(copyText: turnActionCopyText)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // Official `rowMargins` top/bottom 5 pt
                // (CANONICAL/05-layout-scroll.md §3.1). The horizontal 16 pt
                // comes from the collection column's inset, which equals it on
                // phones. The list's own item gap is zeroed for these rows
                // (adapter `itemSpacing(after:)`), so this margin is the whole
                // inter-row gap.
                .padding(.vertical, CodePageTheme.rowMarginTop)
            }
        }
    }

    /// One message's blocks in declared order; the assistant path. Official
    /// puts no padding around a text or collapsed-tool block: the text body is
    /// a bare `RichMarkdownView` (EVIDENCE/round19/bubble-layout.md:90), the
    /// tool row carries its own button padding, and `segmentVerticalPadding`
    /// reaches only a few special tool segment kinds
    /// (EVIDENCE/round19/bubble-layout.md:89). The only separator is the
    /// inter-block gap.
    private func blockStack(_ row: RenderedRow) -> some View {
        VStack(alignment: .leading, spacing: CodePageTheme.blockGap) {
            ForEach(Array(row.blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
    }

    /// A user message renders its attachments first, then one right-aligned
    /// text bubble (device screenshots 2026-10-27). AA publishes one
    /// message's body as several text rows, so every `.text` block joins in
    /// block order instead of stacking as separate paragraphs. Today the
    /// non-text block is only `.attachments`, which the official page draws
    /// outside the bubble as a sibling block above it. A message with no text
    /// draws no bubble at all, so a pure-attachment message is only its
    /// attachments.
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
        return VStack(alignment: .leading, spacing: CodePageTheme.blockGap) {
            // The official row puts the attachment grids above the text
            // bubble (device screenshots 2026-10-27).
            ForEach(Array(others.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
            if !texts.isEmpty {
                // The bubble owns its 12 pt vertical padding; the cell adds
                // none and only stacks the attachment/other blocks beside it.
                CodeUserBubble(text: texts.joined(separator: "\n\n"))
            }
        }
        // Keep the card's shadow inside the hosting cell: its right edge
        // otherwise coincides with the cell's trailing edge and the shadow is
        // clipped there while the left/top/bottom shadows draw.
        .padding(.trailing, CodePageTheme.userRowShadowInset)
    }

    // MARK: - Blocks

    @ViewBuilder
    private func blockView(_ block: CodeMessageRow.Block) -> some View {
        switch block {
        case let .reasoning(id, text, status):
            if status == .done {
                CodeThinkingRow {
                    onThinkingDetail(CodeThinkingDetailRequest(id: id, text: text))
                }
            }

        case let .text(id, text):
            // The official Code page draws a text block through a
            // `UIViewRepresentable` whose synchronous `sizeThatFits` measures
            // the TextKit document (`EVIDENCE/UPSTREAM/part-aa-markdown-ui.md:149`).
            // The leaf draws and measures with the same engine as
            // `CodeMessageHeightMeasurer`, so the first fit already carries
            // the real body and no settled row corrects itself. The Code page
            // has no reveal; the text is always the settled full snapshot.
            CodeMarkdownTextLeaf(text: displayedText(id: id, fallback: text),
                                 typography: typography)

        case let .toolCalls(segments):
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    toolRow(segment)
                }
            }

        case let .other(_, type):
            otherRow(type)

        case let .attachments(_, files, clientMessageID):
            // The official user row draws attachments outside the text bubble
            // (CLOSURE.md §4): the image grid, then the file row. The resolver
            // lets the page attach cached previews through the client send id.
            CodeAttachmentRow(files: attachmentResolver(files, clientMessageID),
                              state: attachmentState,
                              onAttachment: onAttachment,
                              loadThumbnail: loadThumbnail)
        }
    }

    private func toolRow(_ segment: CodeToolSegment) -> some View {
        let calls = CodeToolLabels.calls(in: segment)
        let label = CodeToolLabels.label(for: calls, cwd: cwd)
        return CodeCollapsedToolRow(label: label,
                                    // A settled row carries no leading glyph
                                    // in the official screenshot; a running
                                    // row shows its category icon
                                    // (CANONICAL/04-tool-calls.md §4.1/§7.3).
                                    icon: label.isRunning
                                        ? CodeToolLabels.anthropicon(for: calls.first?.kind ?? .other)
                                        : nil) {
            if let request = CodeToolDetailRequest(calls: calls) { onToolDetail(request) }
        }
    }

    /// The generic row for a block the Code page has no dedicated view for.
    /// `codeGroups` never puts such a row into a message group today, but
    /// dropping the case would make the builder's `other` block render nothing.
    private func otherRow(_ type: String) -> some View {
        HStack(spacing: CodePageTheme.toolRowSpacing) {
            AnthropiconView(name: "anthropicon.tool", size: .medium)
                .foregroundStyle(.secondary)
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

    /// One builder row ready for the stack. A settled thinking block is a
    /// real row (`思考过程`); a running one is still the turn-level working
    /// line's job and stays out of the transcript.
    private struct RenderedRow: Identifiable {
        let id: String
        let role: V2MessageRole
        let blocks: [CodeMessageRow.Block]
    }

    private var renderRows: [RenderedRow] {
        CodeMessageBuilder.rows(for: group.rows.map(\.value), profile: profile)
            .compactMap { row in
                let blocks = row.blocks.filter { block in
                    switch block {
                    case let .reasoning(_, text, status):
                        return status == .done
                            && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    case let .text(_, text):
                        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    case .toolCalls, .other, .attachments:
                        return true
                    }
                }
                guard !blocks.isEmpty else { return nil }
                return RenderedRow(id: row.id, role: row.role, blocks: blocks)
            }
    }

    private func displayedText(id: String, fallback: String) -> String {
        streaming?.text(for: id) ?? fallback
    }
}

// MARK: - Running status line

/// `••• Computing...` — the official working row
/// (`CANONICAL/20-working-mark.md` §1–§4): the 20×20 flipbook mark plus the
/// status text. Normal work rotates the 20 verbs with the official phase
/// timing (0–3 s, 3–7 s, then every 6 s — `0x102a85174`); `compacting` and
/// `connecting` are fixed localised strings. The mark is decorative and
/// hidden from accessibility; the text carries the announcement.
struct CodeThinkingStatusLine: View {
    /// Mirrors `WorkingMarkView.isRunning`: false starts the mark's 0.4 s exit
    /// while the status text stays on screen until the parent removes the row
    /// (`EVIDENCE/round19/streaming.md:188`). The text is not part of the
    /// official exit group, which animates only the mark layer
    /// (`CANONICAL/20-working-mark.md:53`).
    let isRunning: Bool
    /// The official live-turn pose (`SessionDisplay.liveTurnMark`), chosen by
    /// `CodeWorkingMarkPose`.
    let markBody: WorkingMarkBody
    /// What the row is reporting; the adapter recomputes it as the turn's
    /// events change.
    let phase: CodeWorkingStatusPhase
    @Environment(\.colorScheme) private var colorScheme

    init(isRunning: Bool = true,
         markBody: WorkingMarkBody = .think,
         phase: CodeWorkingStatusPhase = .working(startedAt: Date())) {
        self.isRunning = isRunning
        self.markBody = markBody
        self.phase = phase
    }

    var body: some View {
        HStack(spacing: CodePageTheme.workingStatusSpacing) {
            WorkingMarkView(body: markBody, isRunning: isRunning)
            switch phase {
            case .connecting:
                statusLabel(String(localized: "正在连接"))
            case .compacting:
                statusLabel(String(localized: "正在压缩对话…"))
            case let .working(startedAt):
                // The 1 s tick only lets the phase boundary land on time; the
                // text changes at 0 / 3 / 7 / 13 … seconds, not every tick.
                statusTimeline { date in
                    CodeWorkingStatusText.verb(elapsed: date.timeIntervalSince(startedAt)) + "..."
                }
            case let .thinking(startedAt):
                // Official live tiers are refreshed by the same 1 Hz
                // `PeriodicTimelineSchedule` (`0x102a83314` in
                // CodeThinkingView's body).
                statusTimeline { date in
                    CodeThinkingText.liveText(elapsed: date.timeIntervalSince(startedAt))
                }
            case let .thoughtFor(seconds, endedAt, fallbackStartedAt):
                // `思考了 X` is visible for 2 s after the block ends; past
                // that the official selector returns nil and the working row
                // falls back to the rotating verbs (`0x102a88f20-f50`).
                statusTimeline { date in
                    if date < endedAt.addingTimeInterval(CodeThinkingText.closedWindow) {
                        return CodeThinkingText.closedText(seconds: seconds)
                    }
                    return CodeWorkingStatusText.verb(
                        elapsed: date.timeIntervalSince(fallbackStartedAt)) + "..."
                }
            }
        }
        .frame(minHeight: CodePageTheme.workingMarkSize, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    /// The official thinking row re-renders on a 1 Hz timeline; every
    /// time-derived label goes through this one tick so the phase boundary and
    /// the 2 s closed window land on the same cadence.
    private func statusTimeline(_ text: @escaping (Date) -> String) -> some View {
        TimelineView(.periodic(from: .now,
                               by: CodePageTheme.runningStatusVerbRotationInterval)) { context in
            statusLabel(text(context.date))
        }
    }

    private func statusLabel(_ text: String) -> some View {
        Text(verbatim: text)
            // [E] 15 pt / 400; the official family is the ambient
            // Typography's (R19 tool-row-status.md). AA uses the official
            // proportional face; the text style is [U].
            .font(.custom(CodePageTheme.sansFontName,
                          size: CodePageTheme.runningStatusFontSize,
                          relativeTo: .footnote))
            .foregroundStyle(CodePageTheme.runningStatusColor.resolved(for: colorScheme))
            // One line at every Dynamic Type size; a wrapped verb would
            // change the row height every second.
            .lineLimit(1)
            .truncationMode(.tail)
    }
}

// MARK: - Tool row labels

/// One summary phrase of a multi-target span. The failed/total pair is the
/// official per-category dictionary count (`0x10288e3c0`), which decides
/// between the written suffix and the colour-only failure signal.
nonisolated struct CodeToolPhraseLabel: Hashable {
    let text: String
    let failed: Int
    let total: Int
}

/// One collapsed tool row's text and decorations.
nonisolated struct CodeToolRowLabel {
    let verb: String
    let target: String?
    let diff: CodeDiffStat?
    let isRunning: Bool
    /// Failed calls in the single-target shape; 0 when none.
    let failed: Int
    /// Calls in the single-target shape.
    let total: Int
    /// The multi-target summary phrases in official order. Empty on the
    /// single-target path.
    let phrases: [CodeToolPhraseLabel]

    init(verb: String,
         target: String? = nil,
         diff: CodeDiffStat? = nil,
         isRunning: Bool,
         failed: Int = 0,
         total: Int = 0,
         phrases: [CodeToolPhraseLabel] = []) {
        self.verb = verb
        self.target = target
        self.diff = diff
        self.isRunning = isRunning
        self.failed = failed
        self.total = total
        self.phrases = phrases
    }
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

    static func label(for calls: [CodeToolCall], cwd: String?) -> CodeToolRowLabel {
        guard let plan = CodeToolLabelPlan.make(calls: calls, cwd: cwd) else {
            return CodeToolRowLabel(verb: "", isRunning: false)
        }
        if let verb = plan.verb {
            // The official row swaps to the present-participle while the call
            // runs (`ccr_running_*`), the way the German capture reads
            // "Web wird …"; a settled row keeps `ccr_verb_*`.
            let text = plan.isRunning ? runningVerbText(verb) : verbText(verb)
            return CodeToolRowLabel(verb: text,
                                    target: plan.target,
                                    diff: plan.diff,
                                    isRunning: plan.isRunning,
                                    failed: plan.failed,
                                    total: plan.total)
        }
        return CodeToolRowLabel(verb: phraseText(plan.phrases),
                                target: nil,
                                diff: plan.diff,
                                isRunning: plan.isRunning,
                                failed: plan.failed,
                                total: plan.total,
                                phrases: plan.phrases.enumerated().map { index, phrase in
                                    let text = phraseText(phrase)
                                    return CodeToolPhraseLabel(
                                        text: index == 0 ? text : decapitalized(text),
                                        failed: phrase.failed,
                                        total: phrase.count)
                                })
    }

    /// The official failed suffix (`ccr_summary_failed_count`, plural
    /// `(%lld failed)` / `（%lld 项失败）`). The view appends it to a phrase or
    /// to the single-target label; the English value carries the separating
    /// space, the zh-Hans value is the full-width bracket form.
    static func failedSuffix(_ failed: Int, locale: Locale = .autoupdatingCurrent) -> String {
        let format = String(localized: "(%lld failed)", locale: locale)
        return String(format: format, failed)
    }

    /// Official `category → Anthropicon` mapping
    /// (`CANONICAL/04-tool-calls.md` §7.2; AskUserQuestion / MCP / unknown
    /// fall into `other → tool`).
    static func anthropicon(for kind: CodeToolKind) -> String {
        switch kind {
        case .read: "anthropicon.eye"
        case .edit: "anthropicon.edit"
        case .write: "anthropicon.file"
        case .bash: "anthropicon.prompt"
        case .search: "anthropicon.search"
        case .todo: "anthropicon.checklist"
        case .task: "anthropicon.tasks"
        case .plan: "anthropicon.checklist"
        case .question, .mcp, .other: "anthropicon.tool"
        }
    }

    // MARK: - Localized text

    static let phraseSeparator = String(localized: "ccr_summary_separator")

    private static func verbText(_ verb: CodeToolLabelPlan.Verb) -> String {
        switch verb {
        case .read: return String(localized: "ccr_verb_read")
        case .edited: return String(localized: "ccr_verb_edited")
        // No `ccr_verb_*` entry exists for Write in the official tables; the
        // summary form is "Created a file", so the single verb stays "Created".
        case .created: return String(localized: "ccr_verb_created")
        // Official `ccr_write_updated` (updated file write).
        case .updated: return String(localized: "ccr_write_updated")
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
        // Official update-write running form (`ccr_running_editing`).
        case .updated: return String(localized: "ccr_running_editing")
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

/// One thinking-block detail request. The row carries the merged text of its
/// message's thinking run; the page owns the sheet.
struct CodeThinkingDetailRequest: Identifiable {
    let id: String
    let text: String
}

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

/// The one sheet the Code page owns. A single `.sheet(item:)` serves both
/// detail kinds; two modifiers on the same view would shadow each other.
enum CodePageDetailRequest: Identifiable {
    case tool(CodeToolDetailRequest)
    case thinking(CodeThinkingDetailRequest)

    var id: String {
        switch self {
        case let .tool(request): return "tool:\(request.id)"
        case let .thinking(request): return "thinking:\(request.id)"
        }
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

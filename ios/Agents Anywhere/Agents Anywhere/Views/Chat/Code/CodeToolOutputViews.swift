import SwiftUI
import UIKit

// The Code page's five tool-output renderers (`CANONICAL/04-tool-calls.md`
// §5.2). The five-case model and its wire parser live in
// `Models/Chat/Code/CodeToolOutput.swift` (ClientCore, no SwiftUI); this file
// only switches on the parsed result and draws it.
//
// Visual constants the shared theme does not carry yet live in
// `CodeToolCardMetrics` at the bottom of this file. Every one is tagged
// `[E]` / `[I]` / `[U]` with its source (`docs/code-page-visual-evidence.md`
// V-numbers, or the CANONICAL section) so they can be folded into
// `CodePageTheme` once the detail page's visual gate is closed.

// MARK: - Output switcher

struct CodeToolOutputView: View {
    let output: CodeToolOutput
    var kind: CodeToolKind = .other

    var body: some View {
        switch output {
        case let .text(text):
            // Read output is a whole file, not a code snippet. The generic
            // horizontal code card stops drawing its glyphs on a long
            // multi-line body (device report 2026-10-25: 24K/298-line Read
            // rendered a blank card). The official page has a dedicated
            // `FileReadDetailView`; this is its text branch: a vertical,
            // wrapping monospaced reader with the same card chrome.
            if kind == .read {
                CodeFileReadOutputView(text: text)
            } else {
                CodeToolCodeCard(title: String(localized: "Output"), code: text)
            }
        case let .todos(todos):
            CodeToolTodosOutputView(todos: todos)
        case let .diff(diff):
            CodeToolDiffOutputView(diff: diff)
        case let .submittedAnswers(answers):
            CodeToolSubmittedAnswersOutputView(answers: answers)
        case .approvedPlan:
            CodeToolApprovedPlanOutputView()
        case .none:
            // The detail page hides its output section entirely for `.none`;
            // a bare switch still needs a branch.
            EmptyView()
        }
    }
}

// MARK: - Read output (official `FileReadDetailView` text branch)

/// A whole-file Read result. The official detail page renders Read through
/// `FileReadDetailView`/`CodeBlockContent`, not the generic horizontal code
/// card; the body is a vertical, wrapping monospaced text so a 20K+ line
/// document cannot fall out of the code card's fixed-size text path.
private struct CodeFileReadOutputView: View {
    let text: String

    @State private var displayText: String
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale
    @ScaledMetric(relativeTo: .footnote) private var codeFontSize =
        CodeToolCardMetrics.codeFontSize
    @ScaledMetric(relativeTo: .caption) private var titleFontSize =
        CodeToolCardMetrics.titleFontSize
    @ScaledMetric(relativeTo: .caption) private var headerHeight =
        CodeToolCardMetrics.headerHeight

    init(text: String) {
        self.text = text
        _displayText = State(initialValue: String(text.prefix(CodeToolCardMetrics.previewLimit)))
    }

    private var surface: Color {
        CodeToolCardMetrics.surface.resolved(for: colorScheme)
    }

    private var border: Color {
        CodeToolCardMetrics.border.resolved(for: colorScheme)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(String(localized: "Output"))
                    .font(.system(size: titleFontSize,
                                  weight: .regular,
                                  design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(minHeight: CodeToolCardMetrics.titleLineHeight)
                    .lineLimit(1)
                Spacer(minLength: 8)
                CodeToolCopyButton(text: { text },
                                   label: String(localized: "复制代码"),
                                   size: 44)
            }
            .padding(.horizontal, CodeToolCardMetrics.headerHorizontalPadding)
            .frame(height: headerHeight)

            Rectangle()
                .fill(border)
                .frame(height: 1 / displayScale)

            Text(verbatim: displayText)
                .font(.system(size: codeFontSize, design: .monospaced))
                .lineSpacing(CodeToolCardMetrics.codeLineSpacing)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(CodeToolCardMetrics.contentInset)

            if text.count > CodeToolCardMetrics.previewLimit {
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
}

// MARK: - Text output (official `CodeBlockContent`)

/// The official code-card chrome: 44 pt base header (scaled with Dynamic
/// Type), 13/20.8 mono title, 24 pt continuous corners, 16 pt content inset,
/// 1 physical-pixel border and
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

    /// Cached at init and refreshed only when `code` changes, so a body
    /// re-evaluation never re-slices a 200 000-character string.
    @State private var displayCode: String
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale
    @ScaledMetric(relativeTo: .footnote) private var codeFontSize =
        CodeToolCardMetrics.codeFontSize
    @ScaledMetric(relativeTo: .caption) private var titleFontSize =
        CodeToolCardMetrics.titleFontSize
    @ScaledMetric(relativeTo: .caption) private var headerHeight =
        CodeToolCardMetrics.headerHeight

    init(title: String, code: String) {
        self.title = title
        self.code = code
        _displayCode = State(initialValue: String(code.prefix(CodeToolCardMetrics.previewLimit)))
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
            if code.count > CodeToolCardMetrics.previewLimit {
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
        .onChange(of: code) { _, newCode in
            displayCode = String(newCode.prefix(CodeToolCardMetrics.previewLimit))
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
        .frame(height: headerHeight)
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
            CodeToolSectionHeader(title: String(localized: "Todos"),
                                  copyText: todos.isEmpty ? nil : copyText)
            if todos.isEmpty {
                // An explicit empty TodoWrite list is the official cleared
                // state, not "no data" (`ccr_verb_cleared_todos`).
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle")
                        .accessibilityHidden(true)
                    Text(String(localized: "已清空待办"))
                }
                .font(.system(size: todoFontSize))
                .foregroundStyle(.secondary)
                .frame(minHeight: 24)
                .accessibilityElement(children: .combine)
            } else {
                VStack(alignment: .leading, spacing: CodeToolCardMetrics.todoRowSpacing) {
                    ForEach(todos) { todo in
                        row(todo)
                    }
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
    @ScaledMetric(relativeTo: .caption) private var headerHeight =
        CodeToolCardMetrics.headerHeight

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
                    .foregroundStyle(CodeToolCardMetrics.diffStatAdd.resolved(for: colorScheme))
            }
            if diff.removed > 0 {
                Text(verbatim: "−\(diff.removed)")
                    .font(.system(size: diffStatFontSize,
                                  design: .monospaced))
                    .foregroundStyle(CodeToolCardMetrics.diffStatRemove.resolved(for: colorScheme))
            }
            Spacer(minLength: 8)
            CodeToolCopyButton(text: { diff.unifiedText },
                               label: String(localized: "复制 Diff"),
                               size: 44)
        }
        .padding(.horizontal, CodeToolCardMetrics.headerHorizontalPadding)
        .frame(height: headerHeight)
    }

    private var loadMore: some View {
        Button {
            visibleCount = min(visibleCount + CodeToolCardMetrics.diffPageSize,
                               diff.lines.count)
        } label: {
            Text(String(localized: "Expand"))
                .font(.footnote.weight(.medium))
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
                    // One monospace advance, not a fixed 8 pt: the 15 pt `+`
                    // is ~9.3 pt wide, so an 8 pt column let the glyph spill
                    // over the code text.
                    .frame(width: signWidth, alignment: .leading)
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
            // [E] `DiffLineView.Body` ends in `_BackgroundStyleModifier<Color>`
            // (swift_types.csv:81326): the official added/removed row keeps the
            // whole-row fill *and* the 2 pt bar. The official capture measures
            // the fill at the add/remove colour × ≈0.125 over the card surface
            // (#E0F1DE for add on white); the same fraction is applied to both
            // kinds and to dark mode (no dark capture; [I]).
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

    /// One monospace advance at the scaled diff size (SF Mono ≈0.6 em).
    private var signWidth: CGFloat {
        max(8, diffFontSize * CodeToolCardMetrics.diffGutterDigitRatio)
    }

    /// The official whole-row fill: the add/remove colour at the measured
    /// ≈0.125 fraction (`#E0F1DE` for add on white). `barColor` already
    /// resolves the canonical light/dark palette.
    private func fill(_ kind: TimelineDiff.Line.Kind) -> Color {
        barColor(kind)?.opacity(0.125) ?? .clear
    }

    private func barColor(_ kind: TimelineDiff.Line.Kind) -> Color? {
        switch kind {
        case .add: return CodePageTheme.diffLineAdd.resolved(for: colorScheme)
        case .delete: return CodePageTheme.diffLineRemove.resolved(for: colorScheme)
        default: return nil
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
    @State private var copyCount = 0

    var body: some View {
        Button {
            UIPasteboard.general.string = text()
            copied = true
            copyCount += 1
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: size >= 44 ? 15 : 13, weight: .medium))
                .foregroundStyle(copied ? Color.green : Color.secondary)
                .frame(width: size, height: size)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // [E] The official copy control is an `AnimatingHapticButton` fired
        // with `.selection` (EVIDENCE/round19/motion.md §P2-8); AA used a
        // success notification, which is a different pattern.
        .sensoryFeedback(.selection, trigger: copyCount)
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

    /// [E] V61 / CANONICAL/06-visuals-assets.md §3.3 — header height 44 pt
    /// base; both card views scale it with `@ScaledMetric`.
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

    /// [E] V63 — monospaced body 15 pt; the 24 pt line height is realised as
    /// the derived `codeLineSpacing` below, so no separate unused token stays.
    static let codeFontSize: CGFloat = 15

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

    /// [I] V79 — diff stat green `#10AC0D` and red `#B4263E`. There is no dark
    /// capture, so the sampled light values are reused until one lands.
    static let diffStatAdd = CodePageTheme.SchemeColor(
        light: Color(.sRGB, red: 16.0 / 255.0,
                    green: 172.0 / 255.0,
                    blue: 13.0 / 255.0),
        dark: Color(.sRGB, red: 16.0 / 255.0,
                    green: 172.0 / 255.0,
                    blue: 13.0 / 255.0))
    static let diffStatRemove = CodePageTheme.SchemeColor(
        light: Color(.sRGB, red: 180.0 / 255.0,
                    green: 38.0 / 255.0,
                    blue: 62.0 / 255.0),
        dark: Color(.sRGB, red: 180.0 / 255.0,
                    green: 38.0 / 255.0,
                    blue: 62.0 / 255.0))

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

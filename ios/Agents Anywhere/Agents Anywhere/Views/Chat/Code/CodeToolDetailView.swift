import SwiftUI
import UIKit
import Foundation

// The Code page's tool detail (`CANONICAL/04-tool-calls.md` §4.2).
//
// Official structure (round26 §6, round28 §10): a collapsed row's tap opens a
// sheet whose `NavigationStack` roots at `collapsedToolCalls` — the span's
// summary title plus one row per call. A row in that list **pushes** the
// single-call page, which carries the input and the five-case output. The two
// layers are distinct; the single-call page never flattens the span's other
// calls into a "following calls" section.
//
// This file owns both pages:
// - `CodeToolGroupDetailView` (the sheet root, `NavigationStack` + list);
// - `CodeToolCallDetailView` (the pushed single-call page, no stack of its
//   own);
// - `CodeToolDetailView` (a convenience wrapper that roots the single-call
//   page in its own `NavigationStack`, used by previews and the gate).
//
// Detail-page-only visual values live in `CodeToolDetailMetrics` below, each
// tagged with its source. Shared values come from `CodePageTheme`.

/// The sheet-root group page: the span summary plus its call list. Tapping a
/// row pushes `CodeToolCallDetailView`.
struct CodeToolGroupDetailView: View {
    let calls: [CodeToolCall]
    /// Settled thinking text that belongs to the group; the official group
    /// screenshot places it above the call list.
    let thinkingText: String?
    let cwd: String?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityDifferentiateWithoutColor)
    private var differentiateWithoutColor

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: CodePageTheme.blockSpacing) {
                    if let thinkingText, !thinkingText.isEmpty {
                        ChatMarkdownView(text: thinkingText,
                                         isStreaming: false,
                                         resolvesFileReferences: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    LazyVStack(spacing: 0) {
                        ForEach(calls) { call in
                            NavigationLink {
                                CodeToolCallDetailView(call: call)
                            } label: {
                                CodeToolGroupCallRow(
                                    call: call,
                                    cwd: cwd,
                                    differentiateWithoutColor: differentiateWithoutColor)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, CodeToolDetailMetrics.contentInset)
                .padding(.vertical, CodeToolDetailMetrics.verticalInset)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background {
                CodeToolDetailMetrics.pageBackground
                    .resolved(for: colorScheme)
                    .ignoresSafeArea()
            }
            .navigationTitle(Text(verbatim: title))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(CodeToolDetailMetrics.pageBackground.resolved(for: colorScheme),
                               for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                SheetCloseToolbar { dismiss() }
            }
        }
    }

    /// The group title is the same summary the collapsed row shows, e.g.
    /// "编辑了 2 个文件" / "已编辑 Main.dc.html".
    private var title: String {
        let label = CodeToolLabels.label(for: calls, cwd: cwd)
        return CodeToolLabels.visibleText(
            for: label, differentiateWithoutColor: differentiateWithoutColor)
    }
}

/// One call row inside the group list: category icon + single-call label +
/// caret. The official `ToolCallRunRow` typography/colours are the D9 hook;
/// 15 pt text is the one decoded Code text preset.
struct CodeToolGroupCallRow: View {
    let call: CodeToolCall
    let cwd: String?
    let differentiateWithoutColor: Bool

    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric(relativeTo: CodeDetailRowHooks.textStyle)
    private var textLineHeight = CodePageTheme.toolRowTextLineHeight

    var body: some View {
        let label = CodeToolLabels.label(for: [call], cwd: cwd)
        let runs = CodeToolLabels.runs(
            for: label, differentiateWithoutColor: differentiateWithoutColor)
        HStack(alignment: .center, spacing: CodeDetailRowHooks.iconSpacing) {
            AnthropiconView(name: CodeToolLabels.anthropicon(for: call),
                            size: .large)
                .foregroundStyle(CodePageTheme.text500Color
                    .resolved(for: colorScheme))
                .frame(width: CodePageTheme.toolRowIconFrameSize,
                       height: CodePageTheme.toolRowIconFrameSize)
                .accessibilityHidden(true)

            CodeToolLabelText(runs: runs)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(minHeight: textLineHeight, alignment: .leading)
                .layoutPriority(1)

            Spacer(minLength: 0)
            CodeRowCaret()
        }
        .padding(.vertical, CodeDetailRowHooks.verticalPadding)
        .contentShape(Rectangle())
    }
}

/// Maps the semantic label runs to the row fonts and tokens. Shared by the
/// collapsed row and the group list so the single-target verb is `text400`
/// and the target `text100` in both places.
struct CodeToolLabelText: View {
    let runs: [CodeToolLabelRun]

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        CodeToolLabelRun.styledText(runs, scheme: colorScheme)
    }
}

/// The pushed single-call page: row identity + input, then the output. It
/// deliberately has no `NavigationStack`; the group page owns the stack.
struct CodeToolCallDetailView: View {
    let call: CodeToolCall
    let footnote: String?

    private let output: CodeToolOutput
    private let inputText: String?

    @Environment(\.colorScheme) private var colorScheme
    /// The D9 placeholder line box (see `CodeDetailRowHooks`).
    @ScaledMetric(relativeTo: CodeDetailRowHooks.textStyle)
    private var detailTextLineHeight = CodePageTheme.toolRowTextLineHeight

    init(call: CodeToolCall,
         footnote: String? = nil) {
        self.call = call
        self.footnote = footnote
        output = CodeToolOutput(item: call.item, kind: call.kind)
        inputText = Self.inputText(for: call)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CodePageTheme.blockSpacing) {
                detailSection
                outputSection
                footnoteSection
            }
            .padding(.horizontal, CodeToolDetailMetrics.contentInset)
            .padding(.vertical, CodeToolDetailMetrics.verticalInset)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background {
            CodeToolDetailMetrics.pageBackground
                .resolved(for: colorScheme)
                .ignoresSafeArea()
        }
        .navigationTitle(Text(verbatim: call.name))
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(CodeToolDetailMetrics.pageBackground.resolved(for: colorScheme),
                           for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
    }

    // MARK: - Sections (official order)

    /// `ToolCallDetailSections`: row identity plus the input area.
    private var detailSection: some View {
        VStack(alignment: .leading, spacing: CodePageTheme.blockSpacing) {
            summaryRow
            if let inputText {
                CodeToolCodeCard(title: String(localized: "Input"), code: inputText)
            }
        }
    }

    /// The main content: the official five-case output switch. With no
    /// output the section is omitted entirely instead of drawing an empty
    /// "Output" header.
    @ViewBuilder private var outputSection: some View {
        if !output.isEmpty {
            CodeToolOutputView(output: output, kind: call.kind)
        }
    }

    @ViewBuilder private var footnoteSection: some View {
        if let footnote, !footnote.isEmpty {
            Text(verbatim: footnote)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Rows

    /// The detail page's row identity, built from the same official row
    /// primitives as the collapsed row: an `IconFrame` slot, the label,
    /// `TimelineStatusGlyph`, `DiffIndicator` and the caret. The official
    /// `TimelineGroupRow`'s own typography/row height/divider are UNKNOWN
    /// (D9), so the type/row box stays a single hook here
    /// (`CodeDetailRowHooks`) rather than being invented per call site.
    private var summaryRow: some View {
        HStack(alignment: .center, spacing: CodeDetailRowHooks.iconSpacing) {
            AnthropiconView(name: CodeToolLabels.anthropicon(for: call),
                            size: .large)
                .foregroundStyle(CodeDetailRowHooks.iconTint)
                .frame(width: CodePageTheme.toolRowIconFrameSize,
                       height: CodePageTheme.toolRowIconFrameSize)
                .accessibilityHidden(true)

            // The official `TimelineRow` is a two-child HStack (icon,
            // content); the content's own spacing is UNKNOWN (D9), so it
            // keeps SwiftUI's default rather than the icon's 16 pt gap.
            HStack(alignment: .center) {
                Text(verbatim: call.name)
                    .font(.custom(CodePageTheme.monoFontName,
                                  size: CodeDetailRowHooks.textSize,
                                  relativeTo: CodeDetailRowHooks.textStyle))
                    .foregroundStyle(CodeDetailRowHooks.primaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(minHeight: detailTextLineHeight, alignment: .leading)

                CodeTimelineStatusGlyph(status: call.status,
                                        failureExtent: failureExtent)

                if case let .diff(diff) = output,
                   diff.added > 0 || diff.removed > 0 {
                    CodeDiffIndicator(stat: CodeDiffStat(added: diff.added,
                                                         removed: diff.removed))
                }

                Spacer(minLength: 0)
            }
        }
        .padding(.vertical, CodeDetailRowHooks.verticalPadding)
        // [E] R28 §U 收口二 二-D — `TimelineListRowPlain` hides separators
        // and clears the row background. These are no-ops unless the row is
        // hosted in the official `List`; the List container and its
        // `PlainListRowInsets` remain UNKNOWN (U), so the sheet keeps its
        // ScrollView sections.
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }

    private var failureExtent: CodeFailureExtent? {
        switch call.status {
        case .complete, .running: return nil
        case .failed: return .failed
        }
    }

    // MARK: - Wire reads

    /// The input area reads the call's raw input; `arguments` is Codex's alias.
    /// An absent or empty object hides the card (official `showsInput`).
    /// Internal so the gate can assert a group row's pushed page has input.
    static func inputText(for call: CodeToolCall) -> String? {
        let content = call.item.raw["content"] ?? .object([:])
        guard let input = content["input"] ?? content["arguments"],
              input != .null else { return nil }
        if case let .object(fields) = input, fields.isEmpty { return nil }
        if case let .array(items) = input, items.isEmpty { return nil }
        if let text = input.stringValue { return text.isEmpty ? nil : text }
        let json = input.formattedJSON
        return json.isEmpty ? nil : json
    }

}

/// The single-call page rooted in its own `NavigationStack` with the sheet
/// close control. Used by previews and the gate; the product presents the
/// group page (`CodeToolGroupDetailView`) and pushes the bare
/// `CodeToolCallDetailView`.
struct CodeToolDetailView: View {
    let call: CodeToolCall
    let footnote: String?

    @Environment(\.dismiss) private var dismiss

    init(call: CodeToolCall,
         footnote: String? = nil) {
        self.call = call
        self.footnote = footnote
    }

    var body: some View {
        NavigationStack {
            CodeToolCallDetailView(call: call, footnote: footnote)
                .toolbar {
                    SheetCloseToolbar { dismiss() }
                }
        }
    }
}

// MARK: - Detail-row hook (D9)

/// The official `TimelineGroupRow`'s geometry and its still-unknown values
/// (R28 §U-C.7, closed further by §U 收口二 二-D).
///
/// Evidenced:
/// - `TimelineRow` is `HStack(spacing: 16)<icon, content>` (0x100fd6958);
/// - the row's vertical padding is 8.0 pt (0x100fd6638/0x100fd6a90);
/// - `TimelineListRowPlain` hides separators and clears the row background.
///
/// Still UNKNOWN (D9): the row Typography (the environment
/// `TypographyMetadata`), its light/dark RGB, `PlainListRowInsets`, and the
/// connector. `textSize`/`textStyle` below are the only decoded Code text
/// preset (the collapsed row's 15/400/21), used as the placeholder so one
/// probe replaces this block.
private enum CodeDetailRowHooks {
    static let iconSpacing: CGFloat = 16
    static let verticalPadding: CGFloat = 8
    static let textSize: CGFloat = CodePageTheme.toolRowFontSize
    static let textStyle: Font.TextStyle = CodePageTheme.toolRowBodyTextStyle
    /// D9 UNKNOWN: the official detail text is a semantic UIColor→Color
    /// token; its light/dark RGB is not decoded. System semantic colours
    /// match that mechanism without inventing an RGB.
    static let primaryText: Color = .primary
    static let iconTint: Color = .secondary
}

// MARK: - Detail-page-only metrics

/// Values the shared `CodePageTheme` does not carry yet.
///
/// - `[E]` = CANONICAL/token-proven; source section cited.
/// - `[I]` = measured from the reference frames in
///   `docs/code-page-visual-evidence.md` (V-numbers).
/// - `[U]` = no evidence; the stand-in is labelled.
private enum CodeToolDetailMetrics {

    /// [I] V80 — light `#F9F9F7` (249,249,247), dark `#151515` (21,21,21).
    static let pageBackground = CodePageTheme.SchemeColor(
        light: Color(.sRGB, red: 249.0 / 255.0,
                    green: 249.0 / 255.0,
                    blue: 247.0 / 255.0),
        dark: Color(.sRGB, red: 21.0 / 255.0,
                    green: 21.0 / 255.0,
                    blue: 21.0 / 255.0))

    /// [E] V51 — the page keeps the timeline's 16 pt horizontal row margin.
    static let contentInset: CGFloat = CodePageTheme.rowMarginLeading

    /// [I] Detail pages have no sampled vertical inset; 16 pt matches the
    /// Markdown block spacing [E] V55 and keeps the first row off the bar.
    static let verticalInset: CGFloat = 16

}

// MARK: - Previews

private func previewCall(name: String,
                         kind: CodeToolKind,
                         status: V2TimelineItemStatus = .done,
                         content: String) -> CodeToolCall {
    let json = """
    {"id":"preview-\(name)","sessionId":"preview-session","type":"tool",\
    "status":"\(status.rawValue)","orderSeq":1,"content":\(content)}
    """
    guard let item = try? JSONDecoder().decode(V2TimelineItem.self,
                                               from: Data(json.utf8)) else {
        preconditionFailure("Invalid preview timeline item")
    }
    return CodeToolCall(item: item, kind: kind)
}

private func previewLongDiffCall() -> CodeToolCall {
    let lines = (1...1200).map { index in
        let kind = index % 3 == 0 ? "remove" : "add"
        return #"{"type":"\#(kind)","content":"let value\#(index) = \#(index)","oldLineNumber":\#(index),"newLineNumber":\#(index)}"#
    }.joined(separator: ",")
    let content = #"{"toolName":"Edit","input":{"file_path":"Sources/Preview.swift"},"output":{"kind":"diff","lines":[\#(lines)],"lineStat":{"addedLineCount":800,"removedLineCount":400}}}"#
    return previewCall(name: "Edit", kind: .edit, content: content)
}

#Preview("Tool detail — text output") {
    CodeToolDetailView(call: previewCall(
        name: "Bash",
        kind: .bash,
        content: #"{"toolName":"Bash","input":{"command":"npm test"},"output":"$ npm test\n\n> build\n> test\n\nAll 42 tests passed.\n"}"#))
}

#Preview("Tool detail — failure") {
    CodeToolDetailView(call: previewCall(
        name: "Bash",
        kind: .bash,
        status: .failed,
        content: #"{"toolName":"Bash","input":{"command":"npm run build"},"error":"error TS2322: Type 'string' is not assignable to type 'number'.","isError":true}"#))
}

#Preview("Tool detail — long diff (300-row pages)") {
    CodeToolDetailView(call: previewLongDiffCall())
}

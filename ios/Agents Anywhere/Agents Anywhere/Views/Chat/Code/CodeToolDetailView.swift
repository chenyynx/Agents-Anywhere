import SwiftUI
import UIKit
import Foundation

// The Code page's full-screen tool detail (`CANONICAL/04-tool-calls.md` §4.2).
//
// Official structure: a collapsed row's tap replaces the transcript with a
// `NavigationStack` + `ScrollView` page. `ToolCallDetail` carries one call plus
// the calls that followed it, and `ToolCallDetailSections` lays out, in order:
// the detail section (row identity + input), the following calls, the main
// content (the five-case output), and an optional footnote. The official
// transcript has no in-place expansion; this view is the only expanded face of
// a tool row.
//
// The page presentation itself is [U] in the task sheet (§11): W7 decides
// push / sheet / fullScreenCover. This view owns the NavigationStack and the
// page body either way, and only needs `@Environment(\.dismiss)` to close.
//
// Detail-page-only visual values live in `CodeToolDetailMetrics` below, each
// tagged with its source. Shared values come from `CodePageTheme`.

struct CodeToolDetailView: View {
    let call: CodeToolCall
    /// The calls after this one in the same span. The W4 entry point is the
    /// single call; the slot is kept in official order so a span renderer can
    /// fill it without re-laying out the page.
    let followingCalls: [CodeToolCall]
    /// Official `ToolCallDetail.footnote?`. Rendered only when the caller has
    /// something to say; the official page has no footnote in the common case.
    let footnote: String?
    /// The session's working directory, for the following-call labels.
    let cwd: String?

    private let output: CodeToolOutput
    private let inputText: String?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric(relativeTo: .caption) private var sectionLabelFontSize =
        CodeToolDetailMetrics.sectionLabelFontSize
    /// The D9 placeholder line box (see `CodeDetailRowHooks`).
    @ScaledMetric(relativeTo: CodeDetailRowHooks.textStyle)
    private var detailTextLineHeight = CodePageTheme.toolRowTextLineHeight

    init(call: CodeToolCall,
         followingCalls: [CodeToolCall] = [],
         footnote: String? = nil,
         cwd: String? = nil) {
        self.call = call
        self.followingCalls = followingCalls
        self.footnote = footnote
        self.cwd = cwd
        output = CodeToolOutput(item: call.item, kind: call.kind)
        inputText = Self.inputText(for: call)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: CodePageTheme.blockSpacing) {
                    detailSection
                    followingCallsSection
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
            .toolbar {
                SheetCloseToolbar { dismiss() }
            }
        }
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

    /// `ToolCallDetail.followingCalls`: kept as a real section (not a blank
    /// placeholder) so a multi-call span can render its siblings in order.
    @ViewBuilder private var followingCallsSection: some View {
        if !followingCalls.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(String(localized: "Following calls"))
                    .font(.system(size: sectionLabelFontSize,
                                  weight: .regular,
                                  design: .monospaced))
                    .foregroundStyle(.secondary)
                // [E] R28 §U 收口二 二-D — `TimelineListRowPlain` hides the
                // separators, so the rows are stacked without dividers.
                VStack(spacing: 0) {
                    ForEach(followingCalls) { following in
                        followingRow(following)
                    }
                }
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

    /// A following call keeps the collapsed row's verb + target shape. Showing
    /// the bare tool name ("Edit" five times) told the reader nothing about
    /// what the siblings touched (device report 2026-10-23). The row uses the
    /// official `TimelineGroupRow` composition (icon slot, status glyph, diff,
    /// single-line text); its typography/vertical box is the D9 hook above.
    private func followingRow(_ following: CodeToolCall) -> some View {
        let label = CodeToolLabels.label(for: [following], cwd: cwd)
        return HStack(alignment: .center, spacing: CodeDetailRowHooks.iconSpacing) {
            AnthropiconView(name: CodeToolLabels.anthropicon(for: following),
                            size: .large)
                .foregroundStyle(CodeDetailRowHooks.iconTint)
                .frame(width: CodePageTheme.toolRowIconFrameSize,
                       height: CodePageTheme.toolRowIconFrameSize)
                .accessibilityHidden(true)
            HStack(alignment: .center) {
                followingLabelText(label)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(minHeight: detailTextLineHeight, alignment: .leading)
                CodeTimelineStatusGlyph(
                    status: following.status,
                    failureExtent: following.status == .failed ? .failed : nil)
                if let diff = label.diff, diff.hasCounts {
                    CodeDiffIndicator(stat: diff)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.vertical, CodeDetailRowHooks.verticalPadding)
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }

    private func followingLabelText(_ label: CodeToolRowLabel) -> Text {
        let sans = Font.custom(CodePageTheme.sansFontName,
                               size: CodeDetailRowHooks.textSize,
                               relativeTo: CodeDetailRowHooks.textStyle)
        let mono = Font.custom(CodePageTheme.monoFontName,
                               size: CodeDetailRowHooks.textSize,
                               relativeTo: CodePageTheme.toolRowTextStyle)
        let secondary = CodeDetailRowHooks.secondaryText
        let primary = CodeDetailRowHooks.primaryText
        guard let target = label.target, !target.isEmpty else {
            return Text(label.verb).font(sans).foregroundStyle(secondary)
        }
        return Text(label.verb + " ").font(sans).foregroundStyle(secondary)
            + Text(target).font(mono).foregroundStyle(primary)
    }

    // MARK: - Wire reads

    /// The input area reads the call's raw input; `arguments` is Codex's alias.
    /// An absent or empty object hides the card (official `showsInput`).
    private static func inputText(for call: CodeToolCall) -> String? {
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
    static let secondaryText: Color = .secondary
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

    /// [I] V02-V04 — the section headers use the 13 pt code-card title
    /// preset (V62).
    static let sectionLabelFontSize: CGFloat = 13

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

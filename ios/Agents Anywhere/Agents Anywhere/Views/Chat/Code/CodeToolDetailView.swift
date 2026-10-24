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
    @ScaledMetric(relativeTo: CodePageTheme.toolRowTextStyle) private var toolRowFontSize =
        CodePageTheme.toolRowFontSize
    @ScaledMetric(relativeTo: .caption) private var sectionLabelFontSize =
        CodeToolDetailMetrics.sectionLabelFontSize
    @ScaledMetric(relativeTo: .footnote) private var followingFontSize =
        CodeToolDetailMetrics.followingFontSize

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
                ToolbarItem(placement: .topBarLeading) {
                    closeButton
                }
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
                VStack(spacing: 0) {
                    ForEach(followingCalls) { following in
                        followingRow(following)
                        if following.id != followingCalls.last?.id {
                            Divider()
                        }
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
            CodeToolOutputView(output: output)
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

    /// The detail page's row identity. The official `TimelineRow` is an icon,
    /// a label and an optional failure glyph; SF Symbols stand in for the
    /// non-distributable Anthropicon set (`docs/perf-6b-c5-code-profile-task.md`
    /// §6.5).
    private var summaryRow: some View {
        HStack(alignment: .center, spacing: 10) {
            AnthropiconView(name: CodeToolLabels.anthropicon(for: call.kind),
                            size: .large)
                .foregroundStyle(call.status == .failed ? Color.red : Color.secondary)
                .frame(width: 20)
                .accessibilityHidden(true)

            Text(verbatim: call.name)
                .font(.system(size: toolRowFontSize,
                              weight: CodePageTheme.toolRowFontWeight,
                              design: .monospaced))
                .lineLimit(1)
                .truncationMode(.tail)

            if case let .diff(diff) = output,
               diff.added > 0 || diff.removed > 0 {
                CodeDetailDiffIndicator(added: diff.added, removed: diff.removed)
            }

            Spacer(minLength: 8)

            if call.status == .failed {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .accessibilityHidden(true)
            }
        }
        .frame(minHeight: CodePageTheme.toolRowLineHeight)
        .accessibilityElement(children: .combine)
        // The visible status word is gone; VoiceOver still gets the state.
        .accessibilityValue(accessibilityValue)
    }

    private var accessibilityValue: String {
        var parts = [call.item.status.label]
        if case let .diff(diff) = output {
            if diff.added > 0 { parts.append("+\(diff.added)") }
            if diff.removed > 0 { parts.append("−\(diff.removed)") }
        }
        return parts.joined(separator: " ")
    }

    /// A following call keeps the collapsed row's verb + target shape. Showing
    /// the bare tool name ("Edit" five times) told the reader nothing about
    /// what the siblings touched (device report 2026-10-23).
    private func followingRow(_ following: CodeToolCall) -> some View {
        let label = CodeToolLabels.label(for: [following], cwd: cwd)
        return HStack(spacing: 10) {
            AnthropiconView(name: CodeToolLabels.anthropicon(for: following.kind),
                            size: .large)
                .foregroundStyle(.secondary)
                .frame(width: 20)
                .accessibilityHidden(true)
            followingLabelText(label)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            if following.status == .failed {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .accessibilityHidden(true)
            }
        }
        .frame(minHeight: 32)
        .accessibilityElement(children: .combine)
        .accessibilityValue(following.item.status.label)
    }

    private func followingLabelText(_ label: CodeToolRowLabel) -> Text {
        guard let target = label.target, !target.isEmpty else {
            return Text(label.verb)
                .font(.system(size: followingFontSize))
                .foregroundStyle(.secondary)
        }
        return Text(label.verb + " ")
            .font(.system(size: followingFontSize))
            .foregroundStyle(.secondary)
            + Text(target)
            .font(.system(size: followingFontSize, design: .monospaced))
            .foregroundStyle(.primary)
    }

    private var closeButton: some View {
        Button {
            dismiss()
        } label: {
            ZStack {
                Circle()
                    .fill(Color.primary.opacity(0.08))
                    .frame(width: CodeToolDetailMetrics.closeButtonDiameter,
                           height: CodeToolDetailMetrics.closeButtonDiameter)
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
            }
            .frame(width: CodeToolDetailMetrics.closeButtonHitSize,
                   height: CodeToolDetailMetrics.closeButtonHitSize)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "关闭"))
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

/// The row's `DiffIndicator` (`CANONICAL/04-tool-calls.md` §4.2/§6.2). The
/// detail page has no separate component for it, so this mirrors the themed
/// token set the collapsed row uses.
private struct CodeDetailDiffIndicator: View {
    let added: Int
    let removed: Int

    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric(relativeTo: CodePageTheme.toolRowTextStyle)
    private var fontSize = CodePageTheme.diffIndicatorFontSize
    @ScaledMetric(relativeTo: CodePageTheme.toolRowTextStyle)
    private var horizontalPadding = CodePageTheme.diffIndicatorHorizontalPadding
    /// [E] R19 tool-row-status.md — each half is 18 pt tall.
    @ScaledMetric(relativeTo: CodePageTheme.toolRowTextStyle)
    private var halfHeight = CodePageTheme.diffIndicatorHeight
    @ScaledMetric(relativeTo: CodePageTheme.toolRowTextStyle)
    private var cornerRadius = CodePageTheme.diffIndicatorCornerRadius

    var body: some View {
        HStack(spacing: 0) {
            if added > 0 {
                half(text: "+\(added)",
                     fill: CodePageTheme.diffIndicatorAddFill,
                     ink: CodePageTheme.diffIndicatorAddText)
            }
            if removed > 0 {
                half(text: "−\(removed)",
                     fill: CodePageTheme.diffIndicatorRemoveFill,
                     ink: CodePageTheme.diffIndicatorRemoveText)
            }
        }
        // [E] 11 pt / weight 550 in the official mono face.
        .font(Font(MarkdownFontFactory.font(
            name: CodePageTheme.monoFontName,
            size: fontSize,
            weight: CodePageTheme.diffIndicatorFontWeight)))
        .lineLimit(1)
        .fixedSize()
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .accessibilityHidden(true)
    }

    private func half(text: String,
                      fill: CodePageTheme.SchemeColor,
                      ink: CodePageTheme.SchemeColor) -> some View {
        Text(verbatim: text)
            .monospacedDigit()
            .foregroundStyle(ink.resolved(for: colorScheme))
            .padding(.horizontal, horizontalPadding)
            .frame(height: halfHeight)
            .background(fill.resolved(for: colorScheme))
    }
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

    /// [I] V76 — the close control measures about 35 pt across in the Diff
    /// sheet; 30 pt inside a 44 pt hit target keeps the touch area standard.
    static let closeButtonDiameter: CGFloat = 30

    /// [U] Not sampled: the standard 44 pt iOS hit target around the circle.
    static let closeButtonHitSize: CGFloat = 44

    /// [E] V51 — the page keeps the timeline's 16 pt horizontal row margin.
    static let contentInset: CGFloat = CodePageTheme.rowMarginLeading

    /// [I] Detail pages have no sampled vertical inset; 16 pt matches the
    /// Markdown block spacing [E] V55 and keeps the first row off the bar.
    static let verticalInset: CGFloat = 16

    /// [I] V02-V04 — the detail page reuses the 15 pt mono row label; the
    /// section headers use the 13 pt code-card title preset (V62).
    static let sectionLabelFontSize: CGFloat = 13
    static let followingFontSize: CGFloat = 15

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

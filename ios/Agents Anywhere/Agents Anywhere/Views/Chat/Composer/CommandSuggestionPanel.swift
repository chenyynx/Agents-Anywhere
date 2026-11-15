import SwiftUI

/// Slash-command suggestions above the composer, rebuilt on the official
/// Claude app's autocomplete card (1.261019.51).
///
/// EVIDENCE — decompiled Swift type metadata / bodies:
/// - `ClaudeComposer.InputAutocompleteSuggestionList`: ScrollViewReader +
///   onChange, ScrollView + scrollBounceBehavior(.basedOnSize),
///   `InputAutocompleteSuggestionRows` in a VStack, geometry action feeding
///   the measured content height, `_FlexFrameLayout` (max height),
///   background(color, in: RoundedRectangle), clipShape, shadow,
///   `_TraitWritingModifier<TransitionTraitKey>` and `_AnimationModifier<Int>`.
/// - Body calls: `.frame(minWidth:idealWidth:maxWidth:minHeight:idealHeight:
///   maxHeight:alignment:)`, `RoundedCornerStyle`, `.background(_:in:)`,
///   `.clipShape`, `AnyTransition.opacity.combined(with: .scale(scale:anchor:
///   .bottom))` (immediate 0.95), `.animation(_, value: items.count)` with a
///   0.15 s curve.
/// - Height helper `0x1017c1a18`: `rowMinHeight × min(count, 5) + 2 × 8 pt`;
///   the cap is five rows, rowMinHeight comes from a `SwiftUI.ScaledMetric`.
/// - `ClaudeComposer.InputAutocompleteSuggestionRows`: VStack + ForEach, each
///   row a Button with `ListItemRowButtonStyle`, flex frame, background(color,
///   in: RoundedRectangle) for the highlight.
/// - `ClaudeComposer.InputAutocompleteCommandRow`: VStack → Text (ClaudeFonts),
///   foreground color, `lineLimit` environment + `Text.TruncationMode`
///   (two-line description), padding.
///
/// Screenshot measurements (1179×2556 @3x = 393×852 pt, the reference pp sent):
/// card side inset 8–9 pt (same as the composer card), 20 pt row text inset,
/// name JetBrains Mono 13 pt (the bundled ClaudeFonts face — the system mono
/// at the same size reads ~9 % smaller in x-height), description Anthropic
/// Sans 12 pt with 1.3 pt leading (`text400`), two lines then "…", corner
/// radius 16 pt, 16 pt gap above the composer. Both are fixed sizes: the
/// official card does not follow Dynamic Type, and on a phone set to ~0.92×
/// the same custom fonts declared `relativeTo: .footnote` rendered at ~12 pt
/// (21.5 px advance vs the official 23.2 px). No header, no close button —
/// the official card is a bare list.
struct CommandSuggestionPanel: View {
    let chat: SessionChatModel
    @Bindable var draft: ComposerDraft
    @Binding var forced: Bool
    let controls: ChatControlMetrics
    let editor: ComposerEditorController

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .footnote) private var rowMinHeight: CGFloat = 56
    @State private var dismissedFor: String?

    /// Official geometry. The radius is measured off the reference screenshot;
    /// `2 × contentInset` is the `2 × 8` term in the height formula.
    private let cornerRadius: CGFloat = 16
    private let contentInset: CGFloat = 8
    private let rowInset: CGFloat = 20
    private let maxVisibleRows = 5

    private var slashQuery: String? {
        guard let intent = SlashIntent(draft.text), intent.isCommandLike, intent.suffix.isEmpty, !intent.multiline else { return nil }
        return intent.command
    }
    private var query: String { slashQuery ?? "" }
    private var suggestions: [V2RuntimeCommand] { chat.commands.filter { $0.matches(query) } }
    private var isVisible: Bool {
        guard chat.offersCommands, draft.attachments.isEmpty || forced else { return false }
        if forced { return true }
        guard slashQuery != nil, dismissedFor != draft.text else { return false }
        // Typing "/" explains why commands cannot run; longer text stays a message.
        if chat.commandsUnavailableReason != nil { return draft.text.trimmingCharacters(in: .whitespaces) == "/" }
        // Stay visible while the catalog is still empty so the panel's `.task`
        // can load it. Before this, typing `/` on a fresh session never
        // opened the card at all: the old condition required the catalog to
        // be loading, which only happened after the card was already shown.
        return true
    }

    /// Official cap: five `rowMinHeight`s plus the 8 pt insets on both ends.
    /// Rows can be taller than `rowMinHeight` (two-line descriptions), so the
    /// fifth row is intentionally clipped in the screenshot as well.
    private var maximumHeight: CGFloat {
        rowMinHeight * CGFloat(min(suggestions.count, maxVisibleRows)) + contentInset * 2
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            if isVisible {
                panel
                    .transition(reduceMotion
                        ? .opacity
                        : .opacity.combined(with: .scale(scale: 0.95, anchor: .bottom)))
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: isVisible)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: suggestions.count)
    }

    private var panel: some View {
        VStack(spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(panelFill, in: panelShape)
            .clipShape(panelShape)
            .overlay(panelShape.strokeBorder(panelBorder, lineWidth: 0.5))
            .shadow(color: shadowColor, radius: 10, x: 0, y: 3)
            .padding(.horizontal, controls.horizontalInset(expanded: draft.isExpanded))
            // The composer adds 8 pt of its own top margin; together they make
            // the 16 pt gap measured between the card and the composer.
            .padding(.bottom, 8)
            .task(id: chat.canUseCommands) { await chat.loadCommands() }
    }

    private var panelShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    /// Official card fill is the page colour itself; only the hairline and the
    /// down-right shadow separate it from the background (screenshot check).
    private var panelFill: Color {
        Color(uiColor: CodePageTheme.pageBackgroundUIColor)
    }

    /// `border20` = the text base at 30% (measured 183 on 249 in the reference).
    private var panelBorder: Color {
        CodePageTheme.text100Color.resolved(for: colorScheme).opacity(0.30)
    }

    private var shadowColor: Color {
        colorScheme == .dark ? Color.black.opacity(0.45) : Color.black.opacity(0.10)
    }

    private var nameColor: Color {
        CodePageTheme.accentSecondary100Color.resolved(for: colorScheme)
    }

    private var detailColor: Color {
        CodePageTheme.text400Color.resolved(for: colorScheme)
    }

    @ViewBuilder private var content: some View {
        if let reason = chat.commandsUnavailableReason {
            message(reason, symbol: "info.circle")
        } else if chat.commands.isEmpty && chat.isLoadingCommands {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(String(localized: "正在读取指令…"))
                    .font(.custom(CodePageTheme.sansFontName, fixedSize: 12))
                    .foregroundStyle(detailColor)
            }
            .padding(.horizontal, rowInset)
            .frame(minHeight: rowMinHeight)
        } else if chat.commands.isEmpty, chat.commandsError != nil {
            VStack(alignment: .leading, spacing: 4) {
                message(String(localized: "无法读取指令。"), symbol: "exclamationmark.circle")
                Button(String(localized: "重试")) { Task { await chat.loadCommands(force: true) } }
                    .font(.footnote.weight(.medium))
                    .padding(.horizontal, rowInset)
                    .frame(minHeight: 36)
            }
        } else if suggestions.isEmpty {
            message(String(localized: "没有匹配的指令"), symbol: "magnifyingglass")
        } else {
            list
        }
    }

    /// Official list: a plain (non-lazy) VStack of buttons. More than the
    /// visible-row budget becomes a fixed-height ScrollView; `fixedSize`
    /// around a ScrollView made its content its own height, so the list was
    /// clipped and could not scroll (only the first four rows were reachable).
    @ViewBuilder private var list: some View {
        if suggestions.count > maxVisibleRows {
            ScrollView(.vertical) {
                rows
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: maximumHeight)
        } else {
            rows
        }
    }

    private var rows: some View {
        VStack(spacing: 0) {
            ForEach(suggestions) { command in row(command) }
        }
        .padding(.vertical, contentInset)
    }

    private func message(_ text: String, symbol: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            AppSymbol(symbol, size: 14).foregroundStyle(detailColor)
            Text(text)
                .font(.custom(CodePageTheme.sansFontName, fixedSize: 12))
                .foregroundStyle(detailColor)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, rowInset)
        .padding(.vertical, contentInset)
        .frame(minHeight: rowMinHeight, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    /// Official row: monospaced `/name` over a two-line description, 20 pt side
    /// inset, a full-width hit area, and the button style's rounded highlight.
    private func row(_ command: V2RuntimeCommand) -> some View {
        let block = chat.commandBlock(command)
        let detail = block.map { chat.commandBlockMessage(command, $0) }
            ?? command.description
            ?? (command.title == command.id ? nil : command.title)
        return Button {
            forced = false
            if command.isInsertCommand {
                // Official card: the skill goes back into the composer and
                // the whole command is selected, so typing replaces it and
                // sending dispatches it as a normal prompt. Dismiss the card
                // for this exact text; typing a new prefix reopens it.
                let text = chat.complete(command)
                dismissedFor = text
                editor.selectAllAfterSync(text)
            } else {
                Task { await chat.choose(command) }
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: "/\(command.id)")
                    // Official card: JetBrains Mono 13 pt — the bundled
                    // ClaudeFonts face, which is why the system mono at the
                    // same size read smaller (x-height 21 vs 23 px @3x).
                    .font(.custom(CodePageTheme.monoFontName, fixedSize: 13))
                    .foregroundStyle(nameColor)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        // Official description: Anthropic Sans 12 pt
                        // (cap 25–26 px @3x). Not the system 13 pt face.
                        .font(.custom(CodePageTheme.sansFontName, fixedSize: 12))
                        .foregroundStyle(detailColor)
                        // Official description line pitch is 16.3 pt; the
                        // 12 pt Anthropic Sans line box is 15 pt.
                        .lineSpacing(1.3)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            // The official row applies padding first, then the flex frame
            // (`_PaddingLayout` → `_FlexFrameLayout` → background), so
            // `rowMinHeight` is the floor for the padded row, not the text.
            .padding(.horizontal, rowInset)
            .padding(.vertical, contentInset)
            .frame(maxWidth: .infinity, minHeight: rowMinHeight, alignment: .leading)
            .contentShape(Rectangle())
            .opacity(block == nil ? 1 : 0.5)
        }
        .buttonStyle(CommandRowButtonStyle())
        .disabled(chat.isRunningCommand)
        .accessibilityIdentifier("chat.command.\(command.id)")
    }

    /// Official row highlight is a rounded fill (`ListItemRowButtonStyle` +
    /// `background(_:in: RoundedRectangle)`); its colour/radius are not visible
    /// in the reference, so the press state is a light text-tinted fill.
    private struct CommandRowButtonStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .background {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.primary.opacity(configuration.isPressed ? 0.06 : 0))
                }
                .opacity(configuration.isPressed ? 0.65 : 1)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
        }
    }
}

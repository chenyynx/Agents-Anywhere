import SwiftUI

/// The official transcript's truncation footnote and its load control.
///
/// Two official shapes, decoded separately:
/// - **Read** (`FileReadDetailView`): the truncation footnote
///   (`2c67.tool_detail_read_truncated`) stays inside the card; the load
///   status and the `AsyncButton` are a separate `HStack<Text, AsyncButton?>`
///   below it (swiftdump 580104: card, metadata, then the HStack). The button
///   is the inline capsule (`ClaudeInlineButtonStyle` + `Capsule`).
/// - **AA's non-Read / thinking rows**: the truncation note is the in-card
///   "已截断" (`ToolTruncatedNote`); this footer only carries the AA load
///   control.
///
/// Shared by the chat profile's tool/reasoning folds and the Code profile's
/// tool/thinking details: both profiles read the same deferred window.
struct DeferredLoadFooter: View {
    /// `fileOutput` is the official Read shape ("Load full file"); `output` is
    /// the AA extension for any other tool row the deferred window summarised
    /// (the official has no load control there because its tool output is the
    /// tool's own final text). `thinking` is AA-only: the server's budget trim
    /// can summarise a reasoning row.
    enum Kind: Equatable { case fileOutput, output, thinking }

    let chat: SessionChatModel
    /// One footer can complete several rows: a merged thinking block joins
    /// multiple summaries into one body, and one control must finish them.
    let ids: [V2TimelineItemID]
    let kind: Kind
    /// Read keeps the official long footnote inside the card, so the Code
    /// detail passes false here and the note is not repeated below it.
    var showsTruncationNote: Bool

    init(chat: SessionChatModel, id: V2TimelineItemID, kind: Kind,
         showsTruncationNote: Bool = true) {
        self.chat = chat
        self.ids = [id]
        self.kind = kind
        self.showsTruncationNote = showsTruncationNote
    }

    init(chat: SessionChatModel, ids: [V2TimelineItemID], kind: Kind,
         showsTruncationNote: Bool = true) {
        self.chat = chat
        self.ids = ids
        self.kind = kind
        self.showsTruncationNote = showsTruncationNote
    }

    /// One aggregate state: a failure wins over loading wins over idle, and
    /// `loaded` only when every row is complete.
    private var phase: DeferredItemStore.Phase {
        let phases = ids.map { chat.deferredItems.phase($0) }
        if phases.contains(.failed) { return .failed }
        if phases.contains(.offline) { return .offline }
        if phases.contains(.loading) { return .loading }
        if !phases.isEmpty, phases.allSatisfy({ $0 == .loaded }) { return .loaded }
        return .idle
    }

    /// The row behind the control, used for the official line count and the
    /// Read/full-file wording.
    private var item: V2TimelineItem? {
        guard let id = ids.first else { return nil }
        return chat.session.timeline.first { $0.id == id }?.value
    }

    private var effectiveKind: Kind {
        guard kind == .output, ToolTruncation.isReadTool(item) else { return kind }
        return .fileOutput
    }

    var body: some View {
        let phase = phase
        let note = note(phase)
        if effectiveKind == .fileOutput {
            // Official Read: one horizontal line, status text + capsule
            // button (swiftdump 580104). Loaded leaves the text alone; the
            // button disappears.
            HStack(spacing: 12) {
                if !note.isEmpty {
                    Text(note)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                control(phase)
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                if !note.isEmpty {
                    Text(note)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                control(phase)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func control(_ phase: DeferredItemStore.Phase) -> some View {
        switch phase {
        case .loading:
            ProgressView()
                .controlSize(.small)
                .frame(minHeight: 44)
        case .idle, .failed, .offline:
            Button(buttonTitle(phase)) {
                for id in ids where chat.deferredItems.phase(id) != .loaded {
                    if phase == .failed || phase == .offline {
                        chat.deferredItems.retry(id)
                    } else {
                        chat.deferredItems.load(id)
                    }
                }
            }
            .buttonStyle(.plain)
            .font(.footnote.weight(.medium))
            .foregroundStyle(.tint)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            // [U] official `ClaudeInlineButtonStyle` + `Capsule`; the fill
            // and stroke constants are not decoded, so the outline uses tint.
            .background(Capsule().strokeBorder(.tint, lineWidth: 1))
            .contentShape(Capsule())
            .frame(minHeight: 44)
        case .loaded:
            EmptyView()
        }
    }

    /// The truncation note stays visible while loading; a failure replaces it
    /// with the reason, so the reader never mistakes a preview for the whole
    /// output. Uses the iOS-only capitalized `离线` entry: the shared Web
    /// `Offline` key's English value is lowercase.
    private func note(_ phase: DeferredItemStore.Phase) -> String {
        switch phase {
        case .failed:
            return failedTitle
        case .offline:
            return "\(String(localized: "离线")) · \(failedTitle)"
        case .idle, .loading:
            switch effectiveKind {
            case .fileOutput:
                return showsTruncationNote
                    ? Self.truncationText(for: item)
                    : ""
            case .thinking:
                return String(localized: "已按上下文预算截断")
            case .output:
                return ""
            }
        case .loaded:
            switch effectiveKind {
            case .fileOutput, .thinking: return loadedTitle
            case .output: return ""
            }
        }
    }

    /// The official unknown-total footnote ("Showing %lld lines…") counts what
    /// is on screen; the stub carries a bounded tail preview, so its line count
    /// is the honest number. Shared with `ReadTruncationFootnote`, which draws
    /// the same line inside the Read card.
    static func truncationText(for item: V2TimelineItem?) -> String {
        guard let preview = item?.raw["content"]?["outputPreview"]?.stringValue,
              !preview.isEmpty else {
            return String(localized: "已在工具输出上限处截断")
        }
        let lines = preview.split(separator: "\n", omittingEmptySubsequences: false).count
        // Official zh swaps the positional arguments: preserve %n$ when the
        // catalog gains the total-known variant.
        return String(format: String(localized: "显示 %lld 行（已在工具输出上限处截断）"), lines)
    }

    private var failedTitle: String {
        switch effectiveKind {
        case .fileOutput: return String(localized: "无法加载完整文件。")
        case .output: return String(localized: "无法加载完整输出")
        case .thinking: return String(localized: "无法加载完整思考")
        }
    }

    private var loadedTitle: String {
        switch effectiveKind {
        case .fileOutput: return String(localized: "已加载完整文件")
        case .output: return String(localized: "已加载完整输出")
        case .thinking: return String(localized: "已加载完整思考")
        }
    }

    private func buttonTitle(_ phase: DeferredItemStore.Phase) -> String {
        switch phase {
        case .idle:
            switch effectiveKind {
            case .fileOutput: return String(localized: "加载完整文件")
            case .output: return String(localized: "加载完整输出")
            case .thinking: return String(localized: "加载完整思考")
            }
        case .failed, .offline:
            return String(localized: "重试")
        case .loading, .loaded:
            return ""
        }
    }
}

/// The official Read truncation footnote, drawn **inside** the Read card.
/// The load status and the capsule button are a sibling `HStack` below the
/// card (`FileReadDetailView.Body`, swiftdump 580104).
struct ReadTruncationFootnote: View {
    let chat: SessionChatModel
    let id: V2TimelineItemID

    var body: some View {
        let item = chat.session.timeline.first { $0.id == id }?.value
        Text(DeferredLoadFooter.truncationText(for: item))
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 12)
    }
}

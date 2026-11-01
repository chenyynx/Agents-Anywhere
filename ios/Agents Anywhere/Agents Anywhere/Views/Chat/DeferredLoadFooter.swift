import SwiftUI

/// The single in-card status/load line for a cut tool row.
///
/// Official shape (pp 2026-11-01, `0d8e.tool_truncated`): bottom-left inside
/// the card, the 13 pt dark-neutral status text and, when the row can be
/// completed, the inline capsule button next to it. The same line carries
/// "已截断", the Read/other loaded wording, and the failure/offline reason;
/// the text never moves to a separate block or the card's centre.
///
/// Shared by the chat profile's tool/reasoning folds and the Code profile's
/// tool/thinking details: both profiles read the same deferred window.
struct DeferredLoadFooter: View {
    /// `fileOutput` is the official Read wording ("Load full file"); `output`
    /// is the AA extension for any other tool row the deferred window
    /// summarised; `thinking` is AA-only (the server's budget trim).
    enum Kind: Equatable { case fileOutput, output, thinking }

    let chat: SessionChatModel
    /// One footer can complete several rows: a merged thinking block joins
    /// multiple summaries into one body, and one control must finish them.
    let ids: [V2TimelineItemID]
    let kind: Kind
    /// The Code cards put the load/retry action in their header (the existing
    /// Prettify face); their in-card footer is status-only.
    var showsControl: Bool

    init(chat: SessionChatModel, id: V2TimelineItemID, kind: Kind,
         showsControl: Bool = true) {
        self.chat = chat
        self.ids = [id]
        self.kind = kind
        self.showsControl = showsControl
    }

    init(chat: SessionChatModel, ids: [V2TimelineItemID], kind: Kind,
         showsControl: Bool = true) {
        self.chat = chat
        self.ids = ids
        self.kind = kind
        self.showsControl = showsControl
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
        HStack(spacing: 12) {
            if !note.isEmpty {
                ToolStatusText(text: note)
            }
            if showsControl {
                control(phase)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private func control(_ phase: DeferredItemStore.Phase) -> some View {
        switch phase {
        case .loading:
            ProgressView()
                .controlSize(.small)
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
            .contentShape(Rectangle())
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
            // The data-level "已截断" belongs to the card itself
            // (`ToolResult.isTruncated`); a deferred row is not truncated, it
            // is simply not loaded. The header action says what to do.
            case .fileOutput, .output: return ""
            case .thinking: return String(localized: "已按上下文预算截断")
            }
        case .loaded:
            return loadedTitle
        }
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

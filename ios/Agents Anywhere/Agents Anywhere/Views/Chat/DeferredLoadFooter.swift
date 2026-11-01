import SwiftUI

/// The official transcript's truncation footnote (`ToolCallDetailFootnote`)
/// and its explicit load control (`AsyncButton`), not a container of our own:
/// one footnote line in the secondary footnote style and, below it, a plain
/// tinted text button. The preview is already on screen; the full payload is
/// fetched only when the reader asks for it.
///
/// Shared by the chat profile's tool/reasoning folds and the Code profile's
/// tool/thinking details: both profiles read the same deferred window, so both
/// must make the truncation visible and offer the same one-row completion.
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

    init(chat: SessionChatModel, id: V2TimelineItemID, kind: Kind) {
        self.chat = chat
        self.ids = [id]
        self.kind = kind
    }

    init(chat: SessionChatModel, ids: [V2TimelineItemID], kind: Kind) {
        self.chat = chat
        self.ids = ids
        self.kind = kind
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
        guard kind == .output,
              let name = [item?.raw["content"]?["toolName"],
                          item?.raw["content"]?["name"],
                          item?.raw["content"]?["tool"]]
                    .compactMap({ $0?.stringValue }).first?.lowercased()
        else { return kind }
        return name == "read" || name == "readfile" ? .fileOutput : .output
    }

    /// Lines the preview actually shows. The official unknown-total footnote
    /// ("Showing %lld lines…") counts what is on screen; the stub carries a
    /// bounded tail preview, so its line count is the honest number.
    private var shownLines: Int {
        guard let preview = item?.raw["content"]?["outputPreview"]?.stringValue,
              !preview.isEmpty else { return 0 }
        return preview.split(separator: "\n", omittingEmptySubsequences: false).count
    }

    var body: some View {
        let phase = phase
        VStack(alignment: .leading, spacing: 6) {
            Text(note(phase))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            control(phase)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func control(_ phase: DeferredItemStore.Phase) -> some View {
        switch phase {
        case .loading:
            ProgressView()
                .controlSize(.small)
                .frame(minHeight: 44)
                .frame(maxWidth: .infinity, alignment: .leading)
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
            .frame(minHeight: 44)
            .frame(maxWidth: .infinity, alignment: .leading)
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
            return truncationNote
        case .loaded:
            return loadedTitle
        }
    }

    private var truncationNote: String {
        switch effectiveKind {
        case .fileOutput, .output:
            guard shownLines > 0 else { return String(localized: "已在工具输出上限处截断") }
            // Official zh swaps the positional arguments: preserve %n$ when
            // the catalog gains the total-known variant.
            return String(format: String(localized: "显示 %lld 行（已在工具输出上限处截断）"), shownLines)
        case .thinking:
            return String(localized: "已按上下文预算截断")
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

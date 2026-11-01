import SwiftUI

/// The official transcript's truncation footnote plus its explicit load
/// control. The preview is already on screen; the full payload is fetched only
/// when the reader asks for it, and only the row's own control reflects the
/// in-flight state — the row never turns into a spinner.
///
/// Shared by the chat profile's tool/reasoning folds and the Code profile's
/// tool detail: both profiles read the same deferred window, so both must make
/// the truncation visible and offer the same one-row completion.
struct DeferredLoadFooter: View {
    enum Kind: Equatable { case output, thinking }

    let chat: SessionChatModel
    let id: V2TimelineItemID
    let kind: Kind

    var body: some View {
        let phase = chat.deferredItems.phase(id)
        HStack(spacing: 8) {
            Text(note(phase)).font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button(buttonTitle(phase)) {
                if phase == .failed || phase == .offline {
                    chat.deferredItems.retry(id)
                } else {
                    chat.deferredItems.load(id)
                }
            }
            .buttonStyle(.plain).font(.caption.weight(.medium)).foregroundStyle(.tint)
            .disabled(phase == .loading)
            .padding(.horizontal, 8).frame(minHeight: 44)
        }
        .padding(.leading, 12)
        .frame(minHeight: 44)
        .background(.quaternary.opacity(0.3))
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
        }
    }

    private var truncationNote: String {
        switch kind {
        case .output: return String(localized: "已在工具输出上限处截断")
        case .thinking: return String(localized: "已按上下文预算截断")
        }
    }

    private var failedTitle: String {
        switch kind {
        case .output: return String(localized: "无法加载完整输出")
        case .thinking: return String(localized: "无法加载完整思考")
        }
    }

    private func buttonTitle(_ phase: DeferredItemStore.Phase) -> String {
        switch phase {
        case .idle:
            switch kind {
            case .output: return String(localized: "加载完整输出")
            case .thinking: return String(localized: "加载完整思考")
            }
        case .loading:
            return String(localized: "正在加载…")
        case .failed, .offline:
            return String(localized: "重试")
        }
    }
}

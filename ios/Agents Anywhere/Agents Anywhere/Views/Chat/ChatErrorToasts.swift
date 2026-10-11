import SwiftUI

/// Non-inline errors float below the header. Paging only changes the visible
/// toast; retry is always an explicit read, never a replay of the failed action.
struct ChatErrorToasts: View {
    /// The toasts to show (already filtered by the session surface — connection
    /// toasts are withheld while the app-level banner shows the same outage).
    let items: [ChatToast]
    let isRetrying: Bool
    let onRetry: (String) async -> Void
    let onDismiss: (String) -> Void
    @State private var selected: String?
    @ScaledMetric(relativeTo: .footnote) private var lineHeight: CGFloat = 18
    static func height(lineHeight: CGFloat) -> CGFloat { min(220, max(136, lineHeight * 4 + 74)) }
    private var height: CGFloat { Self.height(lineHeight: lineHeight) }


    var body: some View {
        if !items.isEmpty {
            ScrollView(.horizontal) {
                HStack(spacing: 12) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                AppSymbol("exclamationmark.circle").foregroundStyle(.secondary)
                                Text(item.title).font(.subheadline.weight(.medium)).lineLimit(1)
                                Spacer(minLength: 0)
                                if items.count > 1 {
                                    Text("\(index + 1)/\(items.count)").font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                                }
                                Button { onDismiss(item.id) } label: {
                                    AppSymbol("xmark", size: 11).frame(width: 44, height: 44)
                                }.buttonStyle(.plain).accessibilityLabel(String(localized: "关闭此提示"))
                            }
                            ScrollView(.vertical) {
                                Text(item.message).font(.footnote).foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                            }.scrollBounceBehavior(.basedOnSize)
                            if item.canRetry {
                                Button(isRetrying ? String(localized: "正在刷新…") : String(localized: "刷新状态")) { Task { await onRetry(item.id) } }
                                    .font(.footnote.weight(.medium)).frame(minHeight: 36).disabled(isRetrying)
                            }
                        }
                        .padding(.leading, 16).padding(.trailing, 4).padding(.bottom, 12)
                        .frame(height: height)
                        .containerRelativeFrame(.horizontal)
                        .glassEffect(.regular, in: .rect(cornerRadius: 24))
                        .id(item.id)
                    }
                }.scrollTargetLayout()
            }
            .scrollIndicators(.hidden).scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $selected).scrollClipDisabled()
            .frame(height: height)
            .padding(.horizontal, ChatControlMetrics.collapsedHorizontalInset)
            .padding(.top, 4).padding(.bottom, 10)
            .frame(maxWidth: ChatControlMetrics.maximumContentWidth)
            .onChange(of: items.map(\.id), initial: true) { _, ids in
                if selected == nil || !ids.contains(selected ?? "") { selected = ids.first }
            }
            .accessibilityHint(items.count > 1 ? String(localized: "左右滑动查看其他提示") : "")
        }
    }
}

extension ChatErrorToasts {
    /// Shows every toast in `store` (no connection-hiding). For the sheets and
    /// device screens that have no app-level connection banner of their own.
    init(store: ChatToastStore, isRetrying: Bool, onRetry: @escaping (String) async -> Void) {
        self.init(items: store.items, isRetrying: isRetrying, onRetry: onRetry, onDismiss: { store.dismiss($0) })
    }
}

import SwiftUI

/// The reasoning-effort page pushed from the "添加到会话" sheet's own
/// 思考强度 row. The model list used to host that row; the official sheet
/// keeps it on the model card instead, so the page lives on its own here.
struct EffortSelectionList: View {
    @Bindable var settings: ConversationSettings
    var canSelectModel = true
    var onApply: () async -> Bool = { true }
    var applyError: () -> String? = { nil }
    /// Called after a selection is accepted; the host closes its sheet.
    var onFinished: () -> Void = {}

    @State private var isApplying = false
    @State private var showsApplyError = false
    @Environment(\.colorScheme) private var colorScheme

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 28, style: .continuous)
    }

    private var options: [CatalogOption] { settings.model?.reasoning ?? [] }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(Array(options.enumerated()), id: \.element.id) { index, option in
                    if index > 0 {
                        Divider().padding(.leading, 16)
                    }
                    Button {
                        select(option)
                    } label: {
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(option.title)
                                    .font(.system(size: 15))
                                    .foregroundStyle(AppTheme.composerControlGlyph(colorScheme))
                                if !option.detail.isEmpty {
                                    Text(option.detail)
                                        .font(.system(size: 12))
                                        .foregroundStyle(AppTheme.composerSecondaryGlyph(colorScheme))
                                }
                            }
                            Spacer(minLength: 8)
                            if settings.reasoningID == option.id {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(AppTheme.pickerCheckmark(colorScheme))
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, ChatSheetMetrics.rowVerticalPadding)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!option.isEnabled)
                    .opacity(option.isEnabled ? 1 : 0.5)
                }
            }
            .background(AppTheme.composerTileBackground(colorScheme), in: cardShape)
            .padding(.horizontal, ChatSheetMetrics.horizontalInset)
            .padding(.vertical, 16)
        }
        .scrollIndicators(.hidden)
        .background(AppTheme.composerSheetBackground(colorScheme).ignoresSafeArea())
        .alert(String(localized: "无法更改设置"), isPresented: $showsApplyError) {
            Button(String(localized: "好"), role: .cancel) {}
        } message: {
            Text(applyError() ?? String(localized: "当前设置未保存，请稍后重试。"))
        }
    }

    private func select(_ option: CatalogOption) {
        guard !isApplying, canSelectModel, option.isEnabled, let model = settings.model,
              settings.selectModel(model.id, reasoning: option.id) else { return }
        isApplying = true
        Task { @MainActor in
            let accepted = await onApply()
            isApplying = false
            if accepted { onFinished() } else { showsApplyError = true }
        }
    }
}

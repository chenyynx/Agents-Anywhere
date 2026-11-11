import SwiftUI

/// The model list shared by the add-to-chat sheet's "模型" page. Rows carry a
/// subtitle and a selection checkmark (round30 §3.5). The reasoning effort
/// lives on the sheet's own model card, not here — see `EffortSelectionList`.
struct ModelSelectionList: View {
    @Bindable var settings: ConversationSettings
    var canSelectModel = true
    var isLoading = false
    var loadingError: String?
    var onReload: () async -> Void = {}
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

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if isLoading { ProgressView().padding(.vertical, 24) }
                if let loadingError {
                    VStack(spacing: 8) {
                        Text(loadingError).font(.system(size: 12)).foregroundStyle(.secondary)
                        Button(String(localized: "重新加载")) { Task { await onReload() } }
                            .font(.system(size: 12))
                    }
                }
                if settings.catalog.models.isEmpty && !isLoading {
                    Text(String(localized: "没有可选的模型"))
                        .font(.system(size: 12))
                        .foregroundStyle(AppTheme.composerSecondaryGlyph(colorScheme))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                } else {
                    modelCard
                }
            }
            .padding(.horizontal, ChatSheetMetrics.horizontalInset)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .background(AppTheme.composerSheetBackground(colorScheme).ignoresSafeArea())
        .alert(String(localized: "无法更改设置"), isPresented: $showsApplyError) {
            Button(String(localized: "好"), role: .cancel) {}
        } message: {
            Text(applyError() ?? String(localized: "当前设置未保存，请稍后重试。"))
        }
    }

    private var modelCard: some View {
        VStack(spacing: 0) {
            ForEach(Array(settings.catalog.models.enumerated()), id: \.element.id) { index, model in
                if index > 0 {
                    Divider().padding(.leading, 16)
                }
                modelRow(model)
            }
        }
        .background(AppTheme.composerTileBackground(colorScheme), in: cardShape)
    }

    private func modelRow(_ model: ChatModelOption) -> some View {
        Button {
            guard canSelectModel, model.option.isEnabled else { return }
            select { settings.selectModel(model.id) }
        } label: {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.option.title)
                        .font(.system(size: 15))
                        .foregroundStyle(AppTheme.composerControlGlyph(colorScheme))
                    if !model.option.detail.isEmpty {
                        Text(model.option.detail)
                            .font(.system(size: 12))
                            .foregroundStyle(AppTheme.composerSecondaryGlyph(colorScheme))
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 8)
                if settings.modelID == model.id {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(AppTheme.pickerCheckmark(colorScheme))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, ChatSheetMetrics.rowVerticalPadding)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!model.option.isEnabled)
        .opacity(model.option.isEnabled ? 1 : 0.5)
    }

    private func select(_ change: () -> Bool) {
        guard !isApplying, canSelectModel, change() else { return }
        isApplying = true
        Task { @MainActor in
            let accepted = await onApply()
            isApplying = false
            if accepted { onFinished() } else { showsApplyError = true }
        }
    }
}

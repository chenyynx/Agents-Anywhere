import SwiftUI

/// The model list shared by the add-to-chat sheet's "模型" page. Rows carry a
/// subtitle and a selection checkmark (round30 §3.5); the effort row pushes a
/// second list of reasoning options.
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
                if settings.model != nil, !reasoningOptions.isEmpty {
                    NavigationLink { effortList } label: { effortRow }
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
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
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!model.option.isEnabled)
        .opacity(model.option.isEnabled ? 1 : 0.5)
    }

    private var reasoningOptions: [CatalogOption] { settings.model?.reasoning ?? [] }

    private var effortRow: some View {
        HStack(spacing: 8) {
            Text(String(localized: "思考强度"))
                .font(.system(size: 15))
                .foregroundStyle(AppTheme.composerControlGlyph(colorScheme))
            Spacer()
            Text(settings.reasoning?.title ?? String(localized: "默认"))
                .font(.system(size: 15))
                .foregroundStyle(AppTheme.composerSecondaryGlyph(colorScheme))
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AppTheme.composerSecondaryGlyph(colorScheme))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(AppTheme.composerTileBackground(colorScheme), in: cardShape)
        .contentShape(Rectangle())
    }

    private var effortList: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(Array(reasoningOptions.enumerated()), id: \.element.id) { index, option in
                    if index > 0 {
                        Divider().padding(.leading, 16)
                    }
                    Button {
                        guard option.isEnabled, let model = settings.model else { return }
                        select { settings.selectModel(model.id, reasoning: option.id) }
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
                        .padding(.vertical, 14)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!option.isEnabled)
                    .opacity(option.isEnabled ? 1 : 0.5)
                }
            }
            .background(AppTheme.composerTileBackground(colorScheme), in: cardShape)
            .padding(16)
        }
        .scrollIndicators(.hidden)
        .background(AppTheme.composerSheetBackground(colorScheme).ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(String(localized: "思考强度"))
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(AppTheme.composerControlGlyph(colorScheme))
            }
        }
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

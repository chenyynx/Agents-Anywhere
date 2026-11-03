import SwiftUI

/// The model list as its own half-height sheet (draggable to full), matching
/// the official "选择模型" presentation.
struct ModelPickerSheet: View {
    @Bindable var settings: ConversationSettings
    var canSelectModel = true
    var isLoading = false
    var loadingError: String?
    var onReload: () async -> Void = {}
    var onApply: () async -> Bool = { true }
    var applyError: () -> String? = { nil }
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        NavigationStack {
            ModelSelectionList(settings: settings,
                canSelectModel: canSelectModel,
                isLoading: isLoading, loadingError: loadingError,
                onReload: onReload, onApply: onApply, applyError: applyError,
                onFinished: { dismiss() })
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(AppTheme.composerSheetBackground(colorScheme), for: .navigationBar)
                .toolbarBackgroundVisibility(.visible, for: .navigationBar)
                .toolbar {
                    SheetCloseToolbar { dismiss() }
                    ToolbarItem(placement: .principal) {
                        Text(String(localized: "选择模型"))
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(AppTheme.composerControlGlyph(colorScheme))
                    }
                }
        }
        .dynamicTypeSize(.large)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

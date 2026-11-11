import SwiftUI
import UIKit

/// The official "添加到会话" sheet (round30 §3.4): camera + recent photos,
/// the add-file row, the permission row, a connector placeholder, and the
/// takeover switch at the bottom. Model selection lives in its own sheet.
struct AddToChatSheet: View {
    @Bindable var settings: ConversationSettings
    var onPhotos: () -> Void
    var onFiles: () -> Void
    var onCamera: () -> Void = {}
    var onRecentPhotos: ([Data]) -> Void = { _ in }
    var maxPhotoSelection = 5
    var canAttach = true
    var canSelectModel = true
    var canSelectPermission = true
    var isLoading = false
    var loadingError: String?
    var onReload: () async -> Void = {}
    var onApply: () async -> Bool = { true }
    var applyError: () -> String? = { nil }
    var sessionChat: SessionChatModel?

    @State private var pendingTakeover: Bool?
    @State private var isApplying = false
    @State private var showsApplyError = false
    @State private var path: [Page] = []
    /// The app-level store keeps photos and thumbnails warm across sheet
    /// presentations; the local instance only serves previews and test hosts
    /// that did not inject the shared one.
    @Environment(RecentPhotosLoader.self) private var sharedRecentPhotos: RecentPhotosLoader?
    @State private var localRecentPhotos = RecentPhotosLoader()
    @State private var selectedPhotoIDs: Set<String> = []
    @State private var isAddingPhotos = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    private enum Page: Hashable { case models, efforts, permissions }
    private let tile: CGFloat = 100
    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 28, style: .continuous)
    }

    private var recent: RecentPhotosLoader {
        sharedRecentPhotos ?? localRecentPhotos
    }

    private var showsEffortRow: Bool {
        settings.model != nil && !(settings.model?.reasoning.isEmpty ?? true)
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(spacing: 16) {
                    attachmentSources
                    card {
                        row(icon: "anthropicon.fileAdd", title: String(localized: "添加文件"),
                            value: nil, enabled: canAttach, action: onFiles)
                    }
                    card {
                        VStack(spacing: 0) {
                            row(icon: "anthropicon.agent", title: String(localized: "模型"),
                                // The effort has its own row now; the model row
                                // shows the model name only.
                                value: settings.model?.option.title ?? String(localized: "默认模型"),
                                enabled: canSelectModel && !settings.catalog.models.isEmpty) {
                                path.append(.models)
                            }
                            // Official puts the reasoning effort on its own row
                            // under the model row, separated by a hairline.
                            if showsEffortRow {
                                Divider()
                                    .padding(.leading, ChatSheetMetrics.dividerLeadingInset)
                                    .padding(.trailing, ChatSheetMetrics.dividerTrailingInset)
                                row(icon: "anthropicon.extendedThinking",
                                    title: String(localized: "思考强度"),
                                    value: settings.reasoning?.title ?? String(localized: "默认"),
                                    enabled: canSelectModel) {
                                    path.append(.efforts)
                                }
                            }
                        }
                    }
                    card {
                        row(icon: "anthropicon.fastforward", title: String(localized: "权限"),
                            value: settings.permission?.title ?? String(localized: "默认"),
                            enabled: canSelectPermission && !settings.catalog.permissions.isEmpty) {
                            path.append(.permissions)
                        }
                    }
                    card {
                        row(icon: "anthropicon.connectors", title: String(localized: "连接器"),
                            value: String(localized: "即将支持"), enabled: false) {}
                    }
                    takeoverCard
                    if !canAttach {
                        Text(String(localized: "当前运行状态不支持添加附件"))
                            .font(.system(size: 13))
                            .foregroundStyle(AppTheme.composerSecondaryGlyph(colorScheme))
                    }
                    if isLoading { ProgressView(String(localized: "加载对话选项…")) }
                    if let loadingError {
                        VStack(spacing: 8) {
                            Text(loadingError).font(.system(size: 13)).foregroundStyle(.secondary)
                            Button(String(localized: "重新加载")) { Task { await onReload() } }
                                .font(.system(size: 13))
                        }
                    }
                }
                .padding(.horizontal, ChatSheetMetrics.horizontalInset)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
            .background(AppTheme.composerSheetBackground(colorScheme).ignoresSafeArea())
            .toolbarBackground(AppTheme.composerSheetBackground(colorScheme), for: .navigationBar)
            .toolbarBackgroundVisibility(.visible, for: .navigationBar)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                SheetCloseToolbar { dismiss() }
                ToolbarItem(placement: .principal) {
                    Text(String(localized: "添加到会话"))
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(AppTheme.composerControlGlyph(colorScheme))
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(String(localized: "照片")) { onPhotos() }
                        .font(.system(size: 17))
                        .foregroundStyle(AppTheme.composerControlGlyph(colorScheme))
                        .disabled(!canAttach)
                }
            }
            .navigationDestination(for: Page.self) { page in
                switch page {
                case .models:
                    ModelSelectionList(settings: settings,
                        canSelectModel: canSelectModel,
                        isLoading: isLoading, loadingError: loadingError,
                        onReload: onReload, onApply: onApply, applyError: applyError,
                        onFinished: { dismiss() })
                        .navigationTitle(String(localized: "选择模型"))
                        .navigationBarTitleDisplayMode(.inline)
                case .efforts:
                    EffortSelectionList(settings: settings,
                        canSelectModel: canSelectModel,
                        onApply: onApply, applyError: applyError,
                        onFinished: { dismiss() })
                        .navigationTitle(String(localized: "思考强度"))
                        .navigationBarTitleDisplayMode(.inline)
                case .permissions: permissionsPage
                }
            }
        }
        .disabled(isApplying)
        .alert(String(localized: "无法更改设置"), isPresented: $showsApplyError) {
            Button(String(localized: "好"), role: .cancel) {}
        } message: {
            Text(applyError() ?? String(localized: "当前设置未保存，请稍后重试。"))
        }
        .safeAreaInset(edge: .bottom) {
            if !selectedPhotoIDs.isEmpty {
                Button(action: addSelectedPhotos) {
                    HStack(spacing: 8) {
                        if isAddingPhotos { ProgressView().tint(AppTheme.primaryControlForeground(colorScheme)) }
                        Text(isAddingPhotos
                             ? String(localized: "正在添加…")
                             : String(localized: "添加 \(selectedPhotoIDs.count) 张照片"))
                            .font(.system(size: 16, weight: .semibold))
                    }
                    .foregroundStyle(AppTheme.primaryControlForeground(colorScheme))
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(AppTheme.primaryControlBackground(colorScheme), in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(isAddingPhotos)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
        }
        .dynamicTypeSize(.large)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .task { await recent.load() }
    }

    // MARK: - Sources

    @ViewBuilder
    private var attachmentSources: some View {
        if CameraPicker.isAvailable || !recent.items.isEmpty || recent.isLoading {
            // The camera card is the first item of the same horizontal strip:
            // the whole row (camera + photos) scrolls together, as official.
            ScrollView(.horizontal) {
                HStack(spacing: 12) {
                    if CameraPicker.isAvailable {
                        cameraTile
                    }
                    if recent.isLoading && recent.items.isEmpty {
                        // Official's `.loading` state fills the strip with
                        // placeholders instead of collapsing it to the camera.
                        ForEach(Array(0..<min(max(maxPhotoSelection, 0), 3)), id: \.self) { _ in
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(AppTheme.composerControlFill(colorScheme))
                                .frame(width: 95, height: tile)
                                .accessibilityHidden(true)
                        }
                    }
                    ForEach(recent.items) { photo in
                        Button {
                            togglePhoto(photo.id)
                        } label: {
                            ZStack {
                                AppTheme.composerControlFill(colorScheme)
                                if let thumbnail = photo.thumbnail {
                                    Image(uiImage: thumbnail)
                                        .resizable()
                                        .scaledToFill()
                                }
                            }
                            .frame(width: 95, height: tile)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .overlay(alignment: .topTrailing) {
                                if selectedPhotoIDs.contains(photo.id) {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundStyle(Color(white: 0.10))
                                        .frame(width: 22, height: 22)
                                        .background(Circle().fill(.white))
                                        .padding(6)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(String(localized: "最近照片"))
                        .accessibilityAddTraits(selectedPhotoIDs.contains(photo.id) ? .isSelected : [])
                    }
                }
                .padding(.trailing, 16)
            }
            .scrollIndicators(.hidden)
            .disabled(!canAttach)
            .frame(height: tile)
        }
    }

    private func togglePhoto(_ id: String) {
        if selectedPhotoIDs.contains(id) {
            selectedPhotoIDs.remove(id)
        } else if selectedPhotoIDs.count < max(0, maxPhotoSelection) {
            selectedPhotoIDs.insert(id)
        }
    }

    private func addSelectedPhotos() {
        guard !isAddingPhotos else { return }
        let picked = recent.items.filter { selectedPhotoIDs.contains($0.id) }
        guard !picked.isEmpty else { return }
        isAddingPhotos = true
        Task {
            var payloads: [Data] = []
            for photo in picked {
                if let data = await recent.imageData(for: photo) { payloads.append(data) }
            }
            isAddingPhotos = false
            selectedPhotoIDs.removeAll()
            guard !payloads.isEmpty else { return }
            onRecentPhotos(payloads)
            dismiss()
        }
    }

    private var cameraTile: some View {
        Button(action: onCamera) {
            VStack(spacing: 6) {
                AppSymbol("anthropicon.camera", size: 20)
                Text(String(localized: "相机"))
                    .font(.system(size: 14))
            }
            .foregroundStyle(AppTheme.composerSecondaryGlyph(colorScheme))
            .frame(width: tile, height: tile)
            .background(AppTheme.composerControlFill(colorScheme),
                        in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!canAttach)
        .accessibilityLabel(String(localized: "相机"))
    }

    // MARK: - Rows

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content().background(AppTheme.composerTileBackground(colorScheme), in: cardShape)
    }

    private func row(icon: String, title: String, value: String?, enabled: Bool,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                AppSymbol(icon, size: 19)
                    .frame(width: 28)
                    .foregroundStyle(AppTheme.composerRowIcon(colorScheme))
                Text(title).font(.system(size: 15))
                Spacer(minLength: 8)
                if let value {
                    Text(value).font(.system(size: 15))
                        .lineLimit(1)
                        .foregroundStyle(AppTheme.composerSecondaryGlyph(colorScheme))
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AppTheme.composerSecondaryGlyph(colorScheme))
            }
            .foregroundStyle(AppTheme.composerControlGlyph(colorScheme))
            .padding(.horizontal, 16)
            .padding(.vertical, ChatSheetMetrics.rowVerticalPadding)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
    }

    @ViewBuilder
    private var takeoverCard: some View {
        if let chat = sessionChat, let meta = chat.session.metadata {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(isOn: Binding(get: { meta.takeover }, set: { pendingTakeover = $0 })) {
                    HStack(spacing: 12) {
                        AppSymbol("anthropicon.hand", size: 19)
                            .frame(width: 28)
                            .foregroundStyle(AppTheme.composerRowIcon(colorScheme))
                        Text(String(localized: "接管会话"))
                            .font(.system(size: 15))
                            .foregroundStyle(AppTheme.composerControlGlyph(colorScheme))
                    }
                }
                .toggleStyle(.switch)
                .tint(AppTheme.primaryControlBackground(colorScheme))
                .disabled(!chat.canChangeTakeover)
                Text(meta.takeover
                     ? String(localized: "已开启，可从 Agents Anywhere 继续操作。")
                     : String(localized: "只读模式，开启接管后可以继续发送消息。"))
                    .font(.system(size: 12))
                    .foregroundStyle(AppTheme.composerSecondaryGlyph(colorScheme))
                if let error = chat.takeoverError {
                    Text(error).font(.system(size: 12)).foregroundStyle(AppTheme.composerSecondaryGlyph(colorScheme))
                }
                if chat.takeoverUncertain || !chat.session.runtime.isFresh {
                    Button(String(localized: "刷新接管状态")) { Task { await chat.refreshTakeover() } }
                        .font(.system(size: 12))
                        .disabled(chat.isWorking || chat.session.network.availability == .offline)
                }
            }
            .padding(16)
            .background(AppTheme.composerTileBackground(colorScheme), in: cardShape)
        }
    }

    // MARK: - Permissions

    private var permissionsPage: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(Array(settings.catalog.permissions.enumerated()), id: \.element.id) { index, option in
                    if index > 0 {
                        Divider().padding(.leading, 48)
                    }
                    Button {
                        apply { settings.selectPermission(option.id) }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(AppTheme.pickerCheckmark(colorScheme))
                                .frame(width: 20)
                                .opacity(settings.permissionID == option.id ? 1 : 0)
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
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(String(localized: "权限"))
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(AppTheme.composerControlGlyph(colorScheme))
            }
        }
    }

    private func apply(_ selection: () -> Bool) {
        guard !isApplying, selection() else { return }
        isApplying = true
        Task { @MainActor in
            let accepted = await onApply()
            isApplying = false
            if accepted { dismiss() } else { showsApplyError = true }
        }
    }
}

import PhotosUI
import SwiftUI

struct AvatarSettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    @Binding var draft: AccountAvatarDraft
    @State private var localError: String?

    var body: some View {
        SettingsScreen(title: String(localized: "Profile photo")) {
            SettingsSection {
                SettingsRowContainer(verticalPadding: 16) {
                    AvatarEditorPreview(
                        displayName: appState.me?.accountLabel ?? "?",
                        currentSource: appState.accountAvatarSource,
                        selectedImage: draft.selectedImage,
                        zoom: $draft.zoom,
                        offset: $draft.offset
                    )
                    .frame(maxWidth: .infinity)
                }
            }

            SettingsSection {
                PhotosPicker(selection: $draft.selectedItem, matching: .images) {
                    HStack(spacing: SettingsStyle.iconGap) {
                        AppSymbol("photo.on.rectangle", size: 18)
                            .frame(width: SettingsStyle.iconFrame)
                            .foregroundStyle(SettingsStyle.icon(colorScheme))
                        Text(String(localized: "Choose photo"))
                            .font(.system(size: 17))
                            .foregroundStyle(SettingsStyle.ink(colorScheme))
                        Spacer(minLength: 8)
                    }
                    .padding(.horizontal, SettingsStyle.rowPadding)
                    .padding(.vertical, 12)
                    .frame(minHeight: SettingsStyle.rowMinHeight)
                    .contentShape(Rectangle())
                }
                if draft.selectedImage != nil {
                    SettingsRowDivider()
                    SettingsRowContainer(verticalPadding: 14) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(String(localized: "Zoom"))
                                .font(.subheadline)
                                .foregroundStyle(SettingsStyle.ink(colorScheme))
                            Slider(value: $draft.zoom, in: 1 ... 3)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

            if appState.me?.avatar != nil {
                SettingsSection {
                    Button(role: .destructive, action: removeAvatar) {
                        HStack(spacing: SettingsStyle.iconGap) {
                            AppSymbol("trash", size: 18)
                                .frame(width: SettingsStyle.iconFrame)
                            Text(String(localized: "Remove profile photo"))
                                .font(.system(size: 17))
                            Spacer(minLength: 0)
                        }
                        .foregroundStyle(.red)
                        .padding(.horizontal, SettingsStyle.rowPadding)
                        .padding(.vertical, 12)
                        .frame(minHeight: SettingsStyle.rowMinHeight)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(appState.isAccountWorking)
                }
            }
        }
        .toolbar {
            SheetSaveToolbar(isWorking: appState.isAccountWorking, saveDisabled: draft.selectedImage == nil, onSave: uploadAvatar)
        }
        .disabled(appState.isAccountWorking)
        .onChange(of: draft.selectedItem) { _, nextItem in
            guard let nextItem else { return }
            Task { await loadImage(nextItem) }
        }
        .onChange(of: draft.zoom) { _, nextZoom in
            guard let selectedImage = draft.selectedImage else { return }
            draft.offset = AccountAvatarProcessor.clampedOffset(
                image: selectedImage,
                zoom: nextZoom,
                candidate: draft.offset
            )
        }
        .alert(String(localized: "Could not use photo"), isPresented: localErrorBinding) {
            Button(String(localized: "OK"), role: .cancel) {
                localError = nil
            }
        } message: {
            Text(localError ?? "")
        }
    }

    private var localErrorBinding: Binding<Bool> {
        Binding(
            get: { localError != nil },
            set: { isPresented in
                if !isPresented { localError = nil }
            }
        )
    }

    private func loadImage(_ item: PhotosPickerItem) async {
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                throw AccountAvatarProcessingError.invalidImage
            }
            guard draft.selectedItem == item else { return }
            draft.selectedImage = try AccountAvatarProcessor.image(from: data)
            draft.zoom = 1
            draft.offset = .zero
            localError = nil
        } catch {
            guard draft.selectedItem == item else { return }
            draft.selectedImage = nil
            localError = error.localizedDescription
        }
    }

    private func uploadAvatar() {
        guard let selectedImage = draft.selectedImage else { return }
        do {
            let dataURL = try AccountAvatarProcessor.dataURL(
                image: selectedImage,
                zoom: draft.zoom,
                offset: draft.offset
            )
            Task {
                if await appState.updateAccountAvatar(dataURL: dataURL) {
                    draft = AccountAvatarDraft()
                    dismiss()
                }
            }
        } catch {
            localError = error.localizedDescription
        }
    }

    private func removeAvatar() {
        Task {
            if await appState.clearAccountAvatar() {
                draft = AccountAvatarDraft()
            }
        }
    }
}

private struct AvatarEditorPreview: View {
    let displayName: String
    let currentSource: AccountAvatarImageSource?
    let selectedImage: UIImage?
    @Binding var zoom: CGFloat
    @Binding var offset: CGSize

    @GestureState private var dragTranslation = CGSize.zero

    var body: some View {
        if let selectedImage {
            Image(uiImage: selectedImage)
                .resizable()
                .scaledToFill()
                .frame(
                    width: AccountAvatarProcessor.outputSize,
                    height: AccountAvatarProcessor.outputSize
                )
                .scaleEffect(zoom)
                .offset(displayOffset(image: selectedImage))
                .frame(
                    width: AccountAvatarProcessor.outputSize,
                    height: AccountAvatarProcessor.outputSize
                )
                .clipShape(Circle())
                .overlay {
                    Circle()
                        .strokeBorder(.white.opacity(0.9), lineWidth: 2)
                }
                .contentShape(Circle())
                .gesture(dragGesture(image: selectedImage))
        } else {
            AccountAvatarView(
                displayName: displayName,
                source: currentSource,
                size: AccountAvatarProcessor.outputSize
            )
        }
    }

    private func displayOffset(image: UIImage) -> CGSize {
        AccountAvatarProcessor.clampedOffset(
            image: image,
            zoom: zoom,
            candidate: CGSize(
                width: offset.width + dragTranslation.width,
                height: offset.height + dragTranslation.height
            )
        )
    }

    private func dragGesture(image: UIImage) -> some Gesture {
        DragGesture()
            .updating($dragTranslation) { value, state, _ in
                state = value.translation
            }
            .onEnded { value in
                offset = AccountAvatarProcessor.clampedOffset(
                    image: image,
                    zoom: zoom,
                    candidate: CGSize(
                        width: offset.width + value.translation.width,
                        height: offset.height + value.translation.height
                    )
                )
            }
    }
}

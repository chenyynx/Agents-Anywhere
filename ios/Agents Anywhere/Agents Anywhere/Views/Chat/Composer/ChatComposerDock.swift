import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// Both New Session and existing sessions use the same persistent editor and
/// picker hosts. Only the commit action and capability facts differ.
struct ChatComposerDock: View {
    @Bindable var draft: ComposerDraft
    let settings: ConversationSettings
    let maximumEditorHeight: CGFloat
    let controls: ChatControlMetrics
    var canSend = true
    var canAttach = true
    var canSelectModel = true
    var canSelectPermission = true
    var isStreaming = false
    var canStop = true
    var isBusy = false
    var placeholder = String(localized: "询问 Agents")
    var isLoadingSettings = false
    var settingsError: String?
    var sessionChat: SessionChatModel?
    /// Session context-window state for the composer ring; `.hidden` hides it.
    var contextUsage: ContextRingState = .hidden
    let onSend: (String) async -> Void
    var onStop: () async -> Void = {}
    var onLoadSettings: () async -> Void = {}
    var onApplySettings: () async -> Bool = { true }
    var applyError: () -> String? = { nil }
    var onDraftChange: () -> Void = {}
    /// Whether a running turn's send key may enqueue (queue capability).
    var canQueueSend = true
    /// Increments once per successful enqueue; drives the light-impact haptic.
    var queueEnqueueTick = 0
    var onQueueSend: () async -> Void = {}

    @State private var editor = ComposerEditorController()
    @State private var showsOptions = false
    @State private var pendingPicker: AttachmentPicker?
    @State private var picker: AttachmentPicker?
    @State private var photos: [PhotosPickerItem] = []
    @State private var attachmentError: String?
    @State private var isSending = false
    @State private var importCount = 0
    @State private var showsCommandMenu = false
    @Environment(\.displayScale) private var displayScale

    private enum AttachmentPicker { case photos, files }

    /// Which control the trailing slot shows, and whether it is live. Resolved
    /// by the shared pure function (`ComposerQueueAffordance`) so the branch —
    /// queueing implies streaming, which the earlier inline order got wrong —
    /// is owned by one tested source instead of a view-local re-derivation.
    private var affordance: ComposerQueueAffordance {
        ComposerQueueAffordance.resolve(
            isStreaming: isStreaming,
            hasText: !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            canQueue: canQueueSend,
            canStop: canStop,
            canSend: canSend && draft.canAttemptSend)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let sessionChat {
                CommandSuggestionPanel(chat: sessionChat, draft: draft, forced: $showsCommandMenu)
            }
            ChatComposer(draft: draft, editor: editor, isStreaming: isStreaming,
                canSend: canSend, canStop: canStop, isBusy: isBusy || isSending || importCount > 0,
                placeholder: placeholder,
                maximumEditorHeight: maximumEditorHeight, controls: controls,
                onSend: send, onStop: { Task { await onStop() } },
                onOptions: { showsOptions = true },
                showsCommands: sessionChat?.offersCommands == true, commandsActive: showsCommandMenu,
                onCommands: { showsCommandMenu.toggle() },
                contextUsage: contextUsage,
                onDraftChange: onDraftChange,
                affordance: affordance, onQueueSend: send)
                .contentShape(Rectangle())
                // K2 (round 1.1): the composer band owns vertical drags across
                // its whole frame — including the transparent margins around
                // the glass bar — so a swipe here can never fall through to
                // the timeline's interactive dismissal. Inner controls, the
                // editor and the command panel keep their own interactions.
                .composerKeyboardGesture(draft: draft, editor: editor)
        }
        .onChange(of: sessionChat?.optionsRequest) { _, _ in showsOptions = true }
        .frame(maxWidth: ChatControlMetrics.maximumContentWidth)
        .frame(maxWidth: .infinity)
        .background {
            ZStack {
                Color.clear.photosPicker(isPresented: pickerBinding(.photos), selection: $photos,
                    maxSelectionCount: max(1, 5 - draft.attachments.count), matching: .images)
                Color.clear.fileImporter(isPresented: pickerBinding(.files), allowedContentTypes: [.item],
                    allowsMultipleSelection: true, onCompletion: importFiles)
            }
        }
        .sheet(isPresented: $showsOptions, onDismiss: presentPicker) {
            ComposerOptionsSheet(settings: settings,
                onPhotos: { queue(.photos) }, onFiles: { queue(.files) },
                canAttach: canAttach && draft.attachments.count < 5 && importCount == 0,
                canSelectModel: canSelectModel, canSelectPermission: canSelectPermission,
                isLoading: isLoadingSettings, loadingError: settingsError,
                onReload: onLoadSettings, onApply: onApplySettings, applyError: applyError, sessionChat: sessionChat)
                .task(id: "\(canSelectModel):\(canSelectPermission)") { await onLoadSettings() }
        }
        .onChange(of: photos) { _, items in importPhotos(items) }
        .onDisappear {
            editor.finishEditing()
            draft.isFocused = false
        }
        // One light impact per successful enqueue, accounted by the caller.
        .sensoryFeedback(.impact(weight: .light, intensity: 1), trigger: queueEnqueueTick)
        .alert(String(localized: "无法添加附件"), isPresented: Binding(get: { attachmentError != nil }, set: { if !$0 { attachmentError = nil } })) {
            Button(String(localized: "好"), role: .cancel) { attachmentError = nil }
        } message: { Text(attachmentError ?? "") }
    }

    /// Commit the editor's text, then route it: a running turn enqueues, an idle
    /// turn sends. The single entry point keeps a mid-commit frame from
    /// straddling the boundary — whichever turn state the commit settled into
    /// decides the action.
    private func send() {
        guard !isSending, !isBusy, importCount == 0 else { return }
        // Commit follows the affordance the bar is showing: the textless stop
        // form has nothing to commit, and each live form carries its own gate.
        guard affordance.shape != .stop, affordance.isActionEnabled else { return }
        isSending = true
        // A send ends the editing session (the keyboard drops so the reply is
        // visible); an enqueue keeps it, because the queue is fed in a row.
        let dismissKeyboard = affordance.shape != .queueSend
        Task { @MainActor in
            defer { isSending = false }
            guard let text = await editor.committedTextForSend(dismissKeyboard: dismissKeyboard) else { return }
            if isStreaming { await onQueueSend() } else { await onSend(text) }
        }
    }

    private func queue(_ next: AttachmentPicker) { pendingPicker = next; showsOptions = false }
    private func presentPicker() {
        guard let next = pendingPicker else { return }
        pendingPicker = nil; picker = next
    }
    private func pickerBinding(_ value: AttachmentPicker) -> Binding<Bool> {
        Binding(get: { picker == value }, set: { if $0 { picker = value } else if picker == value { picker = nil } })
    }

    private func append(name: String, data: Data, mediaType: String) async {
        guard draft.isValid else { return }
        guard draft.attachments.count < 5 else { attachmentError = String(localized: "每条消息最多添加 5 个附件。"); return }
        guard !data.isEmpty else { attachmentError = String(localized: "文件为空。"); return }
        guard data.count <= 25 * 1024 * 1024 else { attachmentError = String(localized: "单个附件请控制在 25 MiB 以内。"); return }
        let previewMaxPixelSize = ChatImageThumbnail.maximumPixelSize(
            for: CGSize(width: ChatImageThumbnail.maximumBubbleWidth, height: ChatImageThumbnail.maximumBubbleHeight),
            displayScale: displayScale)
        // One decode pass produces both the preview and the original pixel
        // dimensions that travel with the upload as attachment metadata.
        let imageInfo: (preview: Data?, pixelSize: CGSize?) = mediaType.hasPrefix("image/")
            ? await Task.detached(priority: .utility) {
                (ChatImageThumbnail.make(data: data, maxPixelSize: previewMaxPixelSize),
                    ChatImageThumbnail.imageSize(data: data))
            }.value : (nil, nil)
        guard draft.isValid, draft.attachments.count < 5 else { return }
        draft.attachments.append(ChatAttachment(name: name, data: data, mediaType: mediaType,
            previewData: imageInfo.preview, pixelSize: imageInfo.pixelSize))
    }

    private func importPhotos(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        importCount += 1
        Task { @MainActor in
            defer { importCount -= 1; photos = [] }
            for item in items {
                do {
                    guard let data = try await item.loadTransferable(type: Data.self) else { continue }
                    let type = item.supportedContentTypes.first ?? .jpeg
                    await append(name: "Photo-\(UUID().uuidString.prefix(8)).\(type.preferredFilenameExtension ?? "jpg")",
                           data: data, mediaType: type.preferredMIMEType ?? "image/jpeg")
                } catch { attachmentError = error.localizedDescription }
            }
        }
    }

    private func importFiles(_ result: Result<[URL], Error>) {
        do {
            let urls = try result.get()
            importCount += 1
            Task { @MainActor in
                defer { importCount -= 1 }
                for url in urls.prefix(5) {
                    do {
                        let file = try await Task.detached(priority: .userInitiated) { try ImportedChatFile.read(url) }.value
                        await append(name: file.name, data: file.data, mediaType: file.mediaType)
                    } catch { attachmentError = error.localizedDescription }
                }
                if urls.count > 5 { attachmentError = String(localized: "每条消息最多添加 5 个附件。") }
            }
        } catch { attachmentError = error.localizedDescription }
    }
}

nonisolated private struct ImportedChatFile: Sendable {
    let name: String
    let data: Data
    let mediaType: String

    static func read(_ url: URL) throws -> Self {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        // Bound the read even when the document provider has no file-size metadata.
        let data = try handle.read(upToCount: 25 * 1024 * 1024 + 1) ?? Data()
        let type = try url.resourceValues(forKeys: [.contentTypeKey]).contentType
        return Self(name: url.lastPathComponent, data: data, mediaType: type?.preferredMIMEType ?? "application/octet-stream")
    }
}

import SwiftUI
import PhotosUI
import UIKit
import UniformTypeIdentifiers

/// Both New Session and existing sessions use the same persistent editor and
/// picker hosts. Only the commit action and capability facts differ.
struct ChatComposerDock: View {
    @Bindable var draft: ComposerDraft
    let settings: ConversationSettings
    let maximumEditorHeight: CGFloat
    let controls: ChatControlMetrics
    let editor: ComposerEditorController
    @Binding var showsCommandMenu: Bool
    var canSend = true
    var canAttach = true
    /// Delivery classification for long pastes. `.unknown` (offline, not yet
    /// fresh, new session preparing) still produces a local file card; only a
    /// fresh "does not support attachments" falls back to measuring text.
    var attachmentDelivery: AttachmentDelivery = .unknown
    var canSelectModel = true
    var canSelectPermission = true
    var isStreaming = false
    var canStop = true
    var isBusy = false
    /// The new-session host leaves this at the official "type or hold to
    /// talk" line; a session with history passes its own reply wording.
    var placeholder = String(localized: "输入或长按说话")
    var isLoadingSettings = false
    var settingsError: String?
    var sessionChat: SessionChatModel?
    let onSend: (String) async -> Void
    var onStop: () async -> Void = {}
    var onLoadSettings: () async -> Void = {}
    var onApplySettings: () async -> Bool = { true }
    var applyError: () -> String? = { nil }
    var onDraftChange: () -> Void = {}
    /// Whether a running turn's send key may enqueue (queue capability).
    var canQueueSend = true
    /// Whether the running turn can take this draft as a steering message —
    /// text always, attachments only when the runtime declares its steer path
    /// accepts them (`session.steer.parameters.attachments`).
    var canSteerSend = false
    /// Increments once per successful enqueue; drives the light-impact haptic.
    var queueEnqueueTick = 0
    var onQueueSend: () async -> Void = {}
    var onSteerSend: () async -> Void = {}
    /// One persisted choice, shared with the settings row and the send key's
    /// long-press menu.
    @AppStorage(ComposerDeliverySetting.storageKey) private var deliveryRaw =
        ComposerDeliverySetting.defaultValue.rawValue
    private var delivery: ComposerDelivery {
        ComposerDeliverySetting.resolve(deliveryRaw)
    }
    private var midTurnAction: MidTurnDeliveryAction {
        ComposerDeliverySetting.midTurnAction(
            delivery, canSteer: canSteerSend, canQueue: canQueueSend)
    }

    @State private var showsOptions = false
    @State private var pendingPicker: AttachmentPicker?
    @State private var picker: AttachmentPicker?
    @State private var photos: [PhotosPickerItem] = []
    @State private var attachmentError: String?
    @State private var speechError: String?
    @State private var isSending = false
    @State private var importCount = 0
    @State private var showsCamera = false
    @State private var pendingCamera = false
    @State private var editingAttachment: ChatAttachment?
    @StateObject private var dictation = VoiceDictationController()
    @State private var dictating = false
    @State private var dictationBase = ""
    @State private var pendingDictationSend = false
    @Environment(\.displayScale) private var displayScale
    @Environment(RecentPhotosLoader.self) private var recentPhotos: RecentPhotosLoader?

    private enum AttachmentPicker { case photos, files }

    /// Which control the trailing slot shows, and whether it is live. Resolved
    /// by the shared pure function (`ComposerQueueAffordance`) so the branch —
    /// queueing implies streaming, which the earlier inline order got wrong —
    /// is owned by one tested source instead of a view-local re-derivation.
    private var affordance: ComposerQueueAffordance {
        ComposerQueueAffordance.resolve(
            isStreaming: isStreaming,
            hasCommittableContent: midTurnAction == .steer
                ? draft.hasSendableContent
                : !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            // Enabled exactly when the tap has an action (see `midTurnAction`).
            canQueue: midTurnAction != .unavailable,
            canStop: canStop,
            canSend: canSend && draft.canAttemptSend)
    }

    var body: some View {
        VStack(spacing: 0) {
            ChatComposer(draft: draft, editor: editor, isStreaming: isStreaming,
                canSend: canSend, isBusy: isBusy || isSending || importCount > 0,
                placeholder: speechError ?? placeholder,
                maximumEditorHeight: maximumEditorHeight, controls: controls,
                onSend: send, onStop: { Task { await onStop() } },
                onOptions: presentOptions,
                showsCommands: sessionChat?.offersCommands == true, commandsActive: showsCommandMenu,
                onCommands: { showsCommandMenu.toggle() },
                onVoice: startDictation,
                isDictating: dictating,
                isTranscribing: dictation.isTranscribing,
                dictationAmplitude: dictation.amplitude,
                onVoiceCancel: cancelDictation,
                onVoiceFinish: finishDictation,
                onVoiceSend: sendDictation,
                onDraftChange: onDraftChange,
                onLongPaste: convertLongPastedText,
                onEditorLimitReached: {
                    attachmentError = String(localized: "内容过长，请分段输入或添加为文件。")
                },
                onOversizedDraft: repairOversizedDraft,
                onEditAttachment: presentImageEditor,
                affordance: affordance, onQueueSend: send)
                .contentShape(Rectangle())
                // K2 (round 1.1): the composer band owns vertical drags across
                // its whole frame — including the transparent margins around
                // the glass bar — so a swipe here can never fall through to
                // the timeline's interactive dismissal. Inner controls, the
                // editor and the command panel keep their own interactions.
                .composerKeyboardGesture(draft: draft, editor: editor)
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: dictating)
        .onChange(of: dictation.status) { _, status in
            switch status {
            case .denied:
                dictating = false
                speechError = String(localized: "需要麦克风与语音识别权限")
            case .failed(let message):
                dictating = false
                speechError = message
            case .idle, .starting, .recording:
                break
            }
        }
        .onChange(of: draft.text) { _, _ in
            if speechError != nil { speechError = nil }
        }
        .onChange(of: dictation.isTranscribing) { _, transcribing in
            if !transcribing, dictating, !dictation.isRecording {
                dictating = false
            }
        }
        .onChange(of: dictating) { _, isDictating in
            if !isDictating, pendingDictationSend {
                pendingDictationSend = false
                DispatchQueue.main.async { send() }
            }
        }
        .onDisappear { dictation.stop() }
        .onChange(of: sessionChat?.optionsRequest) { _, _ in presentOptions() }
        // The add-to-chat rows (permission/model) read from `settings`, which
        // only the catalog load fills; load once when the composer appears.
        .task(id: "\(canSelectModel):\(canSelectPermission)") { await onLoadSettings() }
        // Warm the photo strip as soon as a chat screen appears, so the first
        // add-to-chat sheet opens on already-resolved assets. `preload` never
        // asks for permission, so this cannot prompt outside the sheet.
        .task { await recentPhotos?.preload() }
        .frame(maxWidth: ChatControlMetrics.maximumContentWidth)
        .frame(maxWidth: .infinity)
        .background {
            ZStack {
                Color.clear.photosPicker(isPresented: pickerBinding(.photos), selection: $photos,
                    maxSelectionCount: max(1, LongMessageAttachmentPolicy.maximumAttachments
                        - draft.attachments.count), matching: .images)
                Color.clear.fileImporter(isPresented: pickerBinding(.files), allowedContentTypes: [.item],
                    allowsMultipleSelection: true, onCompletion: importFiles)
            }
        }
        .sheet(isPresented: $showsOptions, onDismiss: presentPicker) {
            AddToChatSheet(settings: settings,
                onPhotos: { queue(.photos) }, onFiles: { queue(.files) },
                onCamera: { pendingCamera = true; showsOptions = false },
                onRecentPhotos: { payloads in
                    Task {
                        for data in payloads {
                            await append(name: "Photo-\(UUID().uuidString.prefix(8)).jpg",
                                         data: data, mediaType: "image/jpeg")
                        }
                    }
                },
                maxPhotoSelection: max(0, LongMessageAttachmentPolicy.maximumAttachments
                    - draft.attachments.count),
                canAttach: canAttach
                    && draft.attachments.count < LongMessageAttachmentPolicy.maximumAttachments
                    && importCount == 0,
                canSelectModel: canSelectModel,
                canSelectPermission: canSelectPermission,
                isLoading: isLoadingSettings, loadingError: settingsError,
                onReload: onLoadSettings, onApply: onApplySettings, applyError: applyError, sessionChat: sessionChat)
                .task(id: "\(canSelectModel):\(canSelectPermission)") { await onLoadSettings() }
        }
        .fullScreenCover(isPresented: $showsCamera) {
            CameraPicker { image in
                appendCamera(image)
            }
            .ignoresSafeArea()
        }
        .fullScreenCover(item: $editingAttachment) { attachment in
            ComposerImageEditor(attachment: attachment, onSave: replaceEditedAttachment)
        }
        .onChange(of: photos) { _, items in importPhotos(items) }
        .onDisappear {
            editor.finishEditing()
            draft.isFocused = false
        }
        // No enqueue-specific haptic: the official send key fires `.selection`
        // once on the tap, and the haptic table has no "queued" entry
        // (CANONICAL/11-motion-haptics.md §2.4). The previous impact() made a
        // queue tap vibrate twice.
        .sensoryFeedback(.selection, trigger: queueEnqueueTick) { _, _ in false }
        .alert(String(localized: "无法添加附件"), isPresented: Binding(get: { attachmentError != nil }, set: { if !$0 { attachmentError = nil } })) {
            Button(String(localized: "好"), role: .cancel) { attachmentError = nil }
        } message: { Text(attachmentError ?? "") }
    }

    // MARK: - Live dictation

    private func startDictation() {
        guard !dictating else { return }
        speechError = nil
        dictationBase = draft.text
        dictating = true
        dictation.onPartial = { text in
            draft.text = dictationBase + text
        }
        dictation.onAutoFinish = {
            dictating = false
        }
        dictation.start()
    }

    private func cancelDictation() {
        dictation.cancel()
        draft.text = dictationBase
        dictating = false
    }

    private func finishDictation() {
        // Keep the card up while the final transcript lands ("正在转写…").
        dictation.stop()
    }

    private func sendDictation() {
        dictation.stop()
        pendingDictationSend = true
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
            if isStreaming {
                switch ComposerDeliverySetting.midTurnAction(
                    delivery, canSteer: canSteerSend, canQueue: canQueueSend) {
                case .steer: await onSteerSend()
                case .queue: await onQueueSend()
                case .unavailable: break
                }
            } else {
                await onSend(text)
            }
        }
    }

    /// A sheet cannot own the keyboard that belongs to the composer behind it;
    /// resign first or the keyboard stays up over the add-to-chat menu (and can
    /// survive the sheet's dismissal).
    private func presentOptions() {
        editor.finishEditing()
        draft.isFocused = false
        showsOptions = true
    }

    private func presentImageEditor(_ attachment: ChatAttachment) {
        editor.finishEditing()
        draft.isFocused = false
        editingAttachment = attachment
    }

    private func queue(_ next: AttachmentPicker) { pendingPicker = next; showsOptions = false }
    private func presentPicker() {
        if pendingCamera {
            pendingCamera = false
            showsCamera = true
            return
        }
        guard let next = pendingPicker else { return }
        pendingPicker = nil; picker = next
    }
    private func pickerBinding(_ value: AttachmentPicker) -> Binding<Bool> {
        Binding(get: { picker == value }, set: { if $0 { picker = value } else if picker == value { picker = nil } })
    }

    /// A long paste becomes an ordinary `.txt` attachment at paste time, so the
    /// editor never measures the log and its file card appears before send.
    /// `true` means the paste is consumed either way: converted, or refused
    /// with an error — the raw text must never fall through to the editor.
    private func convertLongPastedText(_ text: String) -> Bool {
        switch LongMessageAttachmentPolicy.decidePaste(
            text,
            existingAttachmentCount: draft.attachments.count,
            delivery: attachmentDelivery) {
        case .insert:
            return false
        case .attachment:
            guard let attachment = LongMessageAttachmentPolicy.makeAttachment(
                from: text,
                existingAttachmentCount: draft.attachments.count) else {
                // A slot raced away between the decision and the card: refuse
                // the paste, never fall through to TextKit with the raw log.
                attachmentError = String(localized: "内容过长，无法粘贴。请分段粘贴或添加为文件。")
                return true
            }
            draft.attachments.append(attachment)
            onDraftChange()
            ClientDiagnosticsLog.shared.record(kind: "composer.paste", detail: [
                "result": "attachment",
                "characters": String(text.count),
                "attachments": String(draft.attachments.count),
                "delivery": attachmentDelivery.diagnosticName,
            ], dedupe: false)
            return true
        case .refused:
            attachmentError = String(localized: "内容过长，无法粘贴。请分段粘贴或添加为文件。")
            ClientDiagnosticsLog.shared.record(kind: "composer.paste", detail: [
                "result": "refused",
                "characters": String(text.count),
                "attachments": String(draft.attachments.count),
                "delivery": attachmentDelivery.diagnosticName,
            ], dedupe: false)
            return true
        }
    }

    /// Last line of defence for a draft that reached the model without passing
    /// the paste gates (older build, another entry point). Runs off the view
    /// update pass and repairs the model, so the editor never gets the string.
    private func repairOversizedDraft() {
        let text = draft.text
        guard LongMessageAttachmentPolicy.exceedsEditorLimit(text) else { return }
        let repaired = LongMessageAttachmentPolicy.sanitizeRestoredDraft(
            text, existingAttachmentCount: draft.attachments.count)
        draft.text = repaired.text
        if let attachment = repaired.attachment { draft.attachments.append(attachment) }
        onDraftChange()
        ClientDiagnosticsLog.shared.record(kind: "composer.draft.repair", detail: [
            "characters": String(text.count),
            "keptText": String(repaired.text.count),
            "attachment": repaired.attachment == nil ? "no" : "yes",
        ], dedupe: false)
    }

    private func replaceEditedAttachment(_ updated: ChatAttachment) {
        guard let index = draft.attachments.firstIndex(where: { $0.id == updated.id }) else { return }
        draft.attachments[index] = updated
        onDraftChange()
    }

    private func appendCamera(_ image: UIImage) {
        guard let data = image.jpegData(compressionQuality: 0.9) else { return }
        Task {
            await append(name: "Photo-\(UUID().uuidString.prefix(8)).jpg",
                         data: data, mediaType: "image/jpeg")
        }
    }

    private func append(name: String, data: Data, mediaType: String) async {
        guard draft.isValid else { return }
        guard draft.attachments.count < LongMessageAttachmentPolicy.maximumAttachments else {
            attachmentError = String(localized: "每条消息最多添加 9 个附件。"); return
        }
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
        guard draft.isValid,
              draft.attachments.count < LongMessageAttachmentPolicy.maximumAttachments else { return }
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
                let remaining = max(0, LongMessageAttachmentPolicy.maximumAttachments
                    - draft.attachments.count)
                for url in urls.prefix(remaining) {
                    do {
                        let file = try await Task.detached(priority: .userInitiated) { try ImportedChatFile.read(url) }.value
                        await append(name: file.name, data: file.data, mediaType: file.mediaType)
                    } catch { attachmentError = error.localizedDescription }
                }
                if urls.count > remaining {
                    attachmentError = String(localized: "每条消息最多添加 9 个附件。")
                }
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

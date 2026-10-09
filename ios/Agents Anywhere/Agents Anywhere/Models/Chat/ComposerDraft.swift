import Foundation
import Observation

nonisolated struct ChatAttachment: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let data: Data
    let mediaType: String
    let previewData: Data?
    /// Original image pixel dimensions decoded when the picker produced the
    /// preview (EXIF orientation corrected); nil for non-images and undecodable
    /// selections.
    let pixelSize: CGSize?
    var uploaded: V2AttachmentReference?

    init(id: String = UUID().uuidString, name: String, data: Data, mediaType: String,
         previewData: Data? = nil, pixelSize: CGSize? = nil) {
        self.id = id; self.name = name; self.data = data; self.mediaType = mediaType
        self.previewData = previewData
        self.pixelSize = pixelSize
    }

    var isImage: Bool { mediaType.hasPrefix("image/") }
    @MainActor var local: V2LocalAttachment {
        let dimensions = ChatImageThumbnail.pixelDimensions(for: pixelSize)
        return V2LocalAttachment(fileId: id, name: name, mediaType: mediaType, data: data, sha256: nil,
            pixelWidth: dimensions?.width, pixelHeight: dimensions?.height)
    }
}

/// The editor owns marked-text state; the account/session owns the draft lifetime.
@MainActor @Observable
final class ComposerDraft {
    private(set) var isValid = true
    var text = ""
    var attachments: [ChatAttachment] = []
    var isComposing = false

    /// True while the editor is the first responder. Written only by the
    /// editor's delegate — the authoritative native fact, never a guess.
    private(set) var isFocused = false

    /// The focus the app wants, with a monotonic token. `updateUIView` drives
    /// the text view toward it and only a delegate report bearing the newest
    /// token may write `isFocused`, so a resigned focus can never be revived by
    /// a stale `becomeFirstResponder` — and the field it feeds can never latch
    /// on. Not persisted: it lives and dies with the session.
    private(set) var focusIntent = false
    private(set) var focusToken = 0

    var hasContent: Bool { ComposerExpansion.hasContent(text) }
    var hasSendableContent: Bool { hasContent || !attachments.isEmpty }
    var canAttemptSend: Bool { !isComposing && hasSendableContent }

    /// Derived from the live draft every time it is read; never stored.
    var isExpanded: Bool {
        ComposerExpansion.isExpanded(isFocused: isFocused, attachmentCount: attachments.count, text: text)
    }

    /// Records the desired focus. The token advances on every change so a
    /// delegate callback from before this point cannot overwrite the result.
    @discardableResult
    func setFocusIntent(_ focused: Bool) -> Int {
        focusIntent = focused
        focusToken &+= 1
        return focusToken
    }

    /// Applies a delegate's first-responder report. Only the newest intent's
    /// report counts; a late callback from a superseded focus is dropped.
    func reportFocus(_ responder: Bool, token: Int) {
        guard token == focusToken else { return }
        isFocused = responder
    }

    func clear() { text = ""; attachments = []; isComposing = false }
    func invalidate() { clear(); focusIntent = false; focusToken &+= 1; isFocused = false; isValid = false }
}

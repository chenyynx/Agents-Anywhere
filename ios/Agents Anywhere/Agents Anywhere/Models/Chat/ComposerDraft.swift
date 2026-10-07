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
    var isFocused = false
    var isComposing = false

    var isExpanded: Bool { isFocused || !text.isEmpty || !attachments.isEmpty }
    var hasSendableContent: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty }
    var canAttemptSend: Bool { !isComposing && hasSendableContent }

    func clear() { text = ""; attachments = []; isComposing = false }
    func invalidate() { clear(); isFocused = false; isValid = false }
}

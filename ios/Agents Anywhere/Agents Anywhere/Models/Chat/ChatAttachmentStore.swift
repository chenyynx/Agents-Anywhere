import Foundation
import Observation

struct ChatMessageAttachment: Identifiable, Equatable {
    let id: String
    let content: V2AttachmentContent
    let previewData: Data?
    let previewPixelSize: CGSize?
    /// Advances whenever this cache writes - or evicts - the preview bytes, so
    /// an image whose load failed can re-run its task when a preview arrives.
    let previewVersion: Int
}

/// Session/account-scoped metadata and small previews survive the optimistic
/// bubble's replacement. Full uploaded files are never retained in this cache.
@MainActor @Observable final class ChatAttachmentStore {
    @Observable fileprivate final class Entry {
        var content: V2AttachmentContent?
        private(set) var previewData: Data?
        var previewPixelSize: CGSize?
        private(set) var previewVersion = 0

        /// The one write path for preview bytes; every write advances the
        /// version observed by the image views.
        func setPreview(_ data: Data?) {
            previewData = data
            previewVersion += 1
        }
    }
    @ObservationIgnored private var entries: [String: Entry] = [:]
    @ObservationIgnored private var order: [String] = []
    @ObservationIgnored private var sent: [String: [V2AttachmentContent]] = [:]
    @ObservationIgnored private var sentOrder: [String] = []
    @ObservationIgnored private let byteLimit: Int
    init(byteLimit: Int = 16 * 1024 * 1024) { self.byteLimit = byteLimit }

    func remember(_ attachments: [ChatAttachment], clientID: String) {
        let contents = attachments.map(\.content)
        sent[clientID] = contents
        sentOrder.removeAll { $0 == clientID }; sentOrder.append(clientID)
        while sentOrder.count > 128 { sent.removeValue(forKey: sentOrder.removeFirst()) }
        for (attachment, content) in zip(attachments, contents) {
            let value = entry(content.cacheKey)
            value.content = content
            value.setPreview(attachment.previewData)
            value.previewPixelSize = attachment.previewData.flatMap(ChatImageThumbnail.imageSize(data:))
        }
        trim()
    }

    func resolve(_ contents: [V2AttachmentContent], clientID: String? = nil) -> [ChatMessageAttachment] {
        let fallback = clientID.flatMap { sent[$0] } ?? []
        return (contents.isEmpty ? fallback : contents).enumerated().map { index, content in
            // Correlate by file ID; reordered files must never inherit the wrong image.
            let saved = content.fileId.flatMap { entries[$0]?.content }
                ?? entries[content.cacheKey]?.content ?? fallback.first { $0.fileId == content.fileId && content.fileId != nil }
            let merged = saved.map { content.fillingMissingMetadata(from: $0) } ?? content
            let value = entry(merged.cacheKey)
            if value.previewPixelSize == nil, let data = value.previewData {
                value.previewPixelSize = ChatImageThumbnail.imageSize(data: data)
            }
            return ChatMessageAttachment(id: content.fileId ?? "attachment:\(index):\(content.cacheKey)",
                content: merged, previewData: value.previewData, previewPixelSize: value.previewPixelSize,
                previewVersion: value.previewVersion)
        }
    }

    func preview(for file: V2AttachmentContent) -> Data? { entry(file.cacheKey).previewData }
    func cache(_ data: Data, for file: V2AttachmentContent) {
        guard data.count <= byteLimit else { return }
        let value = entry(file.cacheKey); value.content = file; value.setPreview(data)
        value.previewPixelSize = ChatImageThumbnail.imageSize(data: data)
        trim()
    }
    nonisolated struct Archive: Codable {
        struct Item: Codable {
            let content: JSONValue?
            let preview: Data?
            let key: String
            let previewWidth: Double?
            let previewHeight: Double?
        }
        let items: [Item]
        let sent: [String: [JSONValue]]
    }
    func archived() -> Archive {
        let items: [Archive.Item] = order.compactMap { key -> Archive.Item? in
            guard let entry = entries[key] else { return nil }
            return Archive.Item(content: entry.content?.raw, preview: entry.previewData, key: key,
                previewWidth: entry.previewPixelSize.map { Double($0.width) },
                previewHeight: entry.previewPixelSize.map { Double($0.height) })
        }
        return Archive(items: items, sent: sent.mapValues { $0.map(\.raw) })
    }
    func restore(_ value: Archive) {
        for item in value.items {
            let content = item.content.map(V2AttachmentContent.init(rawContent:))
            let entry = entry(content?.cacheKey ?? item.key)
            entry.content = content; entry.setPreview(item.preview)
            entry.previewPixelSize = item.preview.flatMap(ChatImageThumbnail.imageSize(data:))
                ?? restoredSize(width: item.previewWidth, height: item.previewHeight)
        }
        sent = value.sent.mapValues { $0.map(V2AttachmentContent.init(rawContent:)) }
        sentOrder = Array(sent.keys); trim()
    }
    private func restoredSize(width: Double?, height: Double?) -> CGSize? {
        guard let width, let height, width.isFinite, height.isFinite, width > 0, height > 0 else { return nil }
        return CGSize(width: CGFloat(width), height: CGFloat(height))
    }
    func clear() { entries = [:]; order = []; sent = [:]; sentOrder = [] }
    private func entry(_ key: String) -> Entry {
        order.removeAll { $0 == key }; order.append(key)
        if let value = entries[key] { return value }
        let value = Entry(); entries[key] = value
        while order.count > 256 { entries.removeValue(forKey: order.removeFirst()) }
        return value
    }
    private func trim() {
        var bytes = entries.values.reduce(0) { $0 + ($1.previewData?.count ?? 0) }
        for key in order where bytes > byteLimit {
            if let value = entries[key], let data = value.previewData { bytes -= data.count; value.setPreview(nil) }
        }
    }
}

extension V2AttachmentContent {
    var devicePath: String? { raw["path"]?.stringValue ?? raw["filePath"]?.stringValue }
    var root: String? { raw["root"]?.stringValue }
    var readsFromDevice: Bool {
        devicePath != nil && fileId?.hasPrefix("file_") != true
            && raw["optimistic"] != .bool(true) && openUrl == nil && downloadUrl == nil
    }
    var isImage: Bool {
        if mediaType?.hasPrefix("image/") == true { return true }
        let suffix = ((name ?? devicePath ?? "") as NSString).pathExtension.lowercased()
        return ["png", "jpg", "jpeg", "heic", "heif", "gif", "webp", "tiff", "bmp"].contains(suffix)
    }
    var cacheKey: String { readsFromDevice ? "fs:\(root ?? ""):\(devicePath ?? ""):\(raw.hashValue)" : fileId ?? "raw:\(raw.hashValue)" }
    func fillingMissingMetadata(from local: V2AttachmentContent) -> V2AttachmentContent {
        guard case var .object(fields) = local.raw, case let .object(server) = raw else { return self }
        for (key, value) in server where value != .null { fields[key] = value }
        return V2AttachmentContent(rawContent: .object(fields))
    }
}

extension ChatAttachment {
    var content: V2AttachmentContent {
        var fields: [String: JSONValue] = ["fileId": .string(uploaded?.fileId ?? "local:\(id)"),
            "name": .string(uploaded?.name ?? name), "mediaType": .string(uploaded?.mediaType ?? mediaType),
            "size": .number(Double(uploaded?.size ?? data.count))]
        if let uploaded { fields["openUrl"] = .string(uploaded.openUrl); fields["downloadUrl"] = .string(uploaded.downloadUrl) }
        // Report the original pixel dimensions locally, in the same wire shape
        // the server echoes back, so the optimistic bubble is sized before the
        // authoritative attachment payload arrives.
        if let dimensions = ChatImageThumbnail.pixelDimensions(for: pixelSize) {
            fields["width"] = .number(Double(dimensions.width)); fields["height"] = .number(Double(dimensions.height))
        }
        return V2AttachmentContent(rawContent: .object(fields))
    }
}

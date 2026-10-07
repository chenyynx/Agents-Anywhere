import Foundation

nonisolated struct V2AttachmentReference: Codable, Identifiable, Hashable {
    let fileId: V2AttachmentID
    let sessionId: V2SessionID
    let name: String
    let mediaType: String
    let size: Int
    /// Original image pixel dimensions, EXIF orientation corrected. Optional:
    /// older servers omit them and non-image attachments may never have them.
    var width: Int? = nil
    var height: Int? = nil
    let sha256: String
    let createdAt: String
    let downloadUrl: String
    let openUrl: String

    var id: V2AttachmentID { fileId }
}

struct V2AttachmentDownload: Decodable, Hashable {
    let fileId: V2AttachmentID
    let sessionId: V2SessionID
    let path: String
    let name: String
    let size: Int
    let sha256: String
    let contentBase64: String
    let createdAt: String
    let serverTime: String
}

struct V2AttachmentContent: Hashable {
    let fileId: V2AttachmentID?
    let name: String?
    let mediaType: String?
    let size: Int?
    let openUrl: String?
    let downloadUrl: String?
    let raw: JSONValue

    nonisolated init(rawContent: JSONValue) {
        fileId = rawContent["fileId"]?.stringValue ?? rawContent["id"]?.stringValue
        name = rawContent["name"]?.stringValue
        mediaType = rawContent["mediaType"]?.stringValue ?? rawContent["mimeType"]?.stringValue
        size = rawContent["size"]?.v2IntValue
        openUrl = rawContent["openUrl"]?.stringValue
        downloadUrl = rawContent["downloadUrl"]?.stringValue
        raw = rawContent
    }

    /// Original image pixel dimensions reported by the server (`width`/`height`
    /// in the attachment payload, EXIF orientation corrected) — never a display
    /// size; each surface maps them to its own clamped layout. Only positive
    /// whole numbers qualify; anything else falls back to local decoding.
    var serverPixelSize: CGSize? {
        guard let width = raw["width"]?.v2PositivePixelValue,
              let height = raw["height"]?.v2PositivePixelValue else { return nil }
        return CGSize(width: CGFloat(width), height: CGFloat(height))
    }
}

struct V2AttachmentUploadResponse: Decodable, Hashable {
    let attachments: [V2AttachmentReference]
    let serverTime: String
}

private extension JSONValue {
    nonisolated var v2IntValue: Int? {
        switch self {
        case let .number(value):
            return Int(value)
        case let .string(value):
            return Int(value)
        default:
            return nil
        }
    }

    /// Positive whole number for image pixel dimensions. Strings, booleans,
    /// fractional, zero and negative values do not qualify.
    nonisolated var v2PositivePixelValue: Int? {
        guard case let .number(value) = self, value.isFinite, value > 0,
              let int = Int(exactly: value) else { return nil }
        return int
    }
}

/// create-and-start returns timeline attachment metadata, not the upload DTO.
struct V2CreatedAttachment: Codable, Hashable {
    let fileId: String
    let name: String
    let mediaType: String
    let size: Int
    let sha256: String

    func reference(sessionID: String) -> V2AttachmentReference {
        // These are the same session-scoped routes returned by the upload API.
        let path = "/api/v2/sessions/" + sessionID.v2URLPathComponentEncoded + "/attachments/" + fileId.v2URLPathComponentEncoded
        return .init(fileId: fileId, sessionId: sessionID, name: name, mediaType: mediaType, size: size,
            sha256: sha256, createdAt: "", downloadUrl: path, openUrl: path + "/open")
    }
}

import Foundation

struct V2AttachmentService {
    let attachmentAPI: any V2AttachmentAPIProtocol
    /// Streams the raw byte route. Kept a separate dependency so existing call
    /// sites (and their stubs) that only upload/download JSON are unaffected;
    /// the image path wires the real transport in production.
    let transport: (any HTTPTransport)?

    /// `transport` defaults to nil so the existing JSON-only call sites and
    /// their stubs keep compiling unchanged; `downloadFile` requires it.
    init(attachmentAPI: any V2AttachmentAPIProtocol, transport: (any HTTPTransport)? = nil) {
        self.attachmentAPI = attachmentAPI
        self.transport = transport
    }

    /// Uploads user-selected bytes to the server's session-scoped attachment store.
    func upload(
        sessionId: V2SessionID,
        attachments: [V2LocalAttachment]
    ) async throws -> [V2AttachmentReference] {
        if attachments.isEmpty { throw V2BusinessError.emptyAttachmentSelection }
        if attachments.count > 5 {
            throw V2BusinessError.tooManyAttachments(maximum: 5)
        }
        let files = try attachments.map { attachment in
            if attachment.data.isEmpty {
                throw V2BusinessError.emptyAttachment(name: attachment.name)
            }
            if attachment.data.count > 25 * 1024 * 1024 { throw V2BusinessError.attachmentTooLarge(name: attachment.name) }
            return HTTPUploadFile(
                fieldName: "files",
                fileName: attachment.name,
                mediaType: attachment.mediaType,
                data: attachment.data,
                pixelWidth: attachment.pixelWidth,
                pixelHeight: attachment.pixelHeight
            )
        }
        return try await attachmentAPI.upload(sessionId: sessionId, files: files).attachments
    }

    func download(sessionId: V2SessionID, fileId: V2AttachmentID) async throws -> Data {
        let response = try await attachmentAPI.download(sessionId: sessionId, fileId: fileId)
        guard let data = Data(base64Encoded: response.contentBase64) else {
            throw HTTPError.decoding(message: String(localized: "The attachment content is not valid Base64 data."))
        }
        return data
    }

    /// Streams the original bytes to a temporary file over the raw byte route
    /// (`/open`), skipping the base64 JSON envelope the `download` path uses.
    /// The transport applies the same-origin check, bearer token, same-origin
    /// redirect follow and streaming-to-disk that workspace downloads already
    /// use, so a large image never lands in memory whole.
    func downloadFile(openUrl: String) async throws -> URL {
        guard let transport else { throw HTTPError.invalidResponse }
        guard let url = URL(string: openUrl) else {
            throw HTTPError.invalidRequestURL(path: openUrl)
        }
        return try await transport.download(url)
    }
}

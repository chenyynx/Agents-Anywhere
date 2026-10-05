import Foundation

struct V2RuntimeMessageSendRequest: Encodable, Hashable {
    let content: String
    let attachments: [V2AttachmentSendReference]
    let clientMessageId: String?
}

struct V2AttachmentSendReference: Encodable, Hashable {
    let fileId: V2AttachmentID
}

/// Optional body of `POST …/runtime/interrupt`. `preserveBackground` asks the
/// runtime to spare running background work while it stops the current turn
/// (the model-switch flow); the default is the historical all-stop semantics,
/// so a server that does not know the field is unaffected.
struct V2RuntimeInterruptRequest: Encodable, Hashable {
    let preserveBackground: Bool
}

struct V2RuntimeActionResponse: Decodable, Hashable {
    let ok: Bool
    let result: JSONValue?
    let error: V2RuntimeError?

    @discardableResult
    func requireSuccess() throws -> Self {
        guard ok else {
            throw error ?? V2RuntimeError(code: nil, message: String(localized: "The runtime did not accept this operation."))
        }
        return self
    }
}

struct V2RuntimeCommand: Decodable, Identifiable, Hashable {
    let id: String
    let title: String
    let description: String?
    let aliases: [String]
    let category: String?
    let scope: String
    let enabled: Bool
    let disabledReason: String?
    let acceptsArgs: Bool?
    let argsSchema: JSONValue?
    let metadata: JSONValue?
}

struct V2RuntimeCommandListResponse: Decodable, Hashable {
    let commands: [V2RuntimeCommand]
    let serverTime: String?
}

struct V2RuntimeCommandExecuteRequest: Encodable, Hashable {
    let command: String
    let args: [String]
    let raw: String?
}

struct V2RuntimeCommandExecuteResponse: Decodable, Hashable {
    let command: String?
    let ok: Bool
    let code: String?
    let message: String?
    let result: JSONValue?
    let session: V2SessionMeta?
    let serverTime: String
}

struct V2RuntimeSteerRequest: Encodable, Hashable {
    let content: String
    let attachments: [V2AttachmentSendReference]
    let clientMessageId: String?
}

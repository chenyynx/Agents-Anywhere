import Foundation

enum V2TimelineItemType: String, Codable, Hashable {
    case turnStart = "turn.start"
    case turnEnd = "turn.end"
    case message
    case reasoning
    case tool
    case fileChange = "file_change"
    case marker
    case artifact
    case attachment
    case system
    case unknown
}

enum V2TimelineItemStatus: String, Codable, Hashable {
    case pending
    case running
    case waitingApproval = "waiting_approval"
    case done
    case failed
    case cancelled
    case interrupted
    case hidden
    case unknown
}

enum V2MessageRole: String, Codable, Hashable {
    case user
    case assistant
    case system
    case tool
    case unknown
}

struct V2TimelineItem: Decodable, Identifiable, Hashable {
    /// Preserve extension fields and unknown wire kinds for diagnostic exports.
    let raw: JSONValue
    let id: V2TimelineItemID
    let sessionId: V2SessionID
    let turnId: V2TurnID?
    let type: V2TimelineItemType
    let status: V2TimelineItemStatus
    let role: V2MessageRole?
    let content: V2TimelineItemContent
    let source: JSONValue
    let orderSeq: Int
    let revision: Int
    let contentHash: String
    let updatedSeq: Int
    let createdAt: String
    let updatedAt: String
    let completedAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case sessionId
        case turnId
        case type
        case status
        case role
        case content
        case source
        case orderSeq
        case revision
        case contentHash
        case updatedSeq
        case createdAt
        case updatedAt
        case completedAt
    }

    init(from decoder: Decoder) throws {
        raw = try JSONValue(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(V2TimelineItemID.self, forKey: .id)
        sessionId = try container.decode(V2SessionID.self, forKey: .sessionId)
        turnId = try container.decodeIfPresent(V2TurnID.self, forKey: .turnId)
        let rawType = try container.decodeIfPresent(String.self, forKey: .type) ?? V2TimelineItemType.unknown.rawValue
        type = V2TimelineItemType(rawValue: rawType) ?? .unknown
        let rawStatus = try container.decodeIfPresent(String.self, forKey: .status) ?? V2TimelineItemStatus.unknown.rawValue
        status = V2TimelineItemStatus(rawValue: rawStatus) ?? .unknown
        if let rawRole = try container.decodeIfPresent(String.self, forKey: .role) {
            role = V2MessageRole(rawValue: rawRole) ?? .unknown
        } else {
            role = nil
        }
        let rawContent = try container.decodeIfPresent(JSONValue.self, forKey: .content) ?? .object([:])
        content = V2TimelineItemContent(type: type, rawContent: rawContent)
        source = try container.decodeIfPresent(JSONValue.self, forKey: .source) ?? .object([:])
        orderSeq = try container.decodeIfPresent(Int.self, forKey: .orderSeq)
            ?? container.decodeIfPresent(Int.self, forKey: .updatedSeq)
            ?? 0
        revision = try container.decodeIfPresent(Int.self, forKey: .revision) ?? 1
        contentHash = try container.decodeIfPresent(String.self, forKey: .contentHash) ?? ""
        updatedSeq = try container.decodeIfPresent(Int.self, forKey: .updatedSeq) ?? 0
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
        updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt) ?? createdAt
        completedAt = try container.decodeIfPresent(String.self, forKey: .completedAt)
    }

    /// The projection's single ordering rule for two versions of one row: a
    /// newer revision wins, and an equal revision is broken by the newer durable
    /// sequence. Every reader of "is this the newer copy?" goes through here so
    /// the timeline window and the active-card sidecar cannot disagree.
    func supersedes(_ other: V2TimelineItem) -> Bool {
        revision > other.revision || (revision == other.revision && updatedSeq >= other.updatedSeq)
    }
}

enum V2TimelineItemContent: Hashable {
    case message(V2MessageContent)
    case reasoning(V2ReasoningContent)
    case tool(V2ToolContent)
    case fileChange(V2FileChangeContent)
    case marker(V2MarkerContent)
    case artifact(V2ArtifactContent)
    case attachment(V2AttachmentContent)
    case unknown(JSONValue)

    init(type: V2TimelineItemType, rawContent: JSONValue) {
        switch type {
        case .turnStart, .turnEnd, .system:
            self = .marker(V2MarkerContent(rawContent: rawContent))
        case .message:
            self = .message(V2MessageContent(rawContent: rawContent))
        case .reasoning:
            self = .reasoning(V2ReasoningContent(rawContent: rawContent))
        case .tool:
            self = .tool(V2ToolContent(rawContent: rawContent))
        case .fileChange:
            self = .fileChange(V2FileChangeContent(rawContent: rawContent))
        case .marker:
            self = .marker(V2MarkerContent(rawContent: rawContent))
        case .artifact:
            self = .artifact(V2ArtifactContent(rawContent: rawContent))
        case .attachment:
            self = .attachment(V2AttachmentContent(rawContent: rawContent))
        case .unknown:
            self = .unknown(rawContent)
        }
    }
}

struct V2MessageContent: Hashable {
    let text: String
    let format: String?
    let attachments: [V2AttachmentContent]
    let raw: JSONValue

    init(rawContent: JSONValue) {
        text = ["text", "content", "message", "rawText"].compactMap { rawContent[$0]?.stringValue }.first { !$0.isEmpty } ?? ""
        format = rawContent["format"]?.stringValue
        attachments = rawContent["attachments"]?.arrayValue?.map(V2AttachmentContent.init(rawContent:)) ?? []
        raw = rawContent
    }
}

/// Per-API-call token usage the connector attaches to a timeline item's
/// content (context-usage-ring §1.1): camelCase counters, not a turn total.
struct V2MessageUsage: Hashable {
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let cacheCreationTokens: Int

    var contextTokens: Int { inputTokens + outputTokens + cacheReadTokens + cacheCreationTokens }
}

extension V2MessageUsage {
    /// A missing sub-key reads 0 (the wire omits absent counters); a present
    /// value that is not a whole number invalidates the whole object, so a
    /// malformed frame never shows a partly-guessed count. The key name
    /// `usage` is not ours alone — an agent-call card carries subagent totals
    /// (`tokens` / `toolCalls` / `durationMs`) under it — so the object must
    /// hold at least one of this shape's counters; anything else is rejected
    /// rather than read as a zeroed context.
    init?(rawValue: JSONValue) {
        guard let object = rawValue.objectValue else { return nil }
        let knownKeys = ["inputTokens", "outputTokens", "cacheReadTokens", "cacheCreationTokens"]
        guard knownKeys.contains(where: { object[$0] != nil }) else { return nil }
        func count(_ key: String) -> Int? {
            guard let value = object[key] else { return 0 }
            return value.intValue
        }
        guard let inputTokens = count("inputTokens"), let outputTokens = count("outputTokens"),
              let cacheReadTokens = count("cacheReadTokens"), let cacheCreationTokens = count("cacheCreationTokens")
        else { return nil }
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheCreationTokens = cacheCreationTokens
    }
}

extension V2MessageContent {
    /// The usage block, when this message carries one — other runtimes and
    /// pre-feature history omit it.
    var usage: V2MessageUsage? { raw["usage"].flatMap(V2MessageUsage.init(rawValue:)) }
}

extension V2TimelineItemContent {
    /// The raw wire content of whichever carrier kind this is — the shared
    /// source for fields the connector may stamp on any item kind.
    var raw: JSONValue {
        switch self {
        case let .message(value): value.raw
        case let .reasoning(value): value.raw
        case let .tool(value): value.raw
        case let .fileChange(value): value.raw
        case let .marker(value): value.raw
        case let .artifact(value): value.raw
        case let .attachment(value): value.raw
        case let .unknown(value): value
        }
    }
}

extension V2TimelineItem {
    /// The per-call usage block in this item's content, wherever the
    /// connector attached it. The ring reads the newest item that has one,
    /// and every carrier kind qualifies: the connector stamps the latest API
    /// call's usage on the message, reasoning and tool items of the turn
    /// alike, so the value follows the newest item, not the newest message.
    var usage: V2MessageUsage? { content.raw["usage"].flatMap(V2MessageUsage.init(rawValue:)) }
}

struct V2ReasoningContent: Hashable {
    let text: String
    let summary: String?
    let raw: JSONValue

    init(rawContent: JSONValue) {
        text = rawContent["text"]?.stringValue ?? ""
        summary = rawContent["summary"]?.stringValue
        raw = rawContent
    }
}

struct V2ToolContent: Hashable {
    let name: String?
    let input: JSONValue?
    let output: JSONValue?
    let raw: JSONValue

    init(rawContent: JSONValue) {
        name = rawContent["name"]?.stringValue ?? rawContent["toolName"]?.stringValue
        input = rawContent["input"]
        output = rawContent["output"]
        raw = rawContent
    }
}

struct V2FileChangeContent: Hashable {
    let path: String?
    let action: String?
    let patch: String?
    let changes: [JSONValue]
    let raw: JSONValue

    init(rawContent: JSONValue) {
        path = rawContent["path"]?.stringValue
        action = rawContent["action"]?.stringValue
        patch = rawContent["patch"]?.stringValue
        changes = rawContent["changes"]?.arrayValue ?? []
        raw = rawContent
    }
}

struct V2MarkerContent: Hashable {
    let title: String
    let subtitle: String?
    let variant: String?
    let raw: JSONValue

    init(rawContent: JSONValue) {
        title = rawContent["title"]?.stringValue ?? rawContent["text"]?.stringValue ?? "Event"
        subtitle = rawContent["subtitle"]?.stringValue ?? rawContent["description"]?.stringValue
        variant = rawContent["variant"]?.stringValue
        raw = rawContent
    }
}

struct V2ArtifactContent: Hashable {
    let title: String?
    let mediaType: String?
    let url: String?
    let raw: JSONValue

    init(rawContent: JSONValue) {
        title = rawContent["title"]?.stringValue ?? rawContent["name"]?.stringValue
        mediaType = rawContent["mediaType"]?.stringValue ?? rawContent["mimeType"]?.stringValue
        url = rawContent["url"]?.stringValue ?? rawContent["openUrl"]?.stringValue
        raw = rawContent
    }
}

extension JSONValue {
    nonisolated var arrayValue: [JSONValue]? {
        if case let .array(value) = self {
            return value
        }
        return nil
    }
}

import Foundation

// The wire model for one timeline row. Decoding is deliberately lenient for
// every field EXCEPT the three that anchor a row's identity and order —
// ``id``, ``sessionId`` and ``orderSeq`` are required and a row missing any of
// them fails to decode (and is dropped by the lossy array reader, never
// retried with a substituted value).
//
// ``orderSeq`` in particular is the ONLY ordering truth any client sorts on.
// It must never be approximated from another field: ``updatedSeq`` is a
// revision counter that runs the OPPOSITE way for a message's reasoning rows
// (an intra-message repack gives the reasoning row a higher ``updatedSeq`` than
// its body), so any fallback to it re-creates the exact "reasoning below its
// body" defect the server's v2_42 fix removed (2026-10-14). A missing
// ``orderSeq`` means the row is dropped rather than shown in the wrong place.
//
// TODO(clients): this iOS decoder no longer guesses an orderSeq, but the other
// clients still do — Web/Desktop accept it unvalidated (`payload as T`) and
// their comparator `a.orderSeq - b.orderSeq || a.updatedSeq - …` turns a
// missing orderSeq into `NaN` and falls through to `updatedSeq` (the same
// revision-counter fallback this file forbids); Android reads
// `optInt("orderSeq", 0)` then rewrites `<= 0` to `maxOrderSeq + 1` (row pushed
// to the end). Both silently mis-place a row the contract says must carry
// `orderSeq`. Align them to "required / never guessed" later; tracked in
// docs/api/realtime.md ("Client behaviour on a malformed row") and
// .local-dev/aa-backlog.md.
nonisolated enum V2TimelineItemType: String, Codable, Hashable {
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

nonisolated enum V2TimelineItemStatus: String, Codable, Hashable {
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

nonisolated enum V2MessageRole: String, Codable, Hashable {
    case user
    case assistant
    case system
    case tool
    case unknown
}

nonisolated struct V2TimelineItem: Decodable, Identifiable, Hashable {
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
    /// Chat text for this item version: the message body without attachment
    /// markers, or the joined reasoning summaries. Derived once per decode so
    /// presentation ticks never rescan every reply.
    let displayText: String

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
        try self.init(json: JSONValue(from: decoder))
    }

    /// Builds an item from an already parsed wire tree. `content` and `source`
    /// share that tree's storage; nothing is re-encoded or parsed twice.
    init(json raw: JSONValue) throws {
        guard case .object = raw else {
            throw DecodingError.typeMismatch(Self.self, .init(codingPath: [], debugDescription: "Timeline item must be an object."))
        }
        func required(_ key: CodingKeys) throws -> String {
            guard let value = raw[key.rawValue]?.stringValue else {
                throw DecodingError.keyNotFound(key, .init(codingPath: [], debugDescription: "Missing '\(key.rawValue)' in timeline item."))
            }
            return value
        }
        self.raw = raw
        id = try required(.id)
        sessionId = try required(.sessionId)
        turnId = raw["turnId"]?.stringValue
        type = raw["type"]?.stringValue.flatMap(V2TimelineItemType.init(rawValue:)) ?? .unknown
        status = raw["status"]?.stringValue.flatMap(V2TimelineItemStatus.init(rawValue:)) ?? .unknown
        role = raw["role"]?.stringValue.map { V2MessageRole(rawValue: $0) ?? .unknown }
        let rawContent = raw["content"].flatMap { $0 == .null ? nil : $0 } ?? .object([:])
        content = V2TimelineItemContent(type: type, rawContent: rawContent)
        source = raw["source"].flatMap { $0 == .null ? nil : $0 } ?? .object([:])
        // Required, never approximated: a row without orderSeq fails to decode
        // and the lossy array reader drops it instead of placing it wrong. It is
        // never derived from updatedSeq — that revision counter runs the opposite
        // way for a message's reasoning rows, so a fallback re-creates the exact
        // "reasoning below its body" defect the server's v2_42 fix removed.
        // (see the file header; expected form is Int, like the rest of the wire.)
        guard let orderSeqValue = raw["orderSeq"]?.intValue else {
            throw DecodingError.keyNotFound(CodingKeys.orderSeq, .init(codingPath: [],
                debugDescription: "Missing 'orderSeq' in timeline item."))
        }
        orderSeq = orderSeqValue
        revision = raw["revision"]?.intValue ?? 1
        contentHash = raw["contentHash"]?.stringValue ?? ""
        updatedSeq = raw["updatedSeq"]?.intValue ?? 0
        createdAt = raw["createdAt"]?.stringValue ?? ""
        updatedAt = raw["updatedAt"]?.stringValue ?? createdAt
        completedAt = raw["completedAt"]?.stringValue
        let reasoning = type == .reasoning || type == .system && rawContent["kind"] == .string("reasoning")
        switch content {
        case let .message(value): displayText = TimelineText.message(value.text)
        case let .reasoning(value): displayText = TimelineText.reasoning(value.raw)
        case let .marker(value): displayText = reasoning ? TimelineText.reasoning(value.raw) : ""
        default: displayText = ""
        }
    }

    /// Identity fields reject a changed item before any tree walk. Unchanged
    /// items carried between projections share their wire tree's storage, so
    /// the final `raw` comparison is an identity check rather than a deep walk.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.revision == rhs.revision && lhs.updatedSeq == rhs.updatedSeq
            && lhs.contentHash == rhs.contentHash && lhs.status == rhs.status && lhs.orderSeq == rhs.orderSeq
            && lhs.raw == rhs.raw
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(revision)
        hasher.combine(updatedSeq)
        hasher.combine(contentHash)
    }

    /// The projection's single ordering rule for two versions of one row: a
    /// newer revision wins, and an equal revision is broken by the newer durable
    /// sequence. Every reader of "is this the newer copy?" goes through here so
    /// the timeline window and the active-card sidecar cannot disagree.
    func supersedes(_ other: V2TimelineItem) -> Bool {
        revision > other.revision || (revision == other.revision && updatedSeq >= other.updatedSeq)
    }
}

nonisolated enum V2TimelineItemContent: Hashable {
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

nonisolated struct V2MessageContent: Hashable {
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
/// The engine's self-reported `model` and `contextWindow` ride along when the
/// connector knows them (§8 v3), so the ring's window travels with the
/// measurement that produced it instead of being inferred from the session's
/// nominal catalog entry.
struct V2MessageUsage: Hashable {
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let cacheCreationTokens: Int
    /// The engine's self-reported model id — nil when unreported.
    let model: String?
    /// The engine's self-reported context window — nil when unreported.
    let contextWindow: Int?

    init(inputTokens: Int, outputTokens: Int, cacheReadTokens: Int, cacheCreationTokens: Int,
         model: String? = nil, contextWindow: Int? = nil) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.model = model
        self.contextWindow = contextWindow
    }

    var contextTokens: Int { inputTokens + outputTokens + cacheReadTokens + cacheCreationTokens }
}

extension V2MessageUsage {
    /// A missing sub-key reads 0 (the wire omits absent counters); a present
    /// value that is not a whole number invalidates the whole object, so a
    /// malformed frame never shows a partly-guessed count. The key name
    /// `usage` is not ours alone — an agent-call card carries subagent totals
    /// (`tokens` / `toolCalls` / `durationMs`) under it — so the object must
    /// hold at least one of this shape's counters; anything else is rejected
    /// rather than read as a zeroed context. The engine-stamped `model` and
    /// `contextWindow` neither satisfy that gate nor break it: a missing or
    /// malformed value reads nil for that field alone, counters intact.
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
        // Strict `.string` — `JSONValue.stringValue` also stringifies numbers
        // and bools, and an empty id names no model — and strict `intValue`,
        // which only accepts whole numbers.
        if case let .string(value)? = object["model"], !value.isEmpty {
            model = value
        } else {
            model = nil
        }
        contextWindow = object["contextWindow"]?.intValue
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

nonisolated struct V2ReasoningContent: Hashable {
    let text: String
    let summary: String?
    let raw: JSONValue

    init(rawContent: JSONValue) {
        text = rawContent["text"]?.stringValue ?? ""
        summary = rawContent["summary"]?.stringValue
        raw = rawContent
    }
}

nonisolated struct V2ToolContent: Hashable {
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

nonisolated struct V2FileChangeContent: Hashable {
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

nonisolated struct V2MarkerContent: Hashable {
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

nonisolated struct V2ArtifactContent: Hashable {
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

nonisolated extension JSONValue {
    nonisolated var arrayValue: [JSONValue]? {
        if case let .array(value) = self {
            return value
        }
        return nil
    }
}

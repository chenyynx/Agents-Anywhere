import Foundation

nonisolated enum V2TimelineMode: String {
    case latest
    case changes
    case history
}

nonisolated struct V2SessionTimelinePage: Decodable, Hashable {
    let sessionId: V2SessionID
    let items: [V2TimelineItem]
    let nextSeq: Int
    let hasMore: Bool
    let serverTime: String?
    /// Whether the server applied the `excludeAgentChildren` opt-in to this
    /// page. A pre-field server cannot say, so an absent key reads `false`:
    /// the client must keep its own fallback for child-only windows.
    var excludesAgentChildren = false
}

extension V2SessionTimelinePage {
    /// One history page. A row *inside* `items` that fails to decode (e.g. a
    /// server that dropped a required field) is dropped, never failing the
    /// page. The `items` key itself stays required and must be an array: a
    /// missing key or a non-array is a contract violation and still throws, as
    /// it always did — only the elements are read lossily. Declared in an
    /// extension so the synthesized memberwise initializer survives.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try container.decode(V2SessionID.self, forKey: .sessionId)
        items = try container.decode(LossyElements<V2TimelineItem>.self, forKey: .items).elements
        nextSeq = try container.decode(Int.self, forKey: .nextSeq)
        hasMore = try container.decode(Bool.self, forKey: .hasMore)
        serverTime = try container.decodeIfPresent(String.self, forKey: .serverTime)
        excludesAgentChildren = try container.decodeIfPresent(Bool.self, forKey: .excludesAgentChildren) ?? false
    }

    private enum CodingKeys: String, CodingKey {
        case sessionId
        case items
        case nextSeq
        case hasMore
        case serverTime
        case excludesAgentChildren
    }
}

nonisolated struct V2SessionSnapshot: Decodable, Hashable {
    let session: V2SessionMeta
    let state: V2RuntimeState?
    let timeline: V2TimelineSnapshot
    let approvals: [V2Approval]
    let notices: [V2RuntimeNotice]
    let effectiveCapabilities: V2RuntimeCapabilitySnapshot
    let runtimeCapabilities: V2RuntimeCapabilitySnapshot
    let catalogs: [String: JSONValue]
    let eventCursor: String
    let serverTime: String
    /// The session's active top-level SubAgent cards as the server sees them
    /// (session-open-coverage P1): every non-terminal `agent_call` card —
    /// inside the timeline window or not — with its usage stats, so a cold
    /// open can build the capsule before any card frame arrives. Defaulted so
    /// archive rebuilds and pre-field servers keep constructing exactly as
    /// before; decoding is lenient (see the extension below).
    var activeAgents: [V2TimelineItem] = []
    /// Whether the server applied the `excludeAgentChildren` opt-in to this
    /// snapshot. Same rule as the timeline page: an absent key (老服务端) reads
    /// `false`, which keeps the C0 fallback in charge of child-only windows.
    var excludesAgentChildren = false

    /// A custom `init(from:)` suppresses the synthesized keys, so they are
    /// spelled out (the `V2TimelineItem` convention).
    enum CodingKeys: String, CodingKey {
        case session
        case state
        case timeline
        case approvals
        case notices
        case effectiveCapabilities
        case runtimeCapabilities
        case catalogs
        case eventCursor
        case serverTime
        case activeAgents
        case excludesAgentChildren
    }
}

extension V2SessionSnapshot {
    /// Defensive decode in the `V2TimelineItem` style. The item collections —
    /// `timeline.items` and `activeAgents` — are lossy: one row/card that fails
    /// to decode is dropped instead of failing the whole snapshot, and an absent
    /// `activeAgents` key (老服务端) reads `[]`. Every other field keeps exactly
    /// its previous requirement.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        session = try container.decode(V2SessionMeta.self, forKey: .session)
        state = try container.decodeIfPresent(V2RuntimeState.self, forKey: .state)
        timeline = try container.decode(V2TimelineSnapshot.self, forKey: .timeline)
        approvals = try container.decode([V2Approval].self, forKey: .approvals)
        notices = try container.decode([V2RuntimeNotice].self, forKey: .notices)
        effectiveCapabilities = try container.decode(V2RuntimeCapabilitySnapshot.self, forKey: .effectiveCapabilities)
        runtimeCapabilities = try container.decode(V2RuntimeCapabilitySnapshot.self, forKey: .runtimeCapabilities)
        catalogs = try container.decode([String: JSONValue].self, forKey: .catalogs)
        eventCursor = try container.decode(String.self, forKey: .eventCursor)
        serverTime = try container.decode(String.self, forKey: .serverTime)
        activeAgents = ((try? container.decode(LossyElements<V2TimelineItem>.self, forKey: .activeAgents))?.elements) ?? []
        excludesAgentChildren = try container.decodeIfPresent(Bool.self, forKey: .excludesAgentChildren) ?? false
    }
}

/// An array that keeps the elements it can decode and drops the ones it
/// cannot. Each element is read behind a wrapper that never throws, so the
/// unkeyed container always advances past a bad element — the element decoder
/// itself would leave its index unmoved after a failure.
///
/// Used for every collection of `V2TimelineItem` on the wire (snapshot
/// timeline, history page, active SubAgent cards, archived rows): a row missing
/// a required field (`id`/`sessionId`/`orderSeq`) is dropped rather than
/// failing the whole page — one malformed row must never cost the session open.
/// This is the "宁缺勿假" rule for ordering: a row whose orderSeq we cannot
/// trust is not shown at all, never shown in a guessed position.
struct LossyElements<Element: Decodable>: Decodable {
    let elements: [Element]

    private struct LossyElement<Value: Decodable>: Decodable {
        let value: Value?

        init(from decoder: Decoder) throws {
            value = try? Value(from: decoder)
        }
    }

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var elements: [Element] = []
        while !container.isAtEnd {
            if let value = (try? container.decode(LossyElement<Element>.self))?.value {
                elements.append(value)
            }
        }
        self.elements = elements
    }
}

nonisolated struct V2TimelineSnapshot: Decodable, Hashable {
    let items: [V2TimelineItem]
    let nextSeq: Int
    let hasMore: Bool
}

extension V2TimelineSnapshot {
    /// The snapshot's timeline page. Identical rule to a history page: a row
    /// *inside* `items` that fails to decode is dropped, never failing the
    /// session open; the `items` key itself stays required and must be an array
    /// (a missing key or a non-array still throws, as it always did). Declared
    /// in an extension so the synthesized memberwise initializer survives.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = try container.decode(LossyElements<V2TimelineItem>.self, forKey: .items).elements
        nextSeq = try container.decode(Int.self, forKey: .nextSeq)
        hasMore = try container.decode(Bool.self, forKey: .hasMore)
    }

    private enum CodingKeys: String, CodingKey {
        case items
        case nextSeq
        case hasMore
    }
}

nonisolated struct V2Approval: Decodable, Identifiable, Hashable {
    let id: String
    let sessionId: V2SessionID
    let turnId: V2TurnID?
    let status: String
    let kind: String
    let targetItemId: V2TimelineItemID?
    let title: String
    let description: String?
    let payload: JSONValue
    let choices: [String]
    let source: JSONValue
    let createdAt: String
    let resolvedAt: String?
    let updatedSeq: Int
}

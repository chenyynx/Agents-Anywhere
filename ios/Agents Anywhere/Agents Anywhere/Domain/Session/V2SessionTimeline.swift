import Foundation

enum V2TimelineMode: String {
    case latest
    case changes
    case history
    /// One SubAgent card's own rows, read on demand (session-open-coverage P3).
    /// Newest → oldest pagination through `beforeOrderSeq`, the same page
    /// shape as every other timeline read.
    case children
}

/// The `exclude` filter the coverage reads accept (session-open-coverage P2).
/// Absent (nil) means the request is byte-for-byte what it was before the
/// parameter existed; the server applies the filter, never the client.
enum V2TimelineExclude: String {
    /// Drops every SubAgent child row — a row whose payload carries a
    /// non-empty `content.parentItemId` (the server's rule, contract #2).
    case agentChildren = "agent_children"
}

struct V2SessionTimelinePage: Decodable, Hashable {
    let sessionId: V2SessionID
    let items: [V2TimelineItem]
    let nextSeq: Int
    let hasMore: Bool
    let serverTime: String?
}

struct V2SessionSnapshot: Decodable, Hashable {
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
    }
}

extension V2SessionSnapshot {
    /// Defensive decode in the `V2TimelineItem` style. `activeAgents` alone is
    /// lenient: an absent key (老服务端) or a non-array reads `[]`, and one
    /// card that fails to decode is dropped instead of failing the whole
    /// snapshot — a single malformed card must never cost the session open.
    /// Every other field keeps exactly its previous requirement.
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
    }
}

/// An array that keeps the elements it can decode and drops the ones it
/// cannot. Each element is read behind a wrapper that never throws, so the
/// unkeyed container always advances past a bad element — the element decoder
/// itself would leave its index unmoved after a failure.
private struct LossyElements<Element: Decodable>: Decodable {
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

struct V2TimelineSnapshot: Decodable, Hashable {
    let items: [V2TimelineItem]
    let nextSeq: Int
    let hasMore: Bool
}

struct V2Approval: Decodable, Identifiable, Hashable {
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

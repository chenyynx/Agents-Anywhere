import Foundation

struct V2SessionCatalogs: Hashable {
    let model: V2ModelCatalog
    let permission: V2PermissionCatalog
}

struct V2SessionLiveState: Hashable {
    let state: V2RuntimeState
    let capabilities: V2RuntimeCapabilitySnapshot
    let notices: [V2RuntimeNotice]
}

/// Cached content is readable while disconnected; live controls require fresh runtime facts.
enum V2SessionConnectionState: Hashable {
    case inactive
    case connecting
    case connected
    case reconnecting
    case offline
    case failed(String)
}

/// One SubAgent card the session projection keeps beside the loaded window
/// because it has not reached a terminal phase yet (ios-capsule-activity-window
/// §2). The capsule's visibility must not depend on how much of the timeline the
/// client happens to hold, so an active card is carried whole — it is never
/// pinned into `V2SessionData.items`, which stays a bounded pagination window.
///
/// `confirmedAt` is when this client last read a version of the card (any
/// source: initial page, history page, live frame, recovery replay). It is the
/// only evidence available for ageing the entry out, because the API exposes no
/// single-timeline-item read to reconcile it against.
struct V2ActiveAgentCard: Hashable {
    let item: V2TimelineItem
    let confirmedAt: Date
}

struct V2SessionData: Hashable {
    var session: V2SessionMeta
    var items: [V2TimelineItem]
    var hasOlderItems: Bool
    var hasNewerItems = false
    var state: V2RuntimeState?
    var capabilities: V2RuntimeCapabilitySnapshot
    var notices: [V2RuntimeNotice]
    var cursor: String
    var liveStateIsFresh = false
    var lastExtensionEvent: V2SessionEvent?
    /// Active top-level SubAgent cards, kept beside the window rather than in
    /// it. Fed by every merge, window guards included, so a card that has been
    /// pushed out of the window by later traffic still drives the capsule.
    var activeAgentCards: [V2ActiveAgentCard] = []
    /// SubAgent child rows (payload `content.parentItemId` non-empty), fetched
    /// on demand through the timeline's `mode=children` read (session-open
    /// coverage P3). Kept beside the window exactly like the active-card
    /// sidecar and never written into `items`: the window's paging cursor,
    /// history flags and trims are untouched by detail loading. Merged by id
    /// with the supersedes rule, bounded by `V2SessionProjection.maximumDetail*`.
    var subAgentChildren: [V2TimelineItem] = []

    init(snapshot: V2SessionSnapshot, now: Date = Date()) {
        session = snapshot.session
        items = snapshot.timeline.items.sorted { $0.orderSeq < $1.orderSeq }
        hasOlderItems = snapshot.timeline.hasMore
        state = snapshot.state
        capabilities = snapshot.effectiveCapabilities
        notices = snapshot.notices
        cursor = snapshot.eventCursor
        // session-open-coverage P1: the snapshot's active cards seed the
        // sidecar through the very same absorb rule every other source uses, so
        // a card the window does not hold yet — the cold-open case — is on the
        // capsule from the first read, a card the window also carries is
        // counted once (id union, newer version wins), and a terminal card
        // never enters. Skips other sessions' rows exactly as the merge does.
        for item in snapshot.activeAgents where item.sessionId == snapshot.session.id {
            activeAgentCards = SubAgentProgress.absorbingActiveCards(item, into: activeAgentCards, now: now)
        }
    }
}

/// A user-facing acknowledgement that the client rebuilt a session's data from
/// a snapshot after the incremental recovery could not be applied. Carried on
/// the observation so the disclosure rides the same stream as the error it
/// replaces.
struct V2SessionRecoveryNotice: Hashable {
    let title: String
    let message: String
}

struct V2SessionObservation: Hashable {
    let sessionId: V2SessionID
    let data: V2SessionData?
    let connection: V2SessionConnectionState
    let error: V2ClientFailure?
    /// Sticky self-heal disclosure (see `V2SessionRecoveryNotice`); nil until a
    /// rebuild has happened. Defaulted so observations without one keep
    /// constructing exactly as before.
    var recoveryNotice: V2SessionRecoveryNotice? = nil
}

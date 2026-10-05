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

    init(snapshot: V2SessionSnapshot) {
        session = snapshot.session
        items = snapshot.timeline.items.sorted { $0.orderSeq < $1.orderSeq }
        hasOlderItems = snapshot.timeline.hasMore
        state = snapshot.state
        capabilities = snapshot.effectiveCapabilities
        notices = snapshot.notices
        cursor = snapshot.eventCursor
    }
}

struct V2SessionObservation: Hashable {
    let sessionId: V2SessionID
    let data: V2SessionData?
    let connection: V2SessionConnectionState
    let error: V2ClientFailure?
}

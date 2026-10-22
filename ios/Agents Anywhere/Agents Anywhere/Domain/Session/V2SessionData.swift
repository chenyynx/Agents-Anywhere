import Foundation

nonisolated struct V2SessionCatalogs: Hashable {
    let model: V2ModelCatalog
    let permission: V2PermissionCatalog
}

nonisolated struct V2SessionLiveState: Hashable {
    let state: V2RuntimeState
    let capabilities: V2RuntimeCapabilitySnapshot
    let notices: [V2RuntimeNotice]
}

/// Cached content is readable while disconnected; live controls require fresh runtime facts.
nonisolated enum V2SessionConnectionState: Hashable {
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
/// evidence used for ageing the entry out. The API's single-item read exists
/// for deferred tool summaries (`GET …/timeline/items/{item_id}`), not as a
/// general card reconciliation source, so it does not feed this timestamp.
struct V2ActiveAgentCard: Hashable {
    let item: V2TimelineItem
    let confirmedAt: Date
}

nonisolated struct V2SessionData: Hashable {
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
    /// Whether the server built this window from main-agent rows only
    /// (`excludeAgentChildren`). The panel needs it: in such a window a
    /// SubAgent card's own row is always present while its activity rows can
    /// never be, so the card row is not evidence that the content loaded.
    /// Live child rows may still arrive; this flag describes the read mode,
    /// not the current membership.
    var windowExcludesAgentChildren = false
    /// Whether the window was read with `deferActivity`: large tool payloads
    /// may have arrived as summary rows (`V2TimelineItem.isDeferred`) that the
    /// single-item read can replace. This describes the whole read mode — a
    /// deferred window can still contain no summary rows at all — so it is not
    /// a count of deferred rows.
    var windowDeferredActivity = false
    /// Active top-level SubAgent cards, kept beside the window rather than in
    /// it. Fed by every merge, window guards included, so a card that has been
    /// pushed out of the window by later traffic still drives the capsule.
    var activeAgentCards: [V2ActiveAgentCard] = []

    init(snapshot: V2SessionSnapshot, now: Date = Date()) {
        session = snapshot.session
        items = snapshot.timeline.items.sorted { $0.orderSeq < $1.orderSeq }
        hasOlderItems = snapshot.timeline.hasMore
        state = snapshot.state
        capabilities = snapshot.effectiveCapabilities
        notices = snapshot.notices
        cursor = snapshot.eventCursor
        windowExcludesAgentChildren = snapshot.excludesAgentChildren
        windowDeferredActivity = snapshot.deferredActivity
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

/// The notification-type notices this session has acknowledged within their
/// current open episode, by notice id. A notification is one-shot per *episode*
/// — the span during which it is `status == "open"` — not per `(id, revision)`:
/// production never bumps the revision (the server default is a constant 1 and
/// nothing raises it), so an id-keyed record is the only honest identity. An
/// acknowledgement is meaningful only while its notice is open; when the notice
/// resolves or vanishes its episode has ended and the acknowledgement is
/// dropped (see `V2SessionRepository.reconcileNotificationAcknowledgements`), so
/// a later episode at the same id surfaces again. Persisted with the session
/// archive so a close outlives a page rebuild and a relaunch — the toast store
/// is view-scoped and cannot be the record.
nonisolated struct V2NotificationAcknowledgements: Codable, Hashable {
    private var acknowledged: Set<String> = []

    init() {}

    func contains(_ noticeId: String) -> Bool { acknowledged.contains(noticeId) }

    var isEmpty: Bool { acknowledged.isEmpty }

    mutating func acknowledge(_ noticeId: String) { acknowledged.insert(noticeId) }

    /// Drops every acknowledgement outside `live` — the ids still open as
    /// notifications. Reconciling against the authoritative open set is what
    /// ends an episode: a notice that is no longer open loses its
    /// acknowledgement, so the next time the same id opens it is a fresh
    /// episode that surfaces again.
    mutating func retain(_ live: Set<String>) { acknowledged.formIntersection(live) }
}

nonisolated struct V2SessionObservation: Hashable {
    let sessionId: V2SessionID
    let data: V2SessionData?
    let connection: V2SessionConnectionState
    let error: V2ClientFailure?
    /// Sticky self-heal disclosure (see `V2SessionRecoveryNotice`); nil until a
    /// rebuild has happened. Defaulted so observations without one keep
    /// constructing exactly as before.
    var recoveryNotice: V2SessionRecoveryNotice? = nil
    /// The notification acknowledgements this session carries (see
    /// `V2NotificationAcknowledgements`). Defaulted so existing construction
    /// sites keep compiling.
    var acknowledgedNotifications = V2NotificationAcknowledgements()
}

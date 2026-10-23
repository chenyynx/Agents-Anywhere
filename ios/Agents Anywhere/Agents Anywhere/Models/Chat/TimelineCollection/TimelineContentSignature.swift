import Foundation

/// Everything about a row that can change its rendered height. Kept separate
/// from `ChatTimelineRowModel` (a main-actor observable class) so the diff can
/// be computed and tested as a value comparison.
nonisolated struct TimelineRowContentSignature: Equatable {
    let id: String
    let revision: Int
    let updatedSeq: Int
}

nonisolated struct TimelineInlineNoticeSignature: Equatable {
    let id: String
    /// A notice's status is `V2RuntimeNoticeStatus`; it is not a timeline row
    /// status (open/responding/resolved vs pending/running/done).
    let status: V2RuntimeNoticeStatus
    let revision: Int
}

/// A preview already sitting in `ChatAttachmentStore`. Pixel dimensions decide
/// the image's aspect box, so they change a row's height even when the text
/// does not.
nonisolated struct TimelineAttachmentPreviewSignature: Equatable {
    let id: String
    let pixelWidth: Int?
    let pixelHeight: Int?
}

nonisolated struct TimelineTurnActionSignature: Equatable {
    let replyIDs: [String]
    let changeIDs: [String]
    let startsMidTurn: Bool
    /// The footer can sit on a later group while its file-change rows belong
    /// to an earlier one. A change row gaining a parseable path/diff changes
    /// the footer's height without changing any ID, so carry the revisions.
    var replyRevisions: [Int] = []
    var changeRevisions: [Int] = []
}

/// The inputs `TimelineTurnActions.build` consumes beyond the rows themselves.
/// `hasNewerItems` and the pending bubble decide whether the latest turn's
/// footer commits or stays suppressed, which adds or removes a row.
nonisolated struct TimelineTurnSuppression: Equatable {
    let isRunning: Bool
    let hasNewerItems: Bool
    let hasPendingUserMessage: Bool
}

nonisolated struct TimelineGroupContentSignature: Equatable {
    let rows: [TimelineRowContentSignature]
    /// The group-level fold's state (`TimelineFold(id: "group:<id>")`).
    /// Expanding changes the group's height without changing its rows.
    let disclosureExpanded: Bool
    /// Row-level folds expanded inside this group. One Bool cannot represent
    /// several independent folds: collapsing one while another stays open
    /// would leave the signature equal and the group's height stale.
    var expandedRowIDs: [String] = []
    /// Rows whose reveal clock is running. A reveal settling changes which
    /// engine may render the row (streaming tail vs. static TextKit) without
    /// changing the wire revision, so the signature must carry it.
    var revealingRowIDs: [String] = []
    /// Inline approval/notice cards attached to this group's rows.
    let inlineNotices: [TimelineInlineNoticeSignature]
    let attachments: [TimelineAttachmentPreviewSignature]
    let turnAction: TimelineTurnActionSignature?
    let turnSuppression: TimelineTurnSuppression

    var contentRevision: Int {
        var hasher = TimelineStableHasher()
        for row in rows {
            hasher.combine(row.id)
            hasher.combine(row.revision)
            hasher.combine(row.updatedSeq)
        }
        hasher.combine(disclosureExpanded)
        for rowID in expandedRowIDs.sorted() { hasher.combine(rowID) }
        for rowID in revealingRowIDs.sorted() { hasher.combine(rowID) }
        for notice in inlineNotices {
            hasher.combine(notice.id)
            hasher.combine(notice.status.rawValue)
            hasher.combine(notice.revision)
        }
        for attachment in attachments {
            hasher.combine(attachment.id)
            hasher.combine(attachment.pixelWidth.map { UInt64(bitPattern: Int64($0)) } ?? 0)
            hasher.combine(attachment.pixelHeight.map { UInt64(bitPattern: Int64($0)) } ?? 0)
        }
        if let action = turnAction {
            hasher.combine(true)
            action.replyIDs.forEach { hasher.combine($0) }
            action.replyRevisions.forEach { hasher.combine($0) }
            hasher.combine(action.changeIDs.joined(separator: "|"))
            action.changeRevisions.forEach { hasher.combine($0) }
            hasher.combine(action.startsMidTurn)
        } else {
            hasher.combine(false)
        }
        hasher.combine(turnSuppression.isRunning)
        hasher.combine(turnSuppression.hasNewerItems)
        hasher.combine(turnSuppression.hasPendingUserMessage)
        return hasher.revision
    }
}

nonisolated struct TimelineQueueEntrySignature: Equatable {
    let id: String
    /// `V2QueuedMessage.State` rendered as a stable token; the model type is a
    /// main-actor class, the signature stays a value.
    let state: String
}

nonisolated struct TimelineTailContentSignature: Equatable {
    let queue: [TimelineQueueEntrySignature]
    let sendingPlaceholder: String?
    let orbActivity: String
    let hasNewerItems: Bool
    /// The Code page's working status lives inside the last message while a
    /// reasoning block is active. The tail's own status line is suppressed
    /// then, so the mark is never drawn twice (device report 2026-10-23).
    let statusLineVisible: Bool

    var contentRevision: Int {
        var hasher = TimelineStableHasher()
        for entry in queue {
            hasher.combine(entry.id)
            hasher.combine(entry.state)
        }
        hasher.combine(optional: sendingPlaceholder)
        hasher.combine(orbActivity)
        hasher.combine(hasNewerItems)
        hasher.combine(statusLineVisible)
        return hasher.revision
    }
}

/// The content half of one item's identity: equal signatures mean no
/// re-measurement and no reconfigure are needed.
nonisolated enum TimelineContentSignature: Equatable {
    case group(TimelineGroupContentSignature)
    case olderPrompt(pullReady: Bool, isLoading: Bool, keepsPrompt: Bool, hasOlderItems: Bool)
    case latestPrompt(pullReady: Bool, isLoading: Bool, hasNewerItems: Bool)
    /// The working status row draws only the flipbook mark and the rotating
    /// verb; neither changes its height, so one stable signature is enough.
    case workingStatus
    case notice(id: String, status: V2RuntimeNoticeStatus, revision: Int)
    case pending(id: String, attachments: [TimelineAttachmentPreviewSignature])
    case tail(TimelineTailContentSignature)

    /// The value the height key carries. Two signatures that hash equally but
    /// differ still produce a reconfigure; the revision only decides whether a
    /// measurement may be reused.
    var contentRevision: Int {
        switch self {
        case .group(let group):
            return group.contentRevision
        case .olderPrompt(let pullReady, let isLoading, let keepsPrompt, let hasOlderItems):
            var hasher = TimelineStableHasher()
            hasher.combine(pullReady); hasher.combine(isLoading)
            hasher.combine(keepsPrompt); hasher.combine(hasOlderItems)
            return hasher.revision
        case .latestPrompt(let pullReady, let isLoading, let hasNewerItems):
            var hasher = TimelineStableHasher()
            hasher.combine(pullReady); hasher.combine(isLoading); hasher.combine(hasNewerItems)
            return hasher.revision
        case .workingStatus:
            return 0
        case .notice(let id, let status, let revision):
            var hasher = TimelineStableHasher()
            hasher.combine(id); hasher.combine(status.rawValue); hasher.combine(revision)
            return hasher.revision
        case .pending(let id, let attachments):
            var hasher = TimelineStableHasher()
            hasher.combine(id)
            for attachment in attachments {
                hasher.combine(attachment.id)
                hasher.combine(attachment.pixelWidth ?? 0)
                hasher.combine(attachment.pixelHeight ?? 0)
            }
            return hasher.revision
        case .tail(let tail):
            return tail.contentRevision
        }
    }
}

nonisolated struct TimelineContentEntry: Equatable {
    let item: TimelineListItem
    let signature: TimelineContentSignature
}

nonisolated struct TimelineContentChange: Equatable {
    /// Items present in the new snapshot whose signature differs from the
    /// previous one, in snapshot order. New items are included: the caller
    /// inserts them and, when a height is needed, measures them too.
    let changed: [TimelineListItem]
    let removed: [TimelineListItem]
}

/// Signature store that turns two snapshots into the `reconfigureItems` list.
/// Pure view state (Textual selection, reveal animations, copy feedback) is
/// deliberately absent: it cannot change a row's height and must not force a
/// re-measure.
nonisolated struct TimelineContentSignatures: Equatable {
    private(set) var entries: [TimelineListItem: TimelineContentSignature] = [:]

    @discardableResult
    mutating func update(_ next: [TimelineContentEntry]) -> TimelineContentChange {
        var changed: [TimelineListItem] = []
        var nextEntries: [TimelineListItem: TimelineContentSignature] = [:]
        nextEntries.reserveCapacity(next.count)
        for entry in next {
            nextEntries[entry.item] = entry.signature
            if entries[entry.item] != entry.signature { changed.append(entry.item) }
        }
        let removed = entries.keys
            .filter { nextEntries[$0] == nil }
            .sorted { $0.itemID < $1.itemID }
        entries = nextEntries
        return TimelineContentChange(changed: changed, removed: removed)
    }

    func signature(for item: TimelineListItem) -> TimelineContentSignature? { entries[item] }
}

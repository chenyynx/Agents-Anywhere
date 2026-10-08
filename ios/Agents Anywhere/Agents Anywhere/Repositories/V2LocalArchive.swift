import Foundation

nonisolated struct V2DashboardArchive: Codable {
    struct Page: Codable { let scope: V2SessionListScope; let info: V2SessionPageInfo }
    let connectors: [V2Connector]
    let projects: [V2Project]
    let sessions: [V2SessionMeta]
    let pages: [Page]
    var firstPageIDs: Set<String>? = nil
    var extendedScopes: Set<V2SessionListScope>? = nil
    struct Membership: Codable { let scope: V2SessionListScope; let ids: Set<String> }
    var projectMemberships: [Membership]? = nil
}

nonisolated struct V2SessionArchive: Codable {
    struct Pending: Codable {
        let id: String
        let content: String
        let attachmentIDs: [String]
        let attachments: [ChatAttachment]
        let error: String?
        let rejected: Bool
    }
    /// A queued message that was never put on the wire. Only never-sent items
    /// are stored as `queued`: an item mid-send (`sending`/`awaitingEcho`) may
    /// already have reached the server, so it is demoted to a `Pending` record
    /// instead (see `init`) and never auto-replayed.
    struct Queued: Codable {
        let id: String
        let content: String
        let attachmentIDs: [V2AttachmentID]
        let attachments: [ChatAttachment]
    }
    let session: V2SessionMeta
    let items: [JSONValue]
    let cursor: String
    let hasOlderItems: Bool
    let hasNewerItems: Bool
    let draft: String
    let draftAttachments: [ChatAttachment]
    let pending: [Pending]
    /// The outbound queue, if any. Optional: archives written before this field
    /// existed decode without it.
    var queued: [Queued]? = nil
    var previews: ChatAttachmentStore.Archive? = nil
    /// The recovery diagnostics the session last carried, so a failure that
    /// outlives a relaunch is still on record. Optional: archives written
    /// before this field existed decode without it.
    var recoveryDiagnostics: [V2SessionRecoveryDiagnostic]? = nil

    @MainActor init(data: V2SessionData, model: V2SessionModel) {
        session = data.session; items = data.items.map(\.raw); cursor = data.cursor
        hasOlderItems = data.hasOlderItems; hasNewerItems = data.hasNewerItems
        previews = model.attachmentPreviews.archived()
        draft = model.draft; draftAttachments = model.composer.attachments.map { $0.archived() }
        var storedPending = model.pendingMessages.filter { $0.delivery != .confirmed }.map { value in
            let error: String?; let rejected: Bool
            switch value.delivery {
            case .rejected(let failure): error = failure.message; rejected = true
            case .uncertain(let failure): error = failure.message; rejected = false
            default: error = nil; rejected = false
            }
            return Pending(id: value.id, content: value.content, attachmentIDs: value.attachmentIDs,
                attachments: value.attachments.map { $0.archived() }, error: error, rejected: rejected)
        }
        // Split the queue by certainty. A waiting, fully-uploaded message never
        // left the client, so it is safe to re-arm on restore. Anything already
        // on the wire — mid-send, awaiting its echo, or still uploading — may
        // have reached the server, so it is demoted to an uncertain Pending
        // record and is never sent again automatically.
        var storedQueued: [Queued] = []
        for item in model.sendQueue.items {
            if item.state == .queued, item.isUploadComplete {
                storedQueued.append(Queued(id: item.id, content: item.content,
                    attachmentIDs: item.attachmentIDs, attachments: item.attachments.map { $0.archived() }))
            } else {
                storedPending.append(Pending(id: item.id, content: item.content,
                    attachmentIDs: item.attachmentIDs, attachments: item.attachments.map { $0.archived() },
                    error: nil, rejected: false))
            }
        }
        pending = storedPending
        queued = storedQueued.isEmpty ? nil : storedQueued
    }

    @MainActor func projection(maximumItems: Int, now: @escaping () -> Date = Date.init) throws -> V2SessionProjection {
        let decoded = try items.map { try JSONDecoder().decode(V2TimelineItem.self, from: JSONEncoder().encode($0)) }
        let empty = V2RuntimeCapabilitySnapshot(revision: 0, capabilities: [])
        let snapshot = V2SessionSnapshot(session: session, state: nil,
            timeline: .init(items: decoded, nextSeq: V2SessionProjection.sequence(cursor), hasMore: hasOlderItems),
            approvals: [], notices: [], effectiveCapabilities: empty, runtimeCapabilities: empty,
            catalogs: [:], eventCursor: cursor, serverTime: "")
        return V2SessionProjection(archive: snapshot, hasNewerItems: hasNewerItems, maximumItems: maximumItems, now: now)
    }
}

extension ChatAttachment {
    func archived() -> Self {
        // Uploaded bytes are retrievable by fileId. Keep the small thumbnail and
        // original local bytes only while an upload has not completed.
        var copy = Self(id: id, name: name, data: uploaded == nil ? data : Data(), mediaType: mediaType,
            previewData: previewData, pixelSize: pixelSize)
        copy.uploaded = uploaded
        return copy
    }
}

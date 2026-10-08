import Foundation
import Observation

/// One message the user queued while the agent was still running. It is the
/// queue's own unit of work — distinct from `V2PendingMessage`, which models a
/// *send already on the wire*. A queued message takes the wire on its own turn,
/// so the two never share a lifecycle; this is why `id` is minted at enqueue
/// (a UUID that the eventual drain reuses as the send's `clientMessageId`) and
/// why state is a shape of its own rather than a `V2PendingMessage.Delivery`.
///
/// Attachments upload eagerly at enqueue time. `isUploadComplete` is the gate
/// the drain reads: a queued message whose bytes are not all on the server yet
/// cannot be sent, so the queue's head waits for it instead of failing a turn.
@MainActor @Observable
final class V2QueuedMessage: Identifiable {
    enum State: Equatable { case queued, sending, awaitingEcho }
    let id: String
    let content: String
    private(set) var attachments: [ChatAttachment]
    private(set) var attachmentIDs: [V2AttachmentID]
    private(set) var state: State

    /// Every attachment has a server reference on file, or there is nothing to
    /// upload. `attachmentIDs` is rebuilt from the uploaded references, so this
    /// and a well-formed `attachmentIDs` are the same fact.
    var isUploadComplete: Bool {
        attachments.allSatisfy { $0.uploaded != nil }
    }

    init(id: String = UUID().uuidString, content: String, attachments: [ChatAttachment] = [], state: State = .queued) {
        self.id = id; self.content = content; self.attachments = attachments
        self.attachmentIDs = attachments.compactMap { $0.uploaded?.fileId }
        self.state = state
    }

    /// Binds one eager upload to the attachment that produced it, mirroring
    /// `V2PendingMessage.bindUpload`. The id list is recomputed, so it always
    /// agrees with `isUploadComplete`.
    func bindUpload(_ file: V2AttachmentReference, localID: String) {
        guard let index = attachments.firstIndex(where: { $0.id == localID }) else { return }
        attachments[index].uploaded = file
        attachmentIDs = attachments.compactMap { $0.uploaded?.fileId }
    }

    func update(_ state: State) {
        // The drain advances the head (.sending → .awaitingEcho) and a failed
        // send rolls it back to .queued, so every transition is legal; the setter
        // exists mainly to keep the state observable to the row views.
        self.state = state
    }
}

/// Why the queue is holding. An explicit pause (a failed drain or a failed
/// retry) is distinct from the derived offline pause; the display collapses
/// both into one banner, so the reason only has to say which copy to show.
enum V2SendQueuePause: Equatable {
    case offline
    case failure(String)
}

/// The session's outbound queue. It is a pure ordering container with a pause
/// latch — the session model owns the *decision* to drain, this owns the
/// *contents*. Shape follows `SessionNoticeStore`: a small `@Observable` store
/// the session model holds beside its composer and pending list.
@MainActor @Observable
final class V2SendQueue {
    private(set) var items: [V2QueuedMessage] = []
    /// The user-facing pause that survives a retry-while-offline: a failure is
    /// sticky until an explicit retry clears it, so the banner cannot flicker
    /// away between a reconnect and the next attempt.
    private(set) var explicitPause: V2SendQueuePause?

    var isEmpty: Bool { items.isEmpty }
    var count: Int { items.count }
    var head: V2QueuedMessage? { items.first }

    func enqueue(_ item: V2QueuedMessage) {
        items.append(item)
    }

    func remove(id: String) {
        items.removeAll { $0.id == id }
        // Nothing left to protect: an empty queue cannot stall, and a fresh
        // message queued later must not inherit a stale pause nothing explains.
        if items.isEmpty { explicitPause = nil }
    }

    /// First reason wins: a queue already held for a reason the user can see
    /// must not be overwritten by a later, quieter one mid-flight.
    func pause(_ reason: V2SendQueuePause) {
        guard explicitPause == nil else { return }
        explicitPause = reason
    }

    func resume() {
        explicitPause = nil
    }

    /// Restores a persisted queue. Replaces wholesale — a restore is the only
    /// caller and it runs before any drain can have touched the queue.
    func replaceAll(_ items: [V2QueuedMessage]) {
        self.items = items
        explicitPause = nil
    }
}

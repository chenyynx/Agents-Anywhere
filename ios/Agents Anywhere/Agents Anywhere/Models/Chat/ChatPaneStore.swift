import Foundation

/// A reader position inside the transcript, kept by the page model so a
/// rebuilt view can return to the same place instead of the bottom.
nonisolated struct ChatScrollAnchor: Equatable, Sendable {
    /// `TimelineListItem.itemID` (`"g:…"` / `"n:…"` / `"p:…"`), the same id
    /// space `TimelineCollectionController.anchor(at:)` reports.
    let itemID: String
    let offsetIntoRow: CGFloat
}

/// Shell-owned cache of chat pane models.
///
/// The official app keeps session stores outside the tab page
/// (`SessionRegistry`, capacity 10), so switching tabs or drilling into a
/// device never tears down a store or its live stream. AA holds the chat root
/// and the device stack's session here; the tab pages only render.
@MainActor
final class ChatPaneStore {
    private var services: V2ClientServices?
    private var models: [V2SessionID: SessionChatModel] = [:]
    private var order: [V2SessionID] = []
    /// The chat root plus a device stack session are the working set; a small
    /// cache covers the transient overlap while one of them is replaced.
    private static let limit = 4

    /// The shell creates this from a view body initializer, which is not
    /// main-actor isolated in the package's Swift 5 language mode.
    nonisolated init() {}

    func pane(for session: V2SessionModel, services: V2ClientServices) -> SessionChatModel {
        if self.services !== services {
            models.removeAll()
            order.removeAll()
            self.services = services
        }
        // A cached model can outlive its repository entry: the repository
        // invalidates the old object and mints a new one under the same
        // presentation key. Reusing that stale model would pin the page to a
        // closed session, so drop it before the identity/key lookup.
        for (key, model) in Array(models) where model.session !== session
            && model.session.presentationKey == session.presentationKey
            && !model.session.isValid {
            models.removeValue(forKey: key)
            order.removeAll { $0 == key }
        }
        // A local creation is renamed to the server id in place: the same
        // session object can still sit under its old key.
        if let (key, model) = models.first(where: {
            $0.value.session === session
                || $0.value.session.presentationKey == session.presentationKey
        }) {
            if key != session.id {
                models.removeValue(forKey: key)
                models[session.id] = model
            }
            touch(session.id)
            return model
        }
        let created = SessionChatModel(
            session: session,
            repository: services.sessionRepository,
            attachments: services.attachments,
            files: services.workspaceFiles
        )
        created.onEditCreation = { [weak services, weak session] pending in
            if let session { services?.editCreation(session, pending: pending) }
        }
        created.onDiscardCreation = { [weak services] in services?.discardCreation(session.id) }
        models[session.id] = created
        touch(session.id)
        while order.count > Self.limit, let oldest = order.first {
            order.removeFirst()
            models.removeValue(forKey: oldest)
        }
        return created
    }

    /// Drops panes that are neither the chat root nor on the device stack.
    /// Releasing a pane cancels its live observer through
    /// `SessionLiveRun.deinit`, exactly like closing that chat.
    func retain(_ ids: Set<V2SessionID>) {
        for (key, model) in Array(models) {
            if key != model.session.id {
                models.removeValue(forKey: key)
                models[model.session.id] = model
            }
        }
        for (key, model) in Array(models) where !ids.contains(model.session.id) {
            models.removeValue(forKey: key)
        }
        order = order.filter { models[$0] != nil }
    }

    private func touch(_ id: V2SessionID) {
        order.removeAll { $0 == id }
        order.append(id)
    }
}

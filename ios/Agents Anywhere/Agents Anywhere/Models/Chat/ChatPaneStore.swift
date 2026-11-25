import Foundation

/// A reader position inside the transcript, kept by the page model so a
/// rebuilt view can return to the same place instead of the bottom.
nonisolated struct ChatScrollAnchor: Equatable, Sendable {
    let rowID: String
    let offsetIntoRow: CGFloat
}

/// Shell-owned owner of the current chat pane's model.
///
/// The official app keeps the session store outside the tab page
/// (`SessionRegistry`), so switching tabs never tears down the store or its
/// live stream. AA mirrors that here: the tab page only renders; the model,
/// its observer and its restore anchor outlive the page.
@MainActor
final class ChatPaneStore {
    private var services: V2ClientServices?
    private var model: SessionChatModel?

    /// The shell creates this from a view body initializer, which is not
    /// main-actor isolated in the package's Swift 5 language mode.
    nonisolated init() {}

    /// The model compares by its live session id, not a captured one: a local
    /// creation is renamed to the server id in place, and the same pane must
    /// survive that rename.
    func pane(for session: V2SessionModel, services: V2ClientServices) -> SessionChatModel {
        if let model, model.session.id == session.id, self.services === services {
            return model
        }
        // Releasing the previous pane cancels its live observer with its model
        // (`SessionLiveRun.deinit`), exactly like closing that chat.
        model = nil
        self.services = nil
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
        model = created
        self.services = services
        return created
    }

    /// Drops the pane (and its live observer) unless the chat tab still shows
    /// this session.
    func release(unless id: V2SessionID?) {
        guard let model, model.session.id != id else { return }
        self.model = nil
        services = nil
    }
}

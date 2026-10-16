import Foundation
import Testing
@testable import ClientCore

/// The notification-type notice ("切换已延后") as a one-shot top toast: it must
/// not seat in the timeline, it must float on the shared toast surface with its
/// own severity skin, and closing it must stay closed across a page rebuild
/// while a bumped revision re-opens it (pp 2026-10-16).
@Suite @MainActor struct NotificationNoticeSurfaceTests {
    // MARK: Fixtures

    private func runtimeNotice(id: String = "notice", type: String = "notification", severity: String = "info",
                               status: String = "open", revision: Int = 1, timelineItemId: String? = nil) throws -> V2RuntimeNotice {
        var value = (try fixtureObject("notices")["notices"] as! [[String: Any]])[0]
        value["noticeId"] = id; value["type"] = type; value["severity"] = severity
        value["status"] = status; value["revision"] = revision
        if let timelineItemId { value["source"] = ["timelineItemId": timelineItemId] }
        return try decode(value)
    }

    private func model(id: String = "notice", type: String = "notification", severity: String = "info",
                       status: String = "open", revision: Int = 1, timelineItemId: String? = nil) throws -> SessionNoticeModel {
        SessionNoticeModel(try runtimeNotice(id: id, type: type, severity: severity, status: status,
                                             revision: revision, timelineItemId: timelineItemId))
    }

    // MARK: Rendering routing

    /// A notification notice never seats in the timeline tail, even with no
    /// anchor; an interaction notice the timeline does not anchor still does.
    @Test func notificationIsExcludedFromTheTimelineTail() throws {
        let notification = try model(id: "deferred", type: "notification")
        let interaction = try model(id: "approval", type: "interaction")
        let tail = SessionNoticeRouting.tailNotices([notification, interaction], sessionID: "session", timelineRowIDs: [])
        #expect(tail.map(\.id) == ["approval"])
    }

    /// An interaction notice anchored to an unrendered row seats in the tail;
    /// once its row is rendered it moves to the inline anchor and leaves the
    /// tail. A notification with the same anchor is never inline.
    @Test func theAnchoredInlinePointOnlyTakesInteractionNotices() throws {
        let interaction = try model(id: "approval", type: "interaction", timelineItemId: "row-1")
        let notification = try model(id: "deferred", type: "notification", timelineItemId: "row-1")
        let inline = SessionNoticeRouting.notices([interaction, notification], sessionID: "session", anchoredTo: "row-1")
        #expect(inline.map(\.id) == ["approval"])

        // Anchored interaction: out of the tail once its row is present.
        let tail = SessionNoticeRouting.tailNotices([interaction, notification], sessionID: "session", timelineRowIDs: ["row-1"])
        #expect(tail.isEmpty)
    }

    /// A notification the server has resolved is not visible and so does not
    /// seat anywhere; an open one is visible to the notification channel.
    @Test func aResolvedNotificationIsNotPending() throws {
        let resolved = try model(id: "deferred", type: "notification", status: "resolved", revision: 2)
        #expect(ChatNotification.pending(in: [resolved], acknowledged: V2NotificationAcknowledgements()).isEmpty)
    }

    // MARK: One-shot semantics

    /// The pending filter excludes any notification whose identity the user has
    /// already acknowledged, and re-includes it at a bumped revision — a
    /// genuinely new event at the same id.
    @Test func anAcknowledgedNotificationStaysClosedUntilItsRevisionBumps() throws {
        let open = try model(id: "deferred", type: "notification", revision: 1)
        var acknowledged = V2NotificationAcknowledgements()
        #expect(ChatNotification.pending(in: [open], acknowledged: acknowledged).map(\.id) == ["deferred"])

        acknowledged.acknowledge(noticeId: "deferred", revision: 1)
        #expect(ChatNotification.pending(in: [open], acknowledged: acknowledged).isEmpty)

        // A higher revision is a new event and surfaces again.
        let bumped = try model(id: "deferred", type: "notification", revision: 2)
        #expect(ChatNotification.pending(in: [bumped], acknowledged: acknowledged).map(\.revision) == [2])
    }

    /// The acknowledgement is monotone: closing an older revision after a newer
    /// one cannot lower the recorded bar and reopen the notice.
    @Test func theAcknowledgementNeverMovesBackwards() {
        var acknowledged = V2NotificationAcknowledgements()
        acknowledged.acknowledge(noticeId: "deferred", revision: 2)
        acknowledged.acknowledge(noticeId: "deferred", revision: 1)
        #expect(acknowledged["deferred"] == 2)
    }

    /// The end-to-end one-shot: acknowledging through a session model is
    /// persisted to the archive, so a freshly reconstructed page — modelled by
    /// a new repository restoring from disk, the "退会再进" case — reads the
    /// acknowledgement back and filters the notice out. Without the durable
    /// record (the toast store is view-scoped) it would replay.
    @Test func anAcknowledgedNotificationDoesNotReplayAfterARebuiltRepository() async throws {        let url = FileManager.default.temporaryDirectory.appendingPathComponent("aa-notif-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let store = V2LocalStore(directory: url)
        let http = TestHTTPTransport(); let runtime = V2RuntimeAPI(transport: http)
        func make() -> V2SessionRepository {
            .init(scope: .init(serverURL: URL(string: "https://example.test")!, accountID: "account"),
                detail: .init(sessionAPI: V2SessionAPI(transport: http), runtimeAPI: runtime, realtimeAPI: TestRealtimeAPI()),
                interactions: .init(runtimeAPI: runtime), localStore: store)
        }
        let first = make()
        _ = try await first.load(sessionId: "session")
        first.session(id: "session").acknowledgeNotification(noticeId: "deferred", revision: 1)
        #expect(first.session(id: "session").acknowledgedNotifications["deferred"] == 1)
        await first.flushCache(); first.reset()

        // A new page (fresh repository instance) reads the persisted record.
        let restored = make()
        restored.updateConnectivity(.init(availability: .offline))
        _ = try await restored.load(sessionId: "session")
        let acknowledged = restored.session(id: "session").acknowledgedNotifications
        #expect(acknowledged["deferred"] == 1)
        let open = try model(id: "deferred", type: "notification", revision: 1)
        #expect(ChatNotification.pending(in: [open], acknowledged: acknowledged).isEmpty)

        // A bumped revision still surfaces after the rebuild.
        let bumped = try model(id: "deferred", type: "notification", revision: 2)
        #expect(ChatNotification.pending(in: [bumped], acknowledged: acknowledged).map(\.revision) == [2])
        restored.reset(); await store.close(removing: true)
    }

    // MARK: Severity skin

    /// A notification's severity maps onto the skin: info (and success) take
    /// the neutral glyph, error and warning keep the alarm mark.
    @Test func severitySelectsTheToastSkin() throws {
        let info = try #require(ChatNotification(notice: try runtimeNotice(severity: "info")))
        #expect(info.severity == .info)
        #expect(info.severity.symbolName == "info.circle")

        let success = try #require(ChatNotification(notice: try runtimeNotice(severity: "success")))
        #expect(success.severity == .info)

        let warning = try #require(ChatNotification(notice: try runtimeNotice(severity: "warning")))
        #expect(warning.severity == .warning)
        #expect(warning.severity.symbolName == "exclamationmark.circle")

        let error = try #require(ChatNotification(notice: try runtimeNotice(severity: "error")))
        #expect(error.severity == .error)
        #expect(error.severity.symbolName == "exclamationmark.circle")
    }

    /// Only a notification-type notice becomes a `ChatNotification`; every other
    /// kind stays on its own surface.
    @Test func onlyNotificationTypeBecomesAToastNotification() throws {
        #expect(ChatNotification(notice: try runtimeNotice(type: "interaction")) == nil)
    }

    /// A toast built without an explicit severity keeps the error skin, so the
    /// existing sources (session/runtime/operation/opening/command/sync-recovery)
    /// look exactly as they did.
    @Test func existingSourcesKeepTheErrorSkin() {
        let toast = ChatToast(id: "session", title: "操作未完成", message: "boom", canRetry: false)
        #expect(toast.severity == .error)
        #expect(toast.severity.symbolName == "exclamationmark.circle")

        let store = ChatToastStore()
        store.update(source: "session", failure: V2ClientFailure(kind: .transient, message: "boom"))
        store.update(source: "runtime", notice: ChatRuntimeErrorNotice.make(
            for: V2RuntimeError(code: "claude_process_retired", message: "wire text"))!)
        #expect(store.items.allSatisfy { $0.severity == .error })
    }

    // MARK: Toast store — notification channel

    /// The notification channel pins a dismissal to `(id, revision)`: the same
    /// revision cannot revive a closed toast, a bumped revision re-opens it,
    /// and the notification is recoverable by source for the caller to persist.
    @Test func theNotificationChannelPinsDismissalToIdentity() throws {
        let store = ChatToastStore()
        let first = try #require(ChatNotification(notice: try runtimeNotice(severity: "info", revision: 1)))
        store.update(source: "notif:deferred", notification: first)
        #expect(store.items.map(\.id) == ["notif:deferred"])
        #expect(store.items.first?.severity == .info)
        #expect(store.notification(for: "notif:deferred")?.identity == first.identity)

        // The same revision observed again is one toast, not two.
        store.update(source: "notif:deferred", notification: first)
        #expect(store.items.count == 1)

        store.dismiss("notif:deferred")
        #expect(store.items.isEmpty)
        // A dismissal speaks for the revision it acknowledged.
        store.update(source: "notif:deferred", notification: first)
        #expect(store.items.isEmpty)

        // A bumped revision is a new event and re-opens the toast.
        let bumped = try #require(ChatNotification(notice: try runtimeNotice(severity: "info", revision: 2)))
        store.update(source: "notif:deferred", notification: bumped)
        #expect(store.items.map(\.id) == ["notif:deferred"])
    }

    /// The notification channel does not share a slot with the failure or
    /// runtime channels even for the same logical subject: it is keyed by its
    /// own `notif:` source.
    @Test func theNotificationChannelDoesNotCollideWithOtherSources() throws {
        let store = ChatToastStore()
        store.update(source: "session", failure: V2ClientFailure(kind: .transient, message: "boom"))
        store.update(source: "notif:deferred", notification: try #require(ChatNotification(notice: try runtimeNotice())))
        #expect(Set(store.items.map(\.id)) == ["session", "notif:deferred"])
        store.dismiss("notif:deferred")
        #expect(store.items.map(\.id) == ["session"])
    }
}

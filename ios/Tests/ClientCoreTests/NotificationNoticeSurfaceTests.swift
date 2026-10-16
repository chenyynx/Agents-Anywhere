import Foundation
import Testing
@testable import ClientCore

/// The notification-type notice ("切换已延后") as a one-shot top toast: it must
/// not seat in the timeline, it must float on the shared toast surface with its
/// own severity skin, and closing it must stay closed for *one open episode*
/// while a later episode at the same id surfaces again (pp 2026-10-16).
///
/// The identity is deliberately the notice id, not `(id, revision)`: production
/// never advances the revision (the server default is a constant 1), so a
/// revision-keyed identity would silence an id forever after one close. One-shot
/// is an episode property, ended when the notice leaves the open set.
@Suite @MainActor struct NotificationNoticeSurfaceTests {
    // MARK: Fixtures

    private func noticeObject(id: String = "deferred", type: String = "notification", severity: String = "info",
                              status: String = "open", timelineItemId: String? = nil) throws -> [String: Any] {
        var value = (try fixtureObject("notices")["notices"] as! [[String: Any]])[0]
        value["noticeId"] = id; value["type"] = type; value["severity"] = severity; value["status"] = status
        if let timelineItemId { value["source"] = ["timelineItemId": timelineItemId] }
        return value
    }

    private func runtimeNotice(id: String = "deferred", type: String = "notification", severity: String = "info",
                               status: String = "open", timelineItemId: String? = nil) throws -> V2RuntimeNotice {
        try decode(noticeObject(id: id, type: type, severity: severity, status: status, timelineItemId: timelineItemId))
    }

    private func model(id: String = "deferred", type: String = "notification", severity: String = "info",
                       status: String = "open", timelineItemId: String? = nil) throws -> SessionNoticeModel {
        SessionNoticeModel(try runtimeNotice(id: id, type: type, severity: severity, status: status, timelineItemId: timelineItemId))
    }

    private func notification(id: String = "deferred", severity: String = "info", status: String = "open") throws -> ChatNotification {
        try #require(ChatNotification(notice: try runtimeNotice(id: id, severity: severity, status: status)))
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

    /// Only an open notification is surfaced; a resolved one is not an open
    /// episode and produces no toast.
    @Test func aResolvedNotificationIsNotAnOpenEpisode() throws {
        #expect(ChatNotification(notice: try runtimeNotice(status: "resolved")) == nil)
        #expect(ChatNotification.pending(in: [try model(status: "resolved")], acknowledged: V2NotificationAcknowledgements()).isEmpty)
    }

    // MARK: Episode semantics

    /// An open notification surfaces once; acknowledging it (closing the toast)
    /// keeps it closed for the rest of the episode — the same open notice no
    /// longer surfaces, whatever its revision.
    @Test func anAcknowledgedNotificationStaysClosedWithinItsEpisode() throws {
        let open = try model(status: "open")
        var acknowledged = V2NotificationAcknowledgements()
        #expect(ChatNotification.pending(in: [open], acknowledged: acknowledged).map(\.id) == ["deferred"])

        acknowledged.acknowledge("deferred")
        #expect(ChatNotification.pending(in: [open], acknowledged: acknowledged).isEmpty)
    }

    /// Ending the episode — the notice leaving the open set — drops its
    /// acknowledgement, so a *new* episode at the same id surfaces again. This
    /// is the fix for the "silenced forever" defect: an id-keyed acknowledgement
    /// with no episode boundary would swallow every future deferral.
    @Test func aNewEpisodeAfterTheNoticeLeavesTheOpenSetSurfacesAgain() throws {
        let open = try model(status: "open")
        var acknowledged = V2NotificationAcknowledgements()
        acknowledged.acknowledge("deferred")
        #expect(ChatNotification.pending(in: [open], acknowledged: acknowledged).isEmpty)

        // The notice resolved (or vanished): the episode ended.
        acknowledged.retain([])
        #expect(acknowledged.isEmpty)
        // A fresh open at the same id is a new episode and surfaces again.
        #expect(ChatNotification.pending(in: [open], acknowledged: acknowledged).map(\.id) == ["deferred"])
    }

    /// Reconciling against the open set is a retain, not a wipe: an id still
    /// open keeps its acknowledgement, and only the ids that left are dropped.
    @Test func reconcileRetainsOnlyTheIdsStillOpen() {
        var acknowledged = V2NotificationAcknowledgements()
        acknowledged.acknowledge("first"); acknowledged.acknowledge("second")
        acknowledged.retain(["second"])
        #expect(acknowledged.contains("second"))
        #expect(!acknowledged.contains("first"))
    }

    /// Multiple notifications carry independent acknowledgements.
    @Test func acknowledgementsArePerNoticeID() {
        var acknowledged = V2NotificationAcknowledgements()
        acknowledged.acknowledge("first")
        #expect(acknowledged.contains("first") && !acknowledged.contains("second"))
        acknowledged.retain(["first", "second"])
        #expect(acknowledged.contains("first"))
    }

    // MARK: Toast store — notification channel

    /// The store projects the pending set: it adds a toast per pending
    /// notification, refreshes its copy, and withdraws the toast of a notice
    /// that left the set (resolved) — the P2 fix that stops a leftover toast
    /// claiming an effect that is no longer true. Re-entering the episode later
    /// re-adds it.
    @Test func reconcileAddsRefreshesAndWithdrawsNotificationToasts() throws {
        let store = ChatToastStore()
        let first = try notification(id: "deferred", severity: "info")
        store.reconcileNotifications([first])
        #expect(store.items.map(\.id) == ["notif:deferred"])
        #expect(store.items.first?.severity == .info)
        #expect(store.notification(for: "notif:deferred") == first)

        // A changed copy refreshes the same toast in place.
        let renamed = try #require(ChatNotification(notice: try decode(noticeObject(id: "deferred", severity: "warning"))))
        store.reconcileNotifications([renamed])
        #expect(store.items.map(\.id) == ["notif:deferred"])
        #expect(store.items.first?.severity == .warning)

        // The notice left the open set: its toast is withdrawn.
        store.reconcileNotifications([])
        #expect(store.items.isEmpty)
        #expect(store.notification(for: "notif:deferred") == nil)

        // A later episode re-adds it.
        store.reconcileNotifications([first])
        #expect(store.items.map(\.id) == ["notif:deferred"])
    }

    /// The store never re-adds a notification the user acknowledged, because
    /// `pending` already excludes it; reconcile is a pure projection of the
    /// durable, per-episode acknowledgement, not remembered state in the store.
    @Test func anAcknowledgedNotificationIsNotInThePendingSetSoTheStoreCannotReviveIt() throws {
        let store = ChatToastStore()
        let open = try model(status: "open")
        var acknowledged = V2NotificationAcknowledgements()
        store.reconcileNotifications(ChatNotification.pending(in: [open], acknowledged: acknowledged))
        #expect(store.items.map(\.id) == ["notif:deferred"])

        store.dismiss("notif:deferred")
        acknowledged.acknowledge("deferred")
        // The page re-pushes from the durable set: the notice is acknowledged,
        // so it is not pending — the store must not re-open it.
        store.reconcileNotifications(ChatNotification.pending(in: [open], acknowledged: acknowledged))
        #expect(store.items.isEmpty)
    }

    /// The notification channel does not share a slot with the failure or
    /// runtime channels even for the same logical subject: it is keyed by its
    /// own `notif:` source.
    @Test func theNotificationChannelDoesNotCollideWithOtherSources() throws {
        let store = ChatToastStore()
        store.update(source: "session", failure: V2ClientFailure(kind: .transient, message: "boom"))
        store.reconcileNotifications([try notification()])
        #expect(Set(store.items.map(\.id)) == ["session", "notif:deferred"])
        store.reconcileNotifications([])
        #expect(store.items.map(\.id) == ["session"])
    }

    // MARK: Severity skin

    /// A notification's severity maps onto the skin: info (and success) take
    /// the neutral glyph, error and warning keep the alarm mark.
    @Test func severitySelectsTheToastSkin() throws {
        #expect(try notification(severity: "info").severity == .info)
        #expect(try notification(severity: "info").severity.symbolName == "info.circle")
        #expect(try notification(severity: "success").severity == .info)
        #expect(try notification(severity: "warning").severity == .warning)
        #expect(try notification(severity: "warning").severity.symbolName == "exclamationmark.circle")
        #expect(try notification(severity: "error").severity == .error)
        #expect(try notification(severity: "error").severity.symbolName == "exclamationmark.circle")
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

    // MARK: End-to-end through the repository

    /// The notice list the connector serves on a live read; mutable so a test
    /// can resolve the notice and later re-open it.
    @MainActor private final class LiveNotices {
        var value: [[String: Any]]
        init(_ value: [[String: Any]]) { self.value = value }
    }

    /// The full episode cycle, driven through the real repository paths (live
    /// reads → `applyLive` → `emit` → the model the page observes):
    /// an open notification surfaces; closing it stays closed while it is still
    /// open — including across a rebuilt, disk-restored page (the "退会再进"
    /// case); when the notice leaves the open set the acknowledgement is
    /// dropped; and a fresh episode at the same id surfaces again. Without the
    /// episode boundary the id-keyed acknowledgement would silence the id
    /// forever — the production defect this pins.
    @Test func anAcknowledgedNotificationStaysClosedUntilItsEpisodeEndsThenSurfacesAgain() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("aa-notif-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let localStore = V2LocalStore(directory: url)
        let http = TestHTTPTransport()
        let live = LiveNotices([try noticeObject(id: "deferred", status: "open")])
        http.respond = { call in
            if call.path.hasSuffix("/notices") {
                return try JSONSerialization.data(withJSONObject: ["notices": live.value, "serverTime": "2026-09-05T12:00:00Z"])
            }
            return try http.defaultResponse(call)
        }
        let runtime = V2RuntimeAPI(transport: http)
        func make() -> V2SessionRepository {
            .init(scope: .init(serverURL: URL(string: "https://example.test/api/v2")!, accountID: "account"),
                detail: .init(sessionAPI: V2SessionAPI(transport: http), runtimeAPI: runtime, realtimeAPI: TestRealtimeAPI()),
                interactions: .init(runtimeAPI: runtime), localStore: localStore)
        }
        let repo = make()
        _ = try await repo.load(sessionId: "session")
        let session = repo.session(id: "session")

        func pending() -> [String] {
            ChatNotification.pending(in: session.notices.notices, acknowledged: session.acknowledgedNotifications).map(\.id)
        }

        // 1. A live read surfaces the open notification.
        try await repo.sync(sessionId: "session")
        #expect(pending() == ["deferred"])

        // 2. Closing it records the acknowledgement.
        session.acknowledgeNotification(noticeId: "deferred")
        #expect(session.acknowledgedNotifications.contains("deferred"))
        #expect(pending().isEmpty)

        // 3. Still open on the next live read: stays closed.
        try await repo.sync(sessionId: "session")
        #expect(session.acknowledgedNotifications.contains("deferred"))
        #expect(pending().isEmpty)

        // 4. A rebuilt, disk-restored page keeps it closed. The archive does
        //    not persist notices, so the notice only returns with a live read —
        //    which is exactly the "退会再进 + 重新拉到通知" case: the durable
        //    acknowledgement must suppress it.
        await repo.flushCache(); repo.reset()
        let restored = make()
        _ = try await restored.load(sessionId: "session")
        let restoredSession = restored.session(id: "session")
        #expect(restoredSession.acknowledgedNotifications.contains("deferred"))
        try await restored.sync(sessionId: "session")
        #expect(ChatNotification.pending(in: restoredSession.notices.notices,
            acknowledged: restoredSession.acknowledgedNotifications).isEmpty)

        // 5. The notice leaves the open set: the episode ends and the
        //    acknowledgement is dropped.
        live.value = []
        try await restored.sync(sessionId: "session")
        #expect(!restoredSession.acknowledgedNotifications.contains("deferred"))

        // 6. A fresh episode at the same id surfaces again.
        live.value = [try noticeObject(id: "deferred", status: "open")]
        try await restored.sync(sessionId: "session")
        #expect(ChatNotification.pending(in: restoredSession.notices.notices,
            acknowledged: restoredSession.acknowledgedNotifications).map(\.id) == ["deferred"])

        restored.reset(); await localStore.close(removing: true)
    }
}

import Foundation
import UserNotifications

/// The only switches are the notification master switch and display choices.
/// Background keep-alive has none: while notifications are on, going to the
/// background starts the ladder and the long poll for the whole window
/// (P3 常驻), so turns that begin after the user leaves still notify.
enum NotificationSettings {
    static let enabledKey = "aa.notifications.enabled"
    static let previewKey = "aa.notifications.preview"
    static let sessionSocketKey = "aa.keepalive.sessionSocket"
    static let foregroundKey = "aa.notifications.foreground"

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }
    static var showsPreview: Bool {
        UserDefaults.standard.object(forKey: previewKey) as? Bool ?? true
    }
    /// Keep the viewed session's socket across background (default off: the
    /// background poll delivers notifications without it).
    static var sessionSocketEnabled: Bool {
        UserDefaults.standard.object(forKey: sessionSocketKey) as? Bool ?? false
    }
    /// Foreground banners for sessions other than the one on screen. Off by
    /// default; the visible session never banners in the foreground.
    static var foregroundEnabled: Bool {
        UserDefaults.standard.object(forKey: foregroundKey) as? Bool ?? false
    }
}

/// Renders the server's notification records as local banners (P1).
///
/// The server decides *what* deserves a notification and ships a stable
/// `id` per record (`type:session:turn`); this service only displays it once,
/// suppresses banners while the app is in front (the session list already
/// shows the state), and routes a tap back to the session.
final class NotificationService: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = NotificationService()
    /// Posted on the main queue after a tap; `userInfo["sessionId"]`.
    static let openSessionNotification = Notification.Name("aa.notification.openSession")

    private static let postedKey = "aa.notification.postedIds"
    private static let postedLimit = 256
    private let center = UNUserNotificationCenter.current()
    private var activated = false
    /// The session on screen, kept current by `AppState.setVisibleSession`.
    private(set) var visibleSessionId: String?
    /// Every record id this device has seen in a projection, with its session.
    /// A record for the session on screen is consumed by id, so leaving the
    /// app later cannot re-deliver a reply the user already read — the server
    /// read marker is asynchronous and can still call it unread.
    private var knownRecords: [String: String] = [:]
    /// Kept current by `AppState.setAppInBackground`. A record the foreground
    /// rules suppress is not posted at all (rather than posted and hidden):
    /// it stays unread on the server, so leaving the app lets the long poll
    /// deliver it instead of the banner being swallowed forever.
    var appInForeground = true

    func activate() {
        guard !activated else { return }
        activated = true
        center.delegate = self
        center.getNotificationSettings { settings in
            ClientDiagnosticsLog.shared.record(
                kind: "notification.settings",
                detail: [
                    "enabled": NotificationSettings.isEnabled ? "1" : "0",
                    "preview": NotificationSettings.showsPreview ? "1" : "0",
                    "keepAlive": "always",
                    "authorization": String(settings.authorizationStatus.rawValue),
                ],
                dedupe: false)
        }
        if NotificationSettings.isEnabled {
            requestAuthorization()
        }
    }

    func requestAuthorization() {
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    /// Displays every record this device has not shown yet. Called from the
    /// dashboard snapshot path, which is alive in the background only while
    /// the keep-alive ladder holds the process.
    func handle(snapshot: V2DashboardSnapshot) {
        handle(records: snapshot.notifications ?? [])
    }

    /// The one display path: dashboard snapshots and the background poll both
    /// feed the same records here. Dedupe is by record id.
    func handle(records: [V2DashboardNotification]) {
        if !records.isEmpty {
            ClientDiagnosticsLog.shared.record(
                kind: "notification.snapshot",
                detail: [
                    "records": String(records.count),
                    "ids": records.map(\.id).joined(separator: ","),
                    "enabled": NotificationSettings.isEnabled ? "1" : "0",
                ],
                dedupe: false)
        }
        guard NotificationSettings.isEnabled else {
            if !records.isEmpty {
                ClientDiagnosticsLog.shared.record(
                    kind: "notification.skipped",
                    detail: ["reason": "disabled", "records": String(records.count)],
                    dedupe: false)
            }
            return
        }
        for record in records {
            knownRecords[record.id] = record.sessionId
        }
        let foreground = appInForeground
        for record in records {
            if foreground {
                let isVisible = visibleSessionId.map { $0 == record.sessionId } ?? false
                if isVisible {
                    // The reply is on screen. Consume the id: the server's
                    // read marker may not have caught up, and the background
                    // long poll must not deliver this record later.
                    consume(record)
                    continue
                }
                if !NotificationSettings.foregroundEnabled {
                    // Leave the id unposted: the record is still unread on the
                    // server, so the background long poll delivers it if the
                    // user leaves without reading. Dedupe keeps this log line
                    // to one per record.
                    ClientDiagnosticsLog.shared.record(
                        kind: "notification.deferred",
                        sessionID: record.sessionId,
                        detail: ["id": record.id, "visible": "0"],
                        dedupe: true)
                    continue
                }
            }
            post(record)
        }
    }

    /// The session on screen changed. Any record this device already knows for
    /// it is consumed: the user has seen that conversation, so a later
    /// background cannot surface it again.
    func setVisibleSession(_ sessionId: String?) {
        visibleSessionId = sessionId
        guard let sessionId, appInForeground else { return }
        for (id, owner) in knownRecords where owner == sessionId {
            consume(id: id)
        }
    }

    /// Records the id without scheduling anything: what it described is on
    /// screen already.
    private func consume(_ record: V2DashboardNotification) {
        knownRecords[record.id] = record.sessionId
        consume(id: record.id)
    }

    private func consume(id: String) {
        guard !isPosted(id) else { return }
        rememberPosted(id)
        ClientDiagnosticsLog.shared.record(
            kind: "notification.consumed",
            sessionID: knownRecords[id],
            detail: ["id": id, "reason": "visible"],
            dedupe: true)
    }

    private func post(_ record: V2DashboardNotification) {
        guard !isPosted(record.id) else { return }

        let content = UNMutableNotificationContent()
        content.title = record.title
        let preview = record.preview ?? ""
        let summary = record.summary ?? String(localized: "回复已完成")
        content.body = NotificationSettings.showsPreview && !preview.isEmpty
            ? preview
            : summary
        content.sound = .default
        content.threadIdentifier = record.sessionId
        content.userInfo = ["sessionId": record.sessionId]
        let request = UNNotificationRequest(
            identifier: record.id,
            content: content,
            trigger: nil
        )
        center.add(request)

        rememberPosted(record.id)
        ClientDiagnosticsLog.shared.record(
            kind: "notification.posted",
            sessionID: record.sessionId,
            detail: ["type": record.type, "id": record.id],
            dedupe: false)
    }

    private func isPosted(_ id: String) -> Bool {
        (UserDefaults.standard.stringArray(forKey: Self.postedKey) ?? []).contains(id)
    }

    private func rememberPosted(_ id: String) {
        let defaults = UserDefaults.standard
        var posted = defaults.stringArray(forKey: Self.postedKey) ?? []
        guard !posted.contains(id) else { return }
        posted.append(id)
        if posted.count > Self.postedLimit {
            posted.removeFirst(posted.count - Self.postedLimit)
        }
        defaults.set(posted, forKey: Self.postedKey)
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Foreground presentation is a strict rule plus a setting:
    /// - the conversation on screen never banners (the reply is already there);
    /// - other sessions banner only when the foreground switch is on
    ///   (default off).
    /// Background presentation never consults this: the OS shows banners and
    /// the turn-end cue must arrive.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        let sessionId = notification.request.content
            .userInfo["sessionId"] as? String
        let visible = visibleSessionId
        let isVisible = visible != nil && sessionId == visible
        let show = NotificationSettings.foregroundEnabled && !isVisible
        ClientDiagnosticsLog.shared.record(
            kind: "notification.foreground",
            detail: [
                "id": notification.request.identifier,
                "visible": isVisible ? "1" : "0",
                "enabled": NotificationSettings.foregroundEnabled ? "1" : "0",
                "show": show ? "1" : "0",
            ],
            dedupe: false)
        return show ? [.banner, .list, .sound] : []
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard let sessionId = response.notification.request.content
            .userInfo["sessionId"] as? String, !sessionId.isEmpty else { return }
        NotificationCenter.default.post(
            name: Self.openSessionNotification,
            object: nil,
            userInfo: ["sessionId": sessionId])
    }
}

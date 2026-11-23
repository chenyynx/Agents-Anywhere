import Foundation
import UserNotifications

enum NotificationSettings {
    static let enabledKey = "aa.notifications.enabled"
    static let previewKey = "aa.notifications.preview"
    static let keepAliveKey = "aa.keepalive.enabled"

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }
    static var showsPreview: Bool {
        UserDefaults.standard.object(forKey: previewKey) as? Bool ?? true
    }
    static var keepAliveEnabled: Bool {
        UserDefaults.standard.object(forKey: keepAliveKey) as? Bool ?? true
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
                    "keepAlive": NotificationSettings.keepAliveEnabled ? "1" : "0",
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
            post(record)
        }
    }

    private func post(_ record: V2DashboardNotification) {
        let defaults = UserDefaults.standard
        var posted = defaults.stringArray(forKey: Self.postedKey) ?? []
        guard !posted.contains(record.id) else { return }

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

        posted.append(record.id)
        if posted.count > Self.postedLimit {
            posted.removeFirst(posted.count - Self.postedLimit)
        }
        defaults.set(posted, forKey: Self.postedKey)
        ClientDiagnosticsLog.shared.record(
            kind: "notification.posted",
            sessionID: record.sessionId,
            detail: ["type": record.type, "id": record.id],
            dedupe: false)
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Show the banner in the foreground too (pp 2026-11-23): the completion
    /// cue must not depend on whether the app happens to be in front when the
    /// turn ends — a suppressed foreground banner reads as a lost notification.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        ClientDiagnosticsLog.shared.record(
            kind: "notification.foreground",
            detail: ["id": notification.request.identifier],
            dedupe: false)
        return [.banner, .list, .sound]
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

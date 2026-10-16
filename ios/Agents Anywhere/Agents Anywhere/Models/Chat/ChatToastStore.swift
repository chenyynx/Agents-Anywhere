import Foundation
import Observation

/// The skin a toast is drawn in. Existing sources (failures and the runtime /
/// self-heal disclosures) keep the authored error skin, which is the default;
/// only a notification-type notice may opt out of it.
enum ChatToastSeverity: Equatable {
    case error
    case warning
    case info

    /// The glyph the toast shows. The alarm mark is the error skin every
    /// existing source already had; the neutral `info.circle` keeps a mere
    /// notice from reading as a failure.
    var symbolName: String {
        switch self {
        case .error, .warning: "exclamationmark.circle"
        case .info: "info.circle"
        }
    }
}

struct ChatToast: Identifiable, Equatable {
    let id: String
    let title: String
    let message: String
    let canRetry: Bool
    let severity: ChatToastSeverity

    init(id: String, title: String, message: String, canRetry: Bool, severity: ChatToastSeverity = .error) {
        self.id = id; self.title = title; self.message = message
        self.canRetry = canRetry; self.severity = severity
    }
}

/// One notification-type notice rendered as a toast: a pure notice with no
/// response surface. Its identity is the notice id alone — production never
/// advances the revision (the server default is a constant 1 and nothing raises
/// it), so a `(id, revision)` identity would collapse to `(id, 1)` and a single
/// close would silence the id forever. One-shot is instead an *episode*
/// property: the span during which the notice is open, ended when the notice
/// leaves the open set and its acknowledgement is dropped (see
/// `V2NotificationAcknowledgements`).
struct ChatNotification: Equatable {
    let id: String
    let title: String
    let message: String
    let severity: ChatToastSeverity

    /// The toast payload for an open notification-type notice, or nil for any
    /// other notice. The contract's severity maps onto the skin: an error or
    /// warning notification keeps the alarm mark, a neutral info/success one
    /// does not.
    init?(notice: V2RuntimeNotice) {
        guard notice.isOpenNotification else { return nil }
        id = notice.noticeId
        title = notice.title
        message = notice.message ?? ""
        switch notice.severity {
        case "error": severity = .error
        case "warning": severity = .warning
        default: severity = .info
        }
    }

    /// The notifications a session page should surface as toasts, in list
    /// order: open notification notices whose id the user has not acknowledged
    /// in the current episode. The acknowledgement record is what makes the
    /// notice one-shot across page visits — the toast store is rebuilt every
    /// time the page appears, so the filter must be answered from durable
    /// state, not from the store.
    static func pending(in notices: [SessionNoticeModel], acknowledged: V2NotificationAcknowledgements) -> [ChatNotification] {
        notices.compactMap { model in
            guard let notification = ChatNotification(notice: model.notice) else { return nil }
            guard !acknowledged.contains(notification.id) else { return nil }
            return notification
        }
    }
}

/// One current issue per source. Dismissing an issue does not change connection
/// facts or enable writes, and repeated identical observations do not reopen it.
@MainActor @Observable final class ChatToastStore {
    private(set) var items: [ChatToast] = []
    private var latest: [String: V2ClientFailure] = [:]
    /// Event identities for the pre-rendered notice channel
    /// (`update(source:notice:)`). Separate from `latest` so the failure
    /// channel's semantics stay byte-for-byte what they were.
    private var latestNotices: [String: ChatRuntimeErrorNotice.Identity] = [:]
    /// The notification channel. Keyed by source and holding the whole
    /// notification so the caller can recover its identity when the toast is
    /// dismissed and persist the acknowledgement behind it.
    private var latestNotifications: [String: ChatNotification] = [:]

    func update(source: String, failure: V2ClientFailure?, title: String? = nil, canRetry: Bool = false) {
        guard latest[source] != failure else { return }
        latest[source] = failure
        items.removeAll { $0.id == source }
        guard let failure, failure.kind != .cancelled else { return }
        let heading: String
        switch failure.kind {
        case .invalidResponse: heading = String(localized: "会话数据格式不兼容")
        case .authentication: heading = String(localized: "登录状态需要验证")
        case .offline: heading = String(localized: "网络已断开")
        default: heading = String(localized: "操作未完成")
        }
        items.append(ChatToast(id: source, title: title ?? heading, message: failure.message, canRetry: canRetry))
    }

    /// Pre-rendered runtime notices, deduplicated by event identity.
    ///
    /// The failure channel dedups on the whole payload; a runtime disclosure
    /// needs the same protection with one difference: its parameters are not
    /// interpolated into the copy, so equality of title and message alone
    /// cannot tell a repeated observation from a new incident. `identity`
    /// does. A notice the user dismissed stays dismissed while the same event
    /// persists (the identity is retained across `dismiss`, exactly like
    /// `latest`), and a changed payload — a new event — re-opens it.
    ///
    /// Dropping back to nil retires the identity as well, so an error that
    /// lapses (a new turn replaces the state) and lands again is a fresh
    /// observation rather than a stale dismissal: the field is the truth, and
    /// a dismissal only speaks for the error it acknowledged.
    func update(source: String, notice: ChatRuntimeErrorNotice?) {
        let identity = notice?.identity
        guard latestNotices[source] != identity else { return }
        latestNotices[source] = identity
        items.removeAll { $0.id == source }
        guard let notice else { return }
        items.append(ChatToast(id: source, title: notice.title, message: notice.message, canRetry: notice.canRetry))
    }

    /// Syncs the notification toasts to the currently-open set (`pending`: open
    /// notification notices the user has not acknowledged in this episode).
    ///
    /// A toast is shown for each pending notification, refreshed if its copy
    /// changed, and withdrawn when its notice leaves the set — either the notice
    /// left its open episode (it resolved, so a leftover "已延后" toast would now
    /// claim an effect that is no longer true) or the user acknowledged it. The
    /// store is deliberately a pure projection of `pending`: dedup is by notice
    /// id (production never advances the revision), and "stays dismissed" is
    /// answered by the acknowledgement behind `pending`, not by state within the
    /// store. A later episode at the same id re-opens because the repository
    /// drops the acknowledgement when it observes the notice leave the open set,
    /// so the id is pending again — see `V2SessionRepository`.
    func reconcileNotifications(_ pending: [ChatNotification]) {
        let wanted = Set(pending.map(\.id))
        let stale = latestNotifications.filter { !wanted.contains($0.value.id) }.map(\.key)
        for source in stale {
            latestNotifications[source] = nil
            items.removeAll { $0.id == source }
        }
        for notification in pending {
            let source = Self.notificationSource(notification.id)
            let toast = ChatToast(id: source, title: notification.title, message: notification.message,
                canRetry: false, severity: notification.severity)
            latestNotifications[source] = notification
            if let index = items.firstIndex(where: { $0.id == source }) {
                if items[index] != toast { items[index] = toast }
            } else {
                items.append(toast)
            }
        }
    }

    /// The notification a toast belongs to, so a dismissal can be persisted
    /// against the right notice. Nil for every non-notification toast.
    func notification(for source: String) -> ChatNotification? { latestNotifications[source] }

    /// The toast slot for a notification notice. Prefixed so it can never
    /// collide with the failure/notice sources (`session`, `runtime`, …), which
    /// occupy the same store.
    static func notificationSource(_ noticeId: String) -> String { "notif:\(noticeId)" }

    func dismiss(_ id: String) { items.removeAll { $0.id == id } }
}

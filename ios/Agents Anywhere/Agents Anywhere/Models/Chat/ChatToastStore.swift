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
/// response surface. Its identity is `(id, revision)` because the server
/// re-issues the same notice id with a bumped revision for a genuinely new
/// event — a fresh revision must be able to open a toast the user already
/// dismissed.
struct ChatNotification: Equatable {
    struct Identity: Hashable {
        let id: String
        let revision: Int
    }

    let id: String
    let revision: Int
    let title: String
    let message: String
    let severity: ChatToastSeverity

    var identity: Identity { Identity(id: id, revision: revision) }

    /// The toast payload for a notification-type notice, or nil for any other
    /// notice. The contract's severity maps onto the skin: an error or warning
    /// notification keeps the alarm mark, a neutral info/success one does not.
    init?(notice: V2RuntimeNotice) {
        guard notice.type == "notification" else { return nil }
        id = notice.noticeId
        revision = notice.revision
        title = notice.title
        message = notice.message ?? ""
        switch notice.severity {
        case "error": severity = .error
        case "warning": severity = .warning
        default: severity = .info
        }
    }

    /// The notifications a session page should surface as toasts, in list
    /// order: open notification-type notices whose identity the user has not
    /// already acknowledged. The acknowledgement record is what makes the
    /// notice one-shot across page visits — the toast store is rebuilt every
    /// time the page appears, so the filter must be answered from durable
    /// state, not from the store.
    static func pending(in notices: [SessionNoticeModel], acknowledged: V2NotificationAcknowledgements) -> [ChatNotification] {
        notices.compactMap { model in
            guard model.isVisible, model.notice.type == "notification" else { return nil }
            guard (acknowledged[model.notice.noticeId] ?? 0) < model.notice.revision else { return nil }
            return ChatNotification(notice: model.notice)
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

    /// Notification-type notices, deduplicated and dismissal-pinned by
    /// `(id, revision)` exactly like the runtime channel: re-feeding the same
    /// revision cannot revive a dismissed toast, while a bumped revision — a
    /// genuinely new event at the same id — re-opens it. The notification is
    /// retained so `notification(for:)` can answer after a dismissal.
    func update(source: String, notification: ChatNotification) {
        guard latestNotifications[source]?.identity != notification.identity else { return }
        latestNotifications[source] = notification
        items.removeAll { $0.id == source }
        items.append(ChatToast(id: source, title: notification.title, message: notification.message,
            canRetry: false, severity: notification.severity))
    }

    /// The notification a toast belongs to, so a dismissal can be persisted
    /// against the right identity. Nil for every non-notification toast.
    func notification(for source: String) -> ChatNotification? { latestNotifications[source] }

    func dismiss(_ id: String) { items.removeAll { $0.id == id } }
}

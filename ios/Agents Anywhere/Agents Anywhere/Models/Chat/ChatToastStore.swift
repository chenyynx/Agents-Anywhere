import Foundation
import Observation

struct ChatToast: Identifiable, Equatable {
    let id: String
    let title: String
    let message: String
    let canRetry: Bool
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

    func dismiss(_ id: String) { items.removeAll { $0.id == id } }
}

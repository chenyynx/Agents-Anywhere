import Foundation
import Testing
@testable import ClientCore

/// Connection-class failures surface once: the app-level connection banner
/// already reports an outage, so the session surface withholds its own
/// connection toasts while that banner is up (and never withholds non-connection
/// ones). The fact is kept in the store, so the toast returns when the outage clears.
@Suite @MainActor struct ChatToastDedupTests {
    private func failure(_ kind: V2ClientFailure.Kind, _ message: String = "internal server error") -> V2ClientFailure {
        V2ClientFailure(kind: kind, message: message)
    }

    @Test func connectivityToastIsWithheldWhileTheBannerShows() {
        let store = ChatToastStore()
        store.update(source: "session", failure: failure(.transient))

        #expect(store.items.count == 1)
        #expect(store.items.first?.isConnectivity == true)
        #expect(store.visible(hidingConnectivity: true).isEmpty)
        #expect(store.visible(hidingConnectivity: false).count == 1)
    }

    @Test func offlineIsConnectivity() {
        let store = ChatToastStore()
        store.update(source: "session", failure: failure(.offline, "网络已断开"))
        #expect(store.items.first?.isConnectivity == true)
        #expect(store.visible(hidingConnectivity: true).isEmpty)
    }

    @Test func rejectionIsNotWithheld() {
        let store = ChatToastStore()
        store.update(source: "operation", failure: failure(.rejected, "被拒绝"))
        #expect(store.items.first?.isConnectivity == false)
        #expect(store.visible(hidingConnectivity: true).count == 1)
    }

    @Test func runtimeNoticeHasNoKindAndIsNeverWithheld() {
        let store = ChatToastStore()
        let notice = ChatRuntimeErrorNotice(title: "运行时错误", message: "detail", canRetry: false,
            identity: .init(code: "runtime_error", params: nil))
        store.update(source: "runtime", notice: notice)
        #expect(store.items.first?.kind == nil)
        #expect(store.visible(hidingConnectivity: true).count == 1)
    }

    @Test func mixedToastsKeepOnlyTheNonConnectivityOnesWhileTheBannerShows() {
        let store = ChatToastStore()
        store.update(source: "session", failure: failure(.transient))
        store.update(source: "operation", failure: failure(.rejected, "被拒绝"))

        let visible = store.visible(hidingConnectivity: true)
        #expect(visible.map(\.id) == ["operation"])
        // The connection fact is retained, not dropped.
        #expect(store.items.count == 2)
    }
}

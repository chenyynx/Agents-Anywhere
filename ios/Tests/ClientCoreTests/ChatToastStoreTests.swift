import Foundation
import Testing
@testable import ClientCore

/// The notice channel added for runtime disclosures — dedup by event
/// identity, dismissal pinned to the acknowledged event, re-open on a changed
/// payload — plus a regression pin on the failure channel's behaviour, which
/// this addition must not have touched.
@Suite @MainActor struct ChatToastStoreTests {
    private func notice(_ params: JSONValue? = nil) -> ChatRuntimeErrorNotice {
        ChatRuntimeErrorNotice.make(for: V2RuntimeError(code: "claude_process_retired", message: "wire text", params: params))!
    }

    @Test func aRuntimeNoticeAppearsOnceAndStaysDismissed() {
        let store = ChatToastStore()
        let first = notice()
        store.update(source: "runtime", notice: first)
        #expect(store.items.map(\.id) == ["runtime"])
        #expect(store.items.first?.title == first.title)
        #expect(store.items.first?.message == first.message)
        #expect(store.items.first?.canRetry == false)

        // The same event observed again is one notice, not two.
        store.update(source: "runtime", notice: notice())
        #expect(store.items.map(\.id) == ["runtime"])

        store.dismiss("runtime")
        #expect(store.items.isEmpty)
        // A dismissal speaks for the event it acknowledged: refeeding the
        // same incident must not revive the notice.
        store.update(source: "runtime", notice: notice())
        #expect(store.items.isEmpty)
    }

    @Test func aChangedPayloadReopensTheNotice() {
        let store = ChatToastStore()
        store.update(source: "runtime", notice: notice())
        store.dismiss("runtime")
        #expect(store.items.isEmpty)
        store.update(source: "runtime", notice: notice(.object(["stuckSeconds": .number(600)])))
        #expect(store.items.map(\.id) == ["runtime"])
    }

    /// An error that lapses (a new turn replaces the state) and lands again is
    /// a fresh observation: the field is the truth, and the dismissal only
    /// spoke for the incident it acknowledged.
    @Test func aSupersededAndRelandedErrorIsAFreshObservation() {
        let store = ChatToastStore()
        store.update(source: "runtime", notice: nil)
        #expect(store.items.isEmpty)

        store.update(source: "runtime", notice: notice())
        store.dismiss("runtime")
        store.update(source: "runtime", notice: nil)
        #expect(store.items.isEmpty)

        store.update(source: "runtime", notice: notice())
        #expect(store.items.map(\.id) == ["runtime"])
    }

    /// The failure channel's semantics, byte for byte: identical observations
    /// dedup, dismissal does not clear `latest`, and only a changed payload
    /// re-opens. Pinned here because the notice channel was added to the same
    /// store and must not have moved any of this.
    @Test func theFailureChannelKeepsItsBehaviour() {
        let store = ChatToastStore()
        let failure = V2ClientFailure(kind: .transient, message: "boom")
        store.update(source: "session", failure: failure)
        #expect(store.items.map(\.id) == ["session"])
        store.update(source: "session", failure: failure)
        #expect(store.items.count == 1)
        store.dismiss("session")
        store.update(source: "session", failure: failure)
        #expect(store.items.isEmpty)
        store.update(source: "session", failure: V2ClientFailure(kind: .transient, message: "boom again"))
        #expect(store.items.map(\.id) == ["session"])
    }

    @Test func theTwoChannelsDoNotShareSlots() {
        let store = ChatToastStore()
        store.update(source: "session", failure: V2ClientFailure(kind: .transient, message: "boom"))
        store.update(source: "runtime", notice: notice())
        #expect(store.items.map(\.id) == ["session", "runtime"])
        store.dismiss("runtime")
        #expect(store.items.map(\.id) == ["session"])
    }
}

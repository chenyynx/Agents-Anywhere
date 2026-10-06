import Foundation
import Testing
@testable import ClientCore

/// Covers the store-level semantics behind the notices sheet's auto-dismiss:
/// the sheet closes by watching `visibleNotices` emptiness, so every waiting
/// status must stay visible and only truly terminal/unavailable notices may
/// empty the list. A regression here would close the sheet while an
/// interaction is still being processed.
@Suite @MainActor struct SessionNoticeVisibilityTests {
    private func notice(id: String = "notice", status: String = "open", revision: Int = 1) throws -> V2RuntimeNotice {
        var value = (try fixtureObject("notices")["notices"] as! [[String: Any]])[0]
        value["noticeId"] = id; value["status"] = status; value["revision"] = revision
        return try decode(value)
    }

    @Test func resolvedNoticeLeavesNothingVisibleSoTheSheetCanClose() throws {
        let store = SessionNoticeStore()
        store.update([try notice()], sessionID: "session")
        #expect(store.visibleNotices.map(\.id) == ["notice"])
        store.update([try notice(status: "resolved", revision: 2)], sessionID: "session")
        // Still tracked (revisions may revive it), just not visible anymore.
        #expect(store.notices.map(\.id) == ["notice"])
        #expect(store.visibleNotices.isEmpty)
    }

    @Test func everyWaitingStatusStaysVisibleSoTheSheetCannotCloseEarly() throws {
        let store = SessionNoticeStore()
        for (index, status) in ["open", "failed", "responding", "response_accepted", "resolving"].enumerated() {
            store.update([try notice(status: status, revision: index + 1)], sessionID: "session")
            #expect(store.visibleNotices.map(\.id) == ["notice"], "status=\(status) must stay visible")
        }
    }

    @Test func unavailableSubmissionEmptiesTheListLikeTheDock() throws {
        let store = SessionNoticeStore()
        store.update([try notice()], sessionID: "session")
        let item = try #require(store.visibleNotices.first)
        item.begin(actionID: "approve")
        item.fail(V2RuntimeError(code: "notice_not_found", message: "Gone"))
        #expect(store.visibleNotices.isEmpty)
    }

    @Test func resolvingOneOfSeveralNoticesKeepsTheSheetContent() throws {
        let store = SessionNoticeStore()
        store.update([try notice(id: "first"), try notice(id: "second")], sessionID: "session")
        #expect(store.visibleNotices.count == 2)
        store.update([try notice(id: "first", status: "resolved", revision: 2), try notice(id: "second")], sessionID: "session")
        #expect(store.visibleNotices.map(\.id) == ["second"])
    }
}

import Foundation
import Testing
@testable import ClientCore

private func diagnosticsItem(
    id: String,
    order: Int,
    type: String = "message",
    role: String? = "assistant"
) throws -> V2TimelineItem {
    var object: [String: Any] = [
        "id": id,
        "sessionId": "session",
        "type": type,
        "status": "done",
        "content": ["format": "markdown", "kind": "markdown", "text": id],
        "source": [:],
        "orderSeq": order,
        "revision": 1,
        "updatedSeq": order,
        "contentHash": id,
    ]
    if let role { object["role"] = role }
    return try JSONDecoder().decode(
        V2TimelineItem.self,
        from: JSONSerialization.data(withJSONObject: object)
    )
}

private func diagnosticsLog() -> ClientDiagnosticsLog {
    let suite = "TimelineDiagnosticsTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    defaults.set(true, forKey: ClientDiagnosticsLog.enabledKey)
    return ClientDiagnosticsLog(
        directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("aa-timeline-diagnostics-\(UUID().uuidString)",
                                    isDirectory: true),
        defaults: defaults
    )
}

private func recordedKinds(_ log: ClientDiagnosticsLog) -> [String] {
    log.days().flatMap { log.entries(for: $0) }.map(\.kind)
}

@Suite @MainActor struct TimelineDiagnosticsTests {
    @Test func duplicateOrderSeqIsRecorded() throws {
        let log = diagnosticsLog()
        let items = [
            try diagnosticsItem(id: "a", order: 1),
            try diagnosticsItem(id: "b", order: 1),
            try diagnosticsItem(id: "c", order: 2),
        ]
        TimelineDiagnostics.validateOrder(sessionID: "session", items: items, log: log)
        let entries = log.days().flatMap { log.entries(for: $0) }
        let duplicate = try #require(
            entries.first(where: { $0.kind == "timeline.order.duplicate" })
        )
        #expect(duplicate.detail["orderSeq"] == "1")
        #expect(duplicate.detail["ids"] == "a,b")
    }

    @Test func nonPositiveOrderSeqIsRecorded() throws {
        let log = diagnosticsLog()
        let items = [try diagnosticsItem(id: "a", order: 0)]
        TimelineDiagnostics.validateOrder(sessionID: "session", items: items, log: log)
        #expect(recordedKinds(log).contains("timeline.order.nonpositive"))
    }

    @Test func unrenderedUserMessageIsRecorded() throws {
        let log = diagnosticsLog()
        let user = try diagnosticsItem(id: "user", order: 1, role: "user")
        let assistant = try diagnosticsItem(id: "assistant", order: 2)
        let units: [TimelineChatUnit] = [
            .message(key: "assistant", rowIDs: ["assistant"])
        ]
        TimelineDiagnostics.validateUnits(
            sessionID: "session", rows: [user, assistant], units: units, log: log
        )
        let entries = log.days().flatMap { log.entries(for: $0) }
        let missing = try #require(
            entries.first(where: { $0.kind == "timeline.user_message.unrendered" })
        )
        #expect(missing.detail["id"] == "user")
        #expect(missing.detail["orderSeq"] == "1")
    }

    @Test func groupingSummaryReportsUserCoverage() throws {
        let user = try diagnosticsItem(id: "user", order: 1, role: "user")
        let assistant = try diagnosticsItem(id: "assistant", order: 2)
        let rows = [user, assistant]
        let rendered = TimelineDiagnostics.groupingSummary(
            rows: rows,
            units: [.message(key: "turn", rowIDs: ["user", "assistant"])]
        )
        #expect(rendered["rows"] == "2")
        #expect(rendered["messageUnits"] == "1")
        #expect(rendered["userRows"] == "1")
        #expect(rendered["userRendered"] == "1")
        #expect(rendered["userUnrendered"] == "0")

        let missing = TimelineDiagnostics.groupingSummary(
            rows: rows,
            units: [.message(key: "assistant", rowIDs: ["assistant"])]
        )
        #expect(missing["userUnrendered"] == "1")
    }

    @Test func healthyWindowRecordsNothing() throws {
        let log = diagnosticsLog()
        let user = try diagnosticsItem(id: "user", order: 1, role: "user")
        let assistant = try diagnosticsItem(id: "assistant", order: 2)
        let units: [TimelineChatUnit] = [
            .message(key: "turn", rowIDs: ["user", "assistant"])
        ]
        TimelineDiagnostics.validateUnits(
            sessionID: "session", rows: [user, assistant], units: units, log: log
        )
        #expect(log.days().isEmpty)
    }
}

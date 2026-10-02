import Foundation
import Testing
@testable import ClientCore

/// Pins the send-timing probe behind the `ios-send-timing-probe` diagnostic
/// build: every stamp is first-write-wins, records match their session and
/// their echo's clientMessageId, orphaned taps expire, the store stays bounded
/// and copyText keeps its TSV shape. Expectations are literals so a changed
/// column or rounding turns these red.

@Suite struct SendTimingProbeTests {
    private final class Clock {
        var value: Date
        init(_ seconds: TimeInterval) { value = Date(timeIntervalSince1970: seconds) }
    }

    private func makeProbe(_ clock: Clock) -> SendTimingProbe {
        SendTimingProbe(now: { clock.value })
    }

    // MARK: - Stamps and formatting

    @Test func orderedMarksProduceTheExpectedTsvLine() {
        let clock = Clock(1_000)
        let probe = makeProbe(clock)
        probe.markTap(sessionId: "s1", preview: "hello world! rest of it")
        clock.value += 0.010
        probe.markPending(sessionId: "s1", clientMessageId: "m1")
        clock.value += 0.040
        probe.markFlushStart(sessionId: "s1")
        clock.value += 0.050
        probe.markFlushEnd(sessionId: "s1")
        clock.value += 0.100
        probe.markHTTPStart(sessionId: "s1")
        clock.value += 0.500
        probe.markHTTPEnd(sessionId: "s1")
        clock.value += 0.100
        probe.markEcho(clientMessageId: "m1")
        clock.value += 0.050
        probe.markStateRunning(sessionId: "s1")
        clock.value += 0.050
        probe.markFirstActivity(sessionId: "s1")
        clock.value += 0.050
        probe.markFirstAssistantText(sessionId: "s1")
        clock.value += 0.200
        probe.markTurnEnd(sessionId: "s1")

        let record = probe.latest(for: "s1")
        #expect(record?.pendingClientMessageID == "m1")
        #expect(record?.hasActivity == true)
        #expect(record?.isFinished == true)

        let lines = probe.copyText().split(separator: "\n").map(String.init)
        #expect(lines.count == 2)
        #expect(lines[0].hasPrefix("#\t"))
        // epoch_ms, session, preview (12 chars), then ms deltas:
        // pending, tap→send, flush, post, tap→echo, post→echo, running,
        // first activity, first text, turn end.
        #expect(lines[1] == "1000000\ts1\thello world!\t10\t200\t50\t500\t800\t100\t850\t900\t950\t1150")
    }

    @Test func missingSegmentsFormatAsDash() {
        let clock = Clock(5)
        let probe = makeProbe(clock)
        probe.markTap(sessionId: "s", preview: "x")
        clock.value += 1
        let lines = probe.copyText().split(separator: "\n").map(String.init)
        #expect(lines[1] == "5000\ts\tx\t-\t-\t-\t-\t-\t-\t-\t-\t-\t-")
    }

    @Test func previewFlattensWhitespaceAndTruncates() {
        let clock = Clock(9)
        let probe = makeProbe(clock)
        probe.markTap(sessionId: "s", preview: "one\ttwo\nthree four five")
        let lines = probe.copyText().split(separator: "\n").map(String.init)
        #expect(lines[1].hasPrefix("9000\ts\tone two thre\t"))
    }

    // MARK: - Idempotence

    @Test func repeatedAndLateMarksKeepTheFirstStamp() {
        let clock = Clock(100)
        let probe = makeProbe(clock)
        probe.markTap(sessionId: "s", preview: "x")
        clock.value += 0.100
        probe.markPending(sessionId: "s", clientMessageId: "m1")
        clock.value += 0.100
        probe.markHTTPStart(sessionId: "s")
        clock.value += 0.100
        probe.markHTTPEnd(sessionId: "s")
        let firstEnd = probe.latest(for: "s")?.httpEnd
        clock.value += 0.100
        probe.markHTTPEnd(sessionId: "s")
        #expect(probe.latest(for: "s")?.httpEnd == firstEnd)

        clock.value += 0.100
        probe.markEcho(clientMessageId: "m1")
        let firstEcho = probe.latest(for: "s")?.echoAt
        clock.value += 0.100
        probe.markEcho(clientMessageId: "m1")
        #expect(probe.latest(for: "s")?.echoAt == firstEcho)

        clock.value += 0.100
        probe.markStateRunning(sessionId: "s")
        let firstRunning = probe.latest(for: "s")?.stateRunningAt
        clock.value += 0.100
        probe.markStateRunning(sessionId: "s")
        #expect(probe.latest(for: "s")?.stateRunningAt == firstRunning)
    }

    @Test func marksWithoutARecordAreNoOps() {
        let clock = Clock(50)
        let probe = makeProbe(clock)
        probe.markTap(sessionId: nil, preview: "new session")
        probe.markTap(sessionId: "", preview: "blank")
        #expect(probe.copyText().split(separator: "\n").count == 1)

        probe.markTap(sessionId: "s", preview: "x")
        clock.value += 0.100
        probe.markStateRunning(sessionId: "other")
        probe.markFirstActivity(sessionId: "other")
        probe.markTurnEnd(sessionId: "other")
        probe.markEcho(clientMessageId: "unknown")
        probe.markHTTPEnd(sessionId: "other")
        #expect(probe.latest(for: "other") == nil)
        #expect(probe.latest(for: "s")?.stateRunningAt == nil)
        #expect(probe.latest(for: "s")?.turnEndAt == nil)
        #expect(probe.latest(for: "s")?.echoAt == nil)
    }

    @Test func outOfOrderActivityStampsKeepTheirOwnTimes() {
        let clock = Clock(20)
        let probe = makeProbe(clock)
        probe.markTap(sessionId: "s", preview: "x")
        clock.value += 0.100
        probe.markPending(sessionId: "s", clientMessageId: "m1")
        clock.value += 0.100
        probe.markFirstAssistantText(sessionId: "s")
        let textAt = probe.latest(for: "s")?.firstAssistantTextAt
        clock.value += 0.100
        probe.markFirstActivity(sessionId: "s")
        #expect(probe.latest(for: "s")?.firstAssistantTextAt == textAt)
        #expect(probe.latest(for: "s")?.firstActivityAt != nil)
    }

    // MARK: - Matching

    @Test func recordsAndEchoesMatchBySessionAndClientID() {
        let clock = Clock(1_000)
        let probe = makeProbe(clock)
        probe.markTap(sessionId: "s1", preview: "a")
        probe.markPending(sessionId: "s1", clientMessageId: "m1")
        clock.value += 1
        probe.markTap(sessionId: "s2", preview: "b")
        probe.markPending(sessionId: "s2", clientMessageId: "m2")
        clock.value += 1
        probe.markEcho(clientMessageId: "m2")
        #expect(probe.latest(for: "s1")?.echoAt == nil)
        #expect(probe.latest(for: "s2")?.echoAt == Date(timeIntervalSince1970: 1_002))
        #expect(probe.latest(for: "s3") == nil)
    }

    @Test func aSecondTapOnTheSameSessionReplacesTheCurrentRecord() {
        let clock = Clock(1_000)
        let probe = makeProbe(clock)
        probe.markTap(sessionId: "s", preview: "one")
        probe.markPending(sessionId: "s", clientMessageId: "m1")
        clock.value += 1
        probe.markTap(sessionId: "s", preview: "two")
        clock.value += 1
        probe.markPending(sessionId: "s", clientMessageId: "m2")
        #expect(probe.latest(for: "s")?.preview == "two")
        #expect(probe.latest(for: "s")?.pendingClientMessageID == "m2")
        // The first record is retained for copy, still unbound to the new pending.
        #expect(probe.copyText().split(separator: "\n").count == 3)
        probe.markEcho(clientMessageId: "m1")
        let lines = probe.copyText().split(separator: "\n").map(String.init)
        // The first record keeps its own echo (tap→echo 2000 ms) and nothing else.
        #expect(lines[1] == "1000000\ts\tone\t0\t-\t-\t-\t2000\t-\t-\t-\t-\t-")
        #expect(lines[2].hasPrefix("1001000\ts\ttwo\t"))
    }

    // MARK: - Expiry and bounds

    @Test func orphanedTapsExpireButPendingRecordsStay() {
        let clock = Clock(1_000)
        let probe = makeProbe(clock)
        probe.markTap(sessionId: "s1", preview: "orphan")
        probe.markTap(sessionId: "s2", preview: "bound")
        probe.markPending(sessionId: "s2", clientMessageId: "m2")
        clock.value += 61
        // A new tap on the same session drops the stale orphan first.
        probe.markTap(sessionId: "s1", preview: "second")
        #expect(probe.latest(for: "s1")?.preview == "second")
        #expect(probe.copyText().split(separator: "\n").count == 3)
        // The pending record is never orphan-pruned, even after an hour.
        clock.value += 3_600
        #expect(probe.latest(for: "s2")?.preview == "bound")
        #expect(probe.latest(for: "s2")?.pendingClientMessageID == "m2")
    }

    @Test func otherSessionsOrphansExpireOnCopy() {
        let clock = Clock(1_000)
        let probe = makeProbe(clock)
        probe.markTap(sessionId: "s1", preview: "one")
        probe.markTap(sessionId: "s2", preview: "two")
        clock.value += 61
        #expect(probe.copyText().split(separator: "\n").count == 1) // legend only
        #expect(probe.latest(for: "s1") == nil)
        #expect(probe.latest(for: "s2") == nil)
    }

    @Test func theStoreIsCappedAndEvictsTheOldest() {
        let clock = Clock(1_000)
        let probe = makeProbe(clock)
        probe.markTap(sessionId: "old", preview: "first")
        probe.markPending(sessionId: "old", clientMessageId: "m-old")
        for index in 0..<100 {
            clock.value += 0.001
            probe.markTap(sessionId: "s\(index)", preview: "x")
        }
        #expect(probe.latest(for: "old") == nil)
        #expect(probe.latest(for: "s0") != nil)
        #expect(probe.latest(for: "s99") != nil)
        // The evicted record cannot be resurrected by a late echo.
        probe.markEcho(clientMessageId: "m-old")
        #expect(probe.copyText().split(separator: "\n").count == 101) // legend + 100
    }

    @Test func clearDropsEverything() {
        let clock = Clock(1_000)
        let probe = makeProbe(clock)
        probe.markTap(sessionId: "s", preview: "x")
        probe.markPending(sessionId: "s", clientMessageId: "m")
        probe.clear()
        #expect(probe.latest(for: "s") == nil)
        #expect(probe.copyText().split(separator: "\n").count == 1)
        // A record created after clear still binds.
        probe.markTap(sessionId: "s", preview: "y")
        probe.markPending(sessionId: "s", clientMessageId: "m2")
        #expect(probe.latest(for: "s")?.pendingClientMessageID == "m2")
    }

    // MARK: - Reply observation

    @Test func observationStampsRunningActivityAndTurnEnd() throws {
        let clock = Clock(2_000)
        let probe = makeProbe(clock)
        probe.markTap(sessionId: "s", preview: "hi")
        clock.value += 0.010
        probe.markPending(sessionId: "s", clientMessageId: "m1")

        // Facts before the echo (order 0) and a fresh idle state must not count.
        clock.value += 0.010
        probe.observe(sessionId: "s", data: try sessionData(status: "idle", items: [
            try item(id: "old", order: 0, role: "assistant", type: "reasoning")
        ]))
        #expect(probe.latest(for: "s")?.stateRunningAt == nil)
        #expect(probe.latest(for: "s")?.firstActivityAt == nil)
        #expect(probe.latest(for: "s")?.turnEndAt == nil)

        let echo = try item(id: "echo", order: 5, role: "user", type: "message", clientID: "m1")
        clock.value += 0.100
        let runningAt = clock.value
        probe.observe(sessionId: "s", data: try sessionData(status: "running", items: [echo]))
        #expect(probe.latest(for: "s")?.stateRunningAt == runningAt)
        #expect(probe.latest(for: "s")?.firstActivityAt == nil)

        // A turn marker right after the echo is not reply activity.
        clock.value += 0.100
        probe.observe(sessionId: "s", data: try sessionData(status: "running", items: [
            echo, try item(id: "turn", order: 6, role: nil, type: "turn.start")
        ]))
        #expect(probe.latest(for: "s")?.firstActivityAt == nil)

        clock.value += 0.100
        let activityAt = clock.value
        probe.observe(sessionId: "s", data: try sessionData(status: "running", items: [
            echo, try item(id: "turn", order: 6, role: nil, type: "turn.start"),
            try item(id: "thinking", order: 7, role: "assistant", type: "reasoning")
        ]))
        #expect(probe.latest(for: "s")?.firstActivityAt == activityAt)
        #expect(probe.latest(for: "s")?.firstAssistantTextAt == nil)

        clock.value += 0.100
        let textAt = clock.value
        let items = [
            echo, try item(id: "turn", order: 6, role: nil, type: "turn.start"),
            try item(id: "thinking", order: 7, role: "assistant", type: "reasoning"),
            try item(id: "reply", order: 8, role: "assistant", type: "message")
        ]
        probe.observe(sessionId: "s", data: try sessionData(status: "running", items: items))
        #expect(probe.latest(for: "s")?.firstAssistantTextAt == textAt)

        clock.value += 0.100
        let endAt = clock.value
        probe.observe(sessionId: "s", data: try sessionData(status: "idle", items: items))
        #expect(probe.latest(for: "s")?.turnEndAt == endAt)
        #expect(probe.latest(for: "s")?.isFinished == true)

        // The record is released: a duplicate idle observation keeps its stamp.
        clock.value += 0.100
        probe.observe(sessionId: "s", data: try sessionData(status: "idle", items: items))
        #expect(probe.latest(for: "s")?.turnEndAt == endAt)
    }

    @Test func staleFactsStampNeitherStateNorTurnEnd() throws {
        let clock = Clock(3_000)
        let probe = makeProbe(clock)
        probe.markTap(sessionId: "s", preview: "hi")
        clock.value += 0.010
        probe.markPending(sessionId: "s", clientMessageId: "m1")
        let echo = try item(id: "echo", order: 5, role: "user", type: "message", clientID: "m1")
        clock.value += 0.100
        probe.observe(sessionId: "s", data: try sessionData(status: "running", fresh: false, items: [echo]))
        #expect(probe.latest(for: "s")?.stateRunningAt == nil)
        clock.value += 0.100
        probe.observe(sessionId: "s", data: try sessionData(status: "idle", fresh: false, items: [echo]))
        #expect(probe.latest(for: "s")?.turnEndAt == nil)
    }

    @Test func aTurnThatEndsWithoutObservedActivityIsNotFinished() throws {
        let clock = Clock(4_000)
        let probe = makeProbe(clock)
        probe.markTap(sessionId: "s", preview: "hi")
        clock.value += 0.010
        probe.markPending(sessionId: "s", clientMessageId: "m1")
        clock.value += 0.100
        probe.observe(sessionId: "s", data: try sessionData(status: "idle", items: []))
        #expect(probe.latest(for: "s")?.turnEndAt == nil)
        #expect(probe.latest(for: "s")?.isFinished == false)
    }

    // MARK: - Helpers

    private func sessionData(status: String, fresh: Bool = true, items: [[String: Any]]) throws -> V2SessionData {
        var object = try fixtureObject("snapshot")
        var session = object["session"] as! [String: Any]
        session["id"] = "s"
        object["session"] = session
        var state = object["state"] as! [String: Any]
        state["sessionId"] = "s"
        state["status"] = status
        object["state"] = state
        var timeline = object["timeline"] as! [String: Any]
        timeline["items"] = items
        object["timeline"] = timeline
        let snapshot: V2SessionSnapshot = try decode(object)
        var data = V2SessionData(snapshot: snapshot)
        data.liveStateIsFresh = fresh
        return data
    }

    private func item(id: String, order: Int, role: String?, type: String, clientID: String? = nil) throws -> [String: Any] {
        var object = try itemObject(id: id, sessionID: "s", order: order, clientID: clientID)
        object["type"] = type
        if let role { object["role"] = role } else { object.removeValue(forKey: "role") }
        return object
    }
}

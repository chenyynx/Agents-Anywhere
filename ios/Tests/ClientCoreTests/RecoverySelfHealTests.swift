import Foundation
import Testing
@testable import ClientCore

/// A failure shape the double must be able to throw while nothing is wrong
/// with the event stream itself (an environment difference, not a decode bug).
private struct TestRecoveryReadFailure: Error {}

/// Runs exactly one recovery round through the manual sync path. `true` means
/// the round reported success — a healthy read, or a snapshot rebuild that
/// absorbed the batch failure (see `handleRecoveryFailure`).
@MainActor private func syncRound(_ repo: V2SessionRepository, session: V2SessionID = "session") async -> Bool {
    do { try await repo.sync(sessionId: session); return true }
    catch { return false }
}

/// One incremental batch whose single event cannot be applied: the item
/// payload is missing every field the projection decodes.
@MainActor private func poisonedRecovery() throws -> V2EventRecoveryResponse {
    let poison = try event("timeline.item_created", seq: 12, id: "poison", payload: ["item": ["id": "broken"]])
    return V2EventRecoveryResponse(events: [poison], nextCursor: "seq:12", snapshotRequired: false, serverTime: "")
}

/// The self-heal defense for a recovery batch that cannot be applied: a
/// failure must never park the cursor forever (the 2026-10-07 stall), the
/// failure must be localizable to the event that broke the batch, and the
/// rebuild must be disclosed instead of staying silent.
@Suite @MainActor struct RecoverySelfHealTests {
    /// One failure keeps today's retry semantics; the second rebuilds from a
    /// snapshot — which resets the cursor, clears the streak and publishes the
    /// disclosure — and the round reports success so the connection survives
    /// its own repair.
    @Test func aBatchThatCannotBeAppliedRebuildsAfterTheSecondFailure() async throws {
        let http = TestHTTPTransport(); let realtime = TestRealtimeAPI()
        var date = Date()
        let repo = repository(transport: http, realtime: realtime, now: { date })
        defer { repo.reset() }
        _ = try await repo.open(sessionId: "session")
        // Park the cursor ahead of the snapshot's own, so the rebuild's reset
        // is observable.
        realtime.onRecover = { V2EventRecoveryResponse(events: [], nextCursor: "seq:12", snapshotRequired: false, serverTime: "") }
        #expect(await syncRound(repo))
        #expect(repo.cached(sessionId: "session")?.cursor == "seq:12")
        #expect(http.count("snapshot") == 1)
        let poisoned = try poisonedRecovery()
        realtime.onRecover = { poisoned }

        // The first failure keeps today's retry semantics.
        #expect(await syncRound(repo) == false)
        #expect(http.count("snapshot") == 1, "One failure must not rebuild")
        #expect(repo.session(id: "session").recoveryNotice == nil)
        #expect(repo.recoveryDiagnostics(sessionId: "session").count == 1)

        // The second failure rebuilds, and the rebuild absorbs the failure.
        #expect(await syncRound(repo))
        #expect(http.count("snapshot") == 2, "The rebuild re-reads the snapshot")
        #expect(repo.cached(sessionId: "session")?.cursor == "seq:10", "The rebuild resets the cursor to the snapshot's")
        let records = repo.recoveryDiagnostics(sessionId: "session")
        #expect(records.count == 2)
        let record = try #require(records.last)
        #expect(record.eventId == "poison")
        #expect(record.eventType == "timeline.item_created")
        #expect(record.eventSequence == 12)
        #expect(record.eventCursor == "seq:12")
        #expect(record.fromCursor == "seq:12")
        #expect(!record.message.isEmpty)
        let notice = try #require(repo.session(id: "session").recoveryNotice)
        #expect(!notice.title.isEmpty && !notice.message.isEmpty)

        // The rebuild cleared the streak: one further failure — past the gate,
        // so the frequency window cannot be what holds it back — is a retry
        // again, not another rebuild.
        date += 3600
        #expect(await syncRound(repo) == false)
        #expect(http.count("snapshot") == 2)
    }

    /// A transient failure the very next round recovers from must not degrade
    /// anything: a success clears the streak, so a later isolated failure still
    /// starts from one.
    @Test func aFailureFollowedBySuccessClearsTheStreak() async throws {
        let http = TestHTTPTransport(); let realtime = TestRealtimeAPI()
        var date = Date()
        let repo = repository(transport: http, realtime: realtime, now: { date })
        defer { repo.reset() }
        _ = try await repo.open(sessionId: "session")
        let poisoned = try poisonedRecovery()
        realtime.onRecover = { poisoned }
        #expect(await syncRound(repo) == false)
        realtime.onRecover = { V2EventRecoveryResponse(events: [], nextCursor: "seq:10", snapshotRequired: false, serverTime: "") }
        #expect(await syncRound(repo))
        #expect(http.count("snapshot") == 1)

        // Far past the frequency gate, so only the cleared streak can hold a
        // rebuild back.
        date += 3600
        realtime.onRecover = { poisoned }
        #expect(await syncRound(repo) == false)
        #expect(http.count("snapshot") == 1, "A success in between resets the streak")
        #expect(repo.session(id: "session").recoveryNotice == nil)
    }

    /// The frequency gate: two rebuilds inside one window collapse into one, so
    /// a persistently failing session costs at most one snapshot per window.
    @Test func rebuildsAreGatedToOncePerWindow() async throws {
        let http = TestHTTPTransport(); let realtime = TestRealtimeAPI()
        var date = Date()
        let repo = repository(transport: http, realtime: realtime, now: { date })
        defer { repo.reset() }
        _ = try await repo.open(sessionId: "session")
        let poisoned = try poisonedRecovery()
        realtime.onRecover = { poisoned }
        #expect(await syncRound(repo) == false)
        #expect(await syncRound(repo))
        #expect(http.count("snapshot") == 2)
        let firstNotice = try #require(repo.session(id: "session").recoveryNotice)

        date += 60
        #expect(await syncRound(repo) == false)
        #expect(await syncRound(repo) == false)
        #expect(http.count("snapshot") == 2, "The frequency gate holds rebuilds to one per window")

        date += 300
        // Past the window the next failure rebuilds.
        #expect(await syncRound(repo))
        #expect(http.count("snapshot") == 3)
        // Each rebuild numbers its disclosure, so a later rebuild is a new
        // payload for the toast store and re-opens a dismissed notice instead
        // of staying silent.
        let secondNotice = try #require(repo.session(id: "session").recoveryNotice)
        #expect(secondNotice != firstNotice)
    }

    /// The defense must not assume a decoding failure. An apply that leaves
    /// the projection layer as any other error takes the same path, and the
    /// record still names the event that broke the batch.
    @Test func aNonDecodingApplyFailureTakesTheSamePath() async throws {
        let http = TestHTTPTransport(); let realtime = TestRealtimeAPI()
        var date = Date()
        let repo = repository(transport: http, realtime: realtime, now: { date })
        defer { repo.reset() }
        _ = try await repo.open(sessionId: "session")
        // A payload that cannot be re-encoded throws out of the apply loop as
        // an EncodingError, not an HTTPError.
        let poison = V2SessionEvent(protocolVersion: "1", eventId: "encode-poison", sequence: 11,
                                    cursor: "seq:11", type: "timeline.item_created", sessionId: "session",
                                    emittedAt: "", payload: .object(["item": .number(.nan)]))
        realtime.onRecover = { V2EventRecoveryResponse(events: [poison], nextCursor: "seq:11", snapshotRequired: false, serverTime: "") }
        #expect(await syncRound(repo) == false)
        #expect(await syncRound(repo))
        #expect(http.count("snapshot") == 2, "Any apply failure counts toward the rebuild")
        let record = try #require(repo.recoveryDiagnostics(sessionId: "session").last)
        #expect(record.eventId == "encode-poison")
        #expect(record.eventSequence == 11)
        #expect(record.fromCursor == "seq:10")
        #expect(!record.message.isEmpty)
    }

    /// A failure of the read itself (no event to point at) still books, still
    /// counts, and still rebuilds on the second one.
    @Test func aReadFailureAlsoBooksAndRebuilds() async throws {
        let http = TestHTTPTransport(); let realtime = TestRealtimeAPI()
        var date = Date()
        let repo = repository(transport: http, realtime: realtime, now: { date })
        defer { repo.reset() }
        _ = try await repo.open(sessionId: "session")
        let readFailure = TestRecoveryReadFailure()
        realtime.onRecover = { throw readFailure }
        #expect(await syncRound(repo) == false)
        #expect(await syncRound(repo))
        #expect(http.count("snapshot") == 2)
        let record = try #require(repo.recoveryDiagnostics(sessionId: "session").last)
        #expect(record.eventId == nil && record.eventSequence == nil)
        #expect(record.fromCursor == "seq:10")
        #expect(!record.message.isEmpty)
    }

    /// With the path known to be down nothing is booked and nothing rebuilds;
    /// once it returns the retry semantics start over from the first failure.
    @Test func aDownPathBooksNothingAndNeverRebuilds() async throws {
        let http = TestHTTPTransport(); let realtime = TestRealtimeAPI()
        var date = Date()
        let repo = repository(transport: http, realtime: realtime, now: { date })
        defer { repo.reset() }
        _ = try await repo.open(sessionId: "session")
        let poisoned = try poisonedRecovery()
        realtime.onRecover = { poisoned }
        repo.updateConnectivity(V2NetworkStatus(availability: .offline))
        #expect(await syncRound(repo) == false)
        #expect(await syncRound(repo) == false)
        #expect(await syncRound(repo) == false)
        #expect(http.count("snapshot") == 1)
        #expect(repo.recoveryDiagnostics(sessionId: "session").isEmpty)

        repo.updateConnectivity(V2NetworkStatus(availability: .online))
        // One failure after the outage keeps the retry semantics.
        #expect(await syncRound(repo) == false)
        #expect(http.count("snapshot") == 1)
        // The second failure rebuilds.
        #expect(await syncRound(repo))
        #expect(http.count("snapshot") == 2)
    }

    /// The healthy path stays byte-for-byte what it was: nothing booked,
    /// nothing disclosed, the cursor advances as before.
    @Test func aHealthyRoundIsUnchanged() async throws {
        let http = TestHTTPTransport(); let realtime = TestRealtimeAPI()
        var date = Date()
        let repo = repository(transport: http, realtime: realtime, now: { date })
        defer { repo.reset() }
        _ = try await repo.open(sessionId: "session")
        let created = try event("timeline.item_created", seq: 12, id: "live",
                                payload: ["item": itemObject(id: "second", order: 2, seq: 12)])
        realtime.onRecover = { V2EventRecoveryResponse(events: [created], nextCursor: "seq:12", snapshotRequired: false, serverTime: "") }
        #expect(await syncRound(repo))
        #expect(repo.cached(sessionId: "session")?.cursor == "seq:12")
        #expect(repo.cached(sessionId: "session")?.items.count == 2)
        #expect(repo.recoveryDiagnostics(sessionId: "session").isEmpty)
        #expect(repo.session(id: "session").recoveryNotice == nil)
        #expect(http.count("snapshot") == 1)
    }

    /// A diagnostic that outlives the process: the ring rides the session's
    /// existing local archive, so a failure recorded before a relaunch is
    /// still there after it.
    @Test func diagnosticsSurviveARelaunchThroughTheLocalStore() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("aa-recovery-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let http = TestHTTPTransport(); let realtime = TestRealtimeAPI()
        var date = Date()
        let first = localRepository(http, realtime: realtime, local: V2LocalStore(directory: url), now: { date })
        _ = try await first.open(sessionId: "session")
        let poisoned = try poisonedRecovery()
        realtime.onRecover = { poisoned }
        #expect(await syncRound(first) == false)
        let records = first.recoveryDiagnostics(sessionId: "session")
        #expect(records.count == 1)
        await first.flushCache()
        first.reset()

        let restored = localRepository(TestHTTPTransport(), realtime: TestRealtimeAPI(),
                                       local: V2LocalStore(directory: url), now: { date })
        defer { restored.reset() }
        restored.updateConnectivity(V2NetworkStatus(availability: .offline))
        _ = try await restored.load(sessionId: "session")
        #expect(restored.recoveryDiagnostics(sessionId: "session") == records)
    }
}

/// The same repository as `repository(transport:realtime:now:)`, plus the
/// local archive the launch-restoration tests use.
@MainActor private func localRepository(_ http: TestHTTPTransport, realtime: TestRealtimeAPI,
                                        local: V2LocalStore, now: @escaping () -> Date) -> V2SessionRepository {
    let runtime = V2RuntimeAPI(transport: http)
    return V2SessionRepository(
        scope: V2ClientScope(serverURL: URL(string: "https://example.test/api/v2")!, accountID: "account"),
        detail: V2SessionDetailService(sessionAPI: V2SessionAPI(transport: http), runtimeAPI: runtime, realtimeAPI: realtime),
        interactions: V2RuntimeInteractionService(runtimeAPI: runtime), localStore: local,
        now: now, sleep: { _ in try await Task.sleep(for: .milliseconds(1)) })
}

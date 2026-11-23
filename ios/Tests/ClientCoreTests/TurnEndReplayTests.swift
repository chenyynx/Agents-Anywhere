import Foundation
import Testing
@testable import ClientCore

/// End-to-end replay of the 2026-11-22 footer report.
///
/// A turn ends through a stale recovery snapshot (`fresh=0`), and the next
/// background wake — a turn no user bubble opens — takes the finished turn's
/// footer away. The replay drives the real types the chat adapter uses on one
/// refresh: the live `TurnFooterGate`, `TimelineTurnActions.build`'s
/// latest-bucket suppression, and `restoringFinishedFooters` for the closed
/// state. A red run therefore means a reader loses the footer, not that a
/// mock disagreed with itself.
///
/// b1445 evidence (`sess_MnWJXS5vTqBc6Q`): `timeline.state` running→idle at
/// fresh=0 kept `turnEnds` at 0 (00:07:02); the wake at 00:18:29 logged
/// `footer.gate suppress=1 gate=1 running=1` and `turn.footer` hosts went
/// 17→16; the fresh end at 00:21:18 (`turnEnds=1`) brought the host back.
@Suite @MainActor struct TurnEndReplayTests {
    private func row(_ id: String, role: String, text: String) throws -> ChatTimelineRowModel {
        var value = try itemObject(id: id, text: text)
        value["type"] = "message"
        value["role"] = role
        value["status"] = "done"
        return ChatTimelineRowModel(try decode(value))
    }

    private func sessionData(_ status: V2RuntimeStatus, fresh: Bool) throws -> V2SessionData {
        var object = try fixtureObject("snapshot")
        var state = object["state"] as! [String: Any]
        state["status"] = status.rawValue
        object["state"] = state
        var data = V2SessionData(snapshot: try decode(object))
        data.liveStateIsFresh = fresh
        return data
    }

    /// What the chat adapter does on one timeline refresh, minus the views.
    private struct Replay {
        var gate = TurnFooterGate()
        var closed: [String: TimelineTurnAction] = [:]

        mutating func refresh(groups: [ChatTimelineGroup], userKey: String?,
                              userKeyOrder: Int? = nil,
                              stateKnown: Bool = true,
                              running: Bool, ends: Int) -> [String: TimelineTurnAction] {
            let open = gate.update(userKey: userKey, runtimeIsRunning: running,
                                   authoritativeTurnEnds: ends,
                                   userKeyOrder: userKeyOrder)
            var actions = TimelineTurnActions.build(
                groups: groups,
                suppressLatest: TimelineTurnActions.suppressesLatest(
                    latestTurnOpen: open, runtimeIsRunning: running,
                    hasNewerItems: false, runtimeStateKnown: stateKnown))
            if open {
                if gate.isUserlessEpisode {
                    actions = TimelineTurnActions.restoringFinishedFooters(
                        actions, from: closed, groupIDs: Set(groups.map(\.id)))
                }
            } else if stateKnown {
                closed = actions
            }
            return actions
        }
    }

    @Test func aStaleTurnEndKeepsTheFinishedFooterThroughTheBackgroundWake() throws {
        let groups = TimelineGrouping.groups(
            try [row("user-0", role: "user", text: "earlier"),
                 row("user-1", role: "user", text: "go"),
                 row("reply-1", role: "assistant", text: "done")],
            interactionTargets: [])
        let runtime = V2SessionRuntimeModel()
        var replay = Replay()

        // The previous turn settles while the gate is closed.
        runtime.update(try sessionData(.idle, fresh: true), connection: .connected)
        _ = replay.refresh(groups: groups, userKey: "user-0", running: false,
                           ends: runtime.authoritativeTurnEnds)

        // The reader's new turn starts: the gate anchors to its bubble.
        runtime.update(try sessionData(.running, fresh: true), connection: .connected)
        _ = replay.refresh(groups: groups, userKey: "user-1", running: true,
                           ends: runtime.authoritativeTurnEnds)

        // The turn ends inside a recovery snapshot, applied at fresh=0.
        runtime.update(try sessionData(.idle, fresh: false), connection: .connecting)
        let staleIdle = replay.refresh(groups: groups, userKey: "user-1", running: false,
                                       ends: runtime.authoritativeTurnEnds)
        #expect(staleIdle["reply-1"] != nil)

        // Live facts re-confirm the same idle.
        runtime.update(try sessionData(.idle, fresh: true), connection: .connected)
        _ = replay.refresh(groups: groups, userKey: "user-1", running: false,
                           ends: runtime.authoritativeTurnEnds)

        // A background task wakes the runtime; no user bubble opens it.
        runtime.update(try sessionData(.running, fresh: true), connection: .connected)
        let wake = replay.refresh(groups: groups, userKey: "user-1", running: true,
                                  ends: runtime.authoritativeTurnEnds)

        // The finished turn's footer must survive the wake.
        #expect(wake["reply-1"] != nil)
    }

    /// The 2026-11-23 report (`sess_RRBf0biiw2g6WQ`): a steer echo reaches
    /// the timeline as an ordinary user row, then the same item is corrected
    /// to a steering row while its next turn runs. The correction must not
    /// take the finished turn's footer away (hosts 15 → 14 → 16 on device).
    @Test func aCorrectedSteerEchoKeepsTheFinishedFooter() throws {
        var steerValue = try itemObject(id: "steer", text: "steer")
        steerValue["type"] = "message"
        steerValue["role"] = "user"
        steerValue["status"] = "done"
        var steerSource = steerValue["source"] as? [String: Any] ?? [:]
        steerSource["itemType"] = "steeringUserMessage"
        steerValue["source"] = steerSource
        let steeringRow = ChatTimelineRowModel(try decode(steerValue))

        var replay = Replay()
        // The turn settles; its footer is committed.
        let finished = TimelineGrouping.groups(
            try [row("user-0", role: "user", text: "earlier"),
                 row("reply-0", role: "assistant", text: "done")],
            interactionTargets: [])
        let settled = replay.refresh(groups: finished, userKey: "user-0",
                                     userKeyOrder: 10, running: false, ends: 1)
        #expect(settled["reply-0"] != nil)

        // The steer echo arrives first as an ordinary user row.
        let asUser = TimelineGrouping.groups(
            try [row("user-0", role: "user", text: "earlier"),
                 row("reply-0", role: "assistant", text: "done"),
                 row("steer", role: "user", text: "steer")],
            interactionTargets: [])
        let transient = replay.refresh(groups: asUser, userKey: "steer",
                                       userKeyOrder: 30, running: false, ends: 1)
        #expect(transient["reply-0"] != nil)

        // The same item is corrected to a steering row; its next turn runs.
        let corrected = TimelineGrouping.groups(
            try [row("user-0", role: "user", text: "earlier"),
                 row("reply-0", role: "assistant", text: "done"),
                 steeringRow,
                 row("reply-1", role: "assistant", text: "streaming")],
            interactionTargets: [])
        let running = replay.refresh(groups: corrected, userKey: "user-0",
                                     userKeyOrder: 10, running: true, ends: 1)
        #expect(running["reply-0"] != nil)
    }

    /// 2026-11-23 22:04 (build 1541): switching back to the session rebuilt
    /// the view with cached rows before the live runtime state arrived. The
    /// new gate started closed on `status=nil`; committing the streaming
    /// reply stamped it with a footer (hosts 103→104 at 22:04:10.204), and
    /// the running state's userless restore kept it for the whole turn — it
    /// only vanished when the next rebuild dropped the polluted closed map.
    @Test func anUnknownStateOnOpenKeepsTheStreamingReplyUnsealed() throws {
        let streaming = TimelineGrouping.groups(
            try [row("user-0", role: "user", text: "earlier"),
                 row("reply-0", role: "assistant", text: "done"),
                 row("user-1", role: "user", text: "go"),
                 row("reply-1", role: "assistant", text: "streaming")],
            interactionTargets: [])
        var replay = Replay()

        // Cached rows arrive before the live state: unknown is not "idle".
        let opened = replay.refresh(groups: streaming, userKey: "user-1",
                                    userKeyOrder: 30, stateKnown: false,
                                    running: false, ends: 1)
        #expect(opened["reply-1"] == nil)
        #expect(opened["reply-0"] != nil)

        // The live state arrives running: the streaming reply stays unsealed.
        let running = replay.refresh(groups: streaming, userKey: "user-1",
                                     userKeyOrder: 30, stateKnown: true,
                                     running: true, ends: 1)
        #expect(running["reply-1"] == nil)
        #expect(running["reply-0"] != nil)

        // The turn ends: the footer appears on its final reply.
        let ended = replay.refresh(groups: streaming, userKey: "user-1",
                                   userKeyOrder: 30, stateKnown: true,
                                   running: false, ends: 2)
        #expect(ended["reply-1"] != nil)
    }
}

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
                              running: Bool, ends: Int) -> [String: TimelineTurnAction] {
            let open = gate.update(userKey: userKey, runtimeIsRunning: running,
                                   authoritativeTurnEnds: ends)
            var actions = TimelineTurnActions.build(groups: groups,
                                                    suppressLatest: open && running)
            if open {
                if gate.isUserlessEpisode {
                    actions = TimelineTurnActions.restoringFinishedFooters(
                        actions, from: closed, groupIDs: Set(groups.map(\.id)))
                }
            } else {
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
}

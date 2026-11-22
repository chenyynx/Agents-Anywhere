import Foundation
import Testing
@testable import ClientCore

/// A turn ending applied through a stale projection.
///
/// The authoritative end count is the footer gate's only closing signal, and
/// it is deliberately freshness-gated: a status no live source confirmed must
/// not announce a completion. But an ending *observed* while stale used to be
/// dropped for good — the gate stayed open, and the next background wake (a
/// turn no user bubble opens) then suppressed the finished turn's footer until
/// the runtime went idle again (pp 2026-11-22, `sess_MnWJXS5vTqBc6Q`: fresh=0
/// idle at 00:07:02, wake at 00:18:29, footer hosts 17→16 until 00:21:18).
@Suite @MainActor struct TurnEndFreshnessTests {
    /// A recovery snapshot can deliver `running → idle` before live facts
    /// re-confirm freshness. The ending waits for that confirmation instead
    /// of being dropped.
    @Test func aStaleTurnEndIsCountedOnceFreshFactsStillReportIdle() throws {
        let runtime = V2SessionRuntimeModel()
        runtime.update(try sessionData(.running, fresh: true), connection: .connected)
        runtime.update(try sessionData(.idle, fresh: false), connection: .connecting)
        // Stale: observed and drawn, but not yet authoritative.
        #expect(runtime.authoritativeTurnEnds == 0)
        runtime.update(try sessionData(.idle, fresh: true), connection: .connected)
        #expect(runtime.authoritativeTurnEnds == 1)
        #expect(!runtime.lastTurnEndWasStop)
    }

    /// Fresh facts that still report a turn in flight void the deferred
    /// ending: the observation was a flap, and this episode has its own end.
    @Test func aStaleTurnEndIsDiscardedWhenFreshFactsShowTheTurnResumed() throws {
        let runtime = V2SessionRuntimeModel()
        runtime.update(try sessionData(.running, fresh: true), connection: .connected)
        runtime.update(try sessionData(.idle, fresh: false), connection: .connecting)
        runtime.update(try sessionData(.running, fresh: true), connection: .connected)
        #expect(runtime.authoritativeTurnEnds == 0)
        runtime.update(try sessionData(.idle, fresh: true), connection: .connected)
        #expect(runtime.authoritativeTurnEnds == 1)
    }

    /// A stop's ending keeps its identity through the stale window, so the
    /// completion cue still knows the user ended the turn themselves.
    @Test func aDeferredEndCarriesTheStopFlag() throws {
        let runtime = V2SessionRuntimeModel()
        runtime.update(try sessionData(.running, fresh: true), connection: .connected)
        runtime.beginPredictedIdle()
        runtime.update(try sessionData(.idle, fresh: false), connection: .connecting)
        #expect(runtime.authoritativeTurnEnds == 0)
        runtime.update(try sessionData(.idle, fresh: true), connection: .connected)
        #expect(runtime.authoritativeTurnEnds == 1)
        #expect(runtime.lastTurnEndWasStop)
    }

    /// Snapshot payload with only the status swapped, so the projection keeps
    /// the fixture's session identity, capabilities and timeline.
    private func sessionData(_ status: V2RuntimeStatus, fresh: Bool) throws -> V2SessionData {
        var object = try fixtureObject("snapshot")
        var state = object["state"] as! [String: Any]
        state["status"] = status.rawValue
        object["state"] = state
        var data = V2SessionData(snapshot: try decode(object))
        data.liveStateIsFresh = fresh
        return data
    }
}

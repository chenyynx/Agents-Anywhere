import Foundation
import Testing
@testable import ClientCore

/// The durable half of the interrupted-response notice (pp 2026-11-14).
///
/// The connector stamps `content.turnInterrupted` on a stopped turn's last
/// main row (from the CLI's `[Request interrupted by user]` marker plus the
/// live stop itself). This suite pins the client merge: that flag must yield
/// the same anchor the local ack marker uses, must survive a relaunch through
/// the server timeline, and must not double up with the local marker for the
/// same turn.
@Suite struct InterruptedTurnNoticeTests {
    private func item(
        id: String,
        turnID: String?,
        order: Int,
        flagged: Bool = false
    ) throws -> V2TimelineItem {
        var object = try itemObject(id: id, order: order)
        if let turnID { object["turnId"] = turnID }
        var content = object["content"] as! [String: Any]
        if flagged { content[InterruptedTurnMarkers.contentKey] = true }
        object["content"] = content
        return try decode(object)
    }

    @Test func serverFlagBecomesTheNoticeAnchor() throws {
        let markers = InterruptedTurnMarkers.merge(
            local: [],
            timeline: [
                try item(id: "row-1", turnID: "turn-1", order: 1),
                try item(id: "row-2", turnID: "turn-1", order: 2, flagged: true),
            ]
        )
        #expect(markers == [
            V2InterruptedTurnMarker(anchorItemID: "row-2", turnID: "turn-1"),
        ])
    }

    @Test func serverAnchorReplacesALocalAckMarkerForTheSameTurn() throws {
        let local = [V2InterruptedTurnMarker(anchorItemID: "old-anchor", turnID: "turn-1")]
        let markers = InterruptedTurnMarkers.merge(
            local: local,
            timeline: [try item(id: "row-2", turnID: "turn-1", order: 2, flagged: true)]
        )
        #expect(markers == [
            V2InterruptedTurnMarker(anchorItemID: "row-2", turnID: "turn-1"),
        ])
    }

    @Test func localMarkerRemainsWhenNoServerFlagArrived() throws {
        let local = [V2InterruptedTurnMarker(anchorItemID: "row-2", turnID: "turn-1")]
        let markers = InterruptedTurnMarkers.merge(
            local: local,
            timeline: [
                try item(id: "row-1", turnID: "turn-1", order: 1),
                try item(id: "row-2", turnID: "turn-1", order: 2),
            ]
        )
        #expect(markers == local)
    }

    @Test func twoFlaggedRowsOfOneTurnCollapseToOneAnchor() throws {
        let markers = InterruptedTurnMarkers.merge(
            local: [],
            timeline: [
                try item(id: "stale-stamp", turnID: "turn-1", order: 1, flagged: true),
                try item(id: "row-2", turnID: "turn-1", order: 2),
                try item(id: "row-3", turnID: "turn-1", order: 3, flagged: true),
            ]
        )
        #expect(markers == [
            V2InterruptedTurnMarker(anchorItemID: "row-3", turnID: "turn-1"),
        ])
    }

    @Test func unflaggedTurnsProduceNoNotice() throws {
        let markers = InterruptedTurnMarkers.merge(
            local: [],
            timeline: [
                try item(id: "row-1", turnID: "turn-1", order: 1),
                try item(id: "row-2", turnID: "turn-2", order: 2),
            ]
        )
        #expect(markers.isEmpty)
    }

    @Test func authoritativeRecoveryStandsDownOnceADurableMarkerExists() throws {
        // Device 2026-11-14: one stop, two cards. The durable marker sits on
        // the stopped turn; the recovery then ran again after the next prompt
        // landed and anchored a second marker on that prompt's row.
        let timeline = [
            try item(id: "row-1", turnID: "turn-1", order: 1),
            try item(id: "row-2", turnID: "turn-1", order: 2, flagged: true),
            try item(id: "row-3", turnID: "turn-2", order: 3),
        ]
        let existing = InterruptedTurnMarkers.merge(local: [], timeline: timeline)
        #expect(InterruptedTurnMarkers.authoritativeAnchor(
            timeline: timeline, existing: existing, isIdleInterrupt: true
        ) == nil)
    }

    @Test func authoritativeRecoveryAnchorsTheNewestRowForALegacyConnector() throws {
        let timeline = [
            try item(id: "row-1", turnID: "turn-1", order: 1),
            try item(id: "row-2", turnID: "turn-1", order: 2),
        ]
        #expect(InterruptedTurnMarkers.authoritativeAnchor(
            timeline: timeline, existing: [], isIdleInterrupt: true
        ) == V2InterruptedTurnMarker(anchorItemID: "row-2", turnID: "turn-1"))
    }

    @Test func authoritativeRecoveryRequiresTheInterruptedIdleState() throws {
        let timeline = [try item(id: "row-1", turnID: "turn-1", order: 1)]
        #expect(InterruptedTurnMarkers.authoritativeAnchor(
            timeline: timeline, existing: [], isIdleInterrupt: false
        ) == nil)
    }

    @Test func authoritativeRecoveryLeavesAnAlreadyAnchoredRowAlone() throws {
        let timeline = [try item(id: "row-1", turnID: "turn-1", order: 1)]
        let existing = [V2InterruptedTurnMarker(anchorItemID: "row-1", turnID: "turn-1")]
        #expect(InterruptedTurnMarkers.authoritativeAnchor(
            timeline: timeline, existing: existing, isIdleInterrupt: true
        ) == nil)
    }
}

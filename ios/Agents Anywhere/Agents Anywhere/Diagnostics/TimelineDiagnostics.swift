import Foundation

/// Client-side timeline invariants worth recording. These checks run only when
/// the reader enabled diagnostics; when disabled they return immediately.
///
/// The server is the ordering authority. This validator does not repair
/// anything: it records what the client actually received and grouped, so a
/// later reader can tell a transport loss from a display/grouping defect.
nonisolated enum TimelineDiagnostics {
    /// Counts that describe what the chat grouping actually produced. Logged
    /// as a compact `timeline.grouping` trail entry when the shape changes, so
    /// a later reader can tell "row missing" from "row grouped into a step".
    static func groupingSummary(
        rows: [V2TimelineItem],
        units: [TimelineChatUnit]
    ) -> [String: String] {
        let userRows = rows.filter {
            $0.type == .message && $0.role == .user
        }
        let rendered = Set(units.flatMap { $0.rowIDs })
        var stepGroups = 0
        var messageUnits = 0
        var standalone = 0
        for unit in units {
            switch unit {
            case .stepGroup(_, _): stepGroups += 1
            case .message(_, _): messageUnits += 1
            case .standalone(_): standalone += 1
            }
        }
        return [
            "rows": String(rows.count),
            "units": String(units.count),
            "stepGroups": String(stepGroups),
            "messageUnits": String(messageUnits),
            "standalone": String(standalone),
            "userRows": String(userRows.count),
            "userRendered": String(
                userRows.filter { rendered.contains($0.id) }.count),
            "userUnrendered": String(
                userRows.filter { !rendered.contains($0.id) }.count),
        ]
    }

    /// Duplicate and non-positive `orderSeq` values in a held window.
    static func validateOrder(
        sessionID: String,
        items: [V2TimelineItem],
        log: ClientDiagnosticsLog = .shared
    ) {
        guard log.isEnabled, !items.isEmpty else { return }
        let sorted = items.sorted {
            $0.orderSeq == $1.orderSeq
                ? $0.id < $1.id
                : $0.orderSeq < $1.orderSeq
        }
        var index = 0
        while index < sorted.count {
            var end = index + 1
            while end < sorted.count,
                  sorted[end].orderSeq == sorted[index].orderSeq {
                end += 1
            }
            if end - index > 1 {
                let group = sorted[index..<end]
                log.record(
                    kind: "timeline.order.duplicate",
                    sessionID: sessionID,
                    detail: [
                        "orderSeq": String(sorted[index].orderSeq),
                        "count": String(end - index),
                        "ids": group.prefix(4).map(\.id).joined(separator: ","),
                    ]
                )
            }
            index = end
        }
        let nonPositive = sorted.filter { $0.orderSeq <= 0 }
        if !nonPositive.isEmpty {
            log.record(
                kind: "timeline.order.nonpositive",
                sessionID: sessionID,
                detail: [
                    "count": String(nonPositive.count),
                    "ids": nonPositive.prefix(4).map(\.id).joined(separator: ","),
                ]
            )
        }
    }

    /// A user message in the held window that no chat unit rendered. This is
    /// the 2026-11-10 "message disappeared after the report body" symptom: the
    /// row is present in the window, but the grouped output has no row for it.
    static func validateUnits(
        sessionID: String,
        rows: [V2TimelineItem],
        units: [TimelineChatUnit],
        log: ClientDiagnosticsLog = .shared
    ) {
        guard log.isEnabled, !rows.isEmpty else { return }
        let rendered = Set(units.flatMap { $0.rowIDs })
        let sorted = rows.sorted {
            $0.orderSeq == $1.orderSeq
                ? $0.id < $1.id
                : $0.orderSeq < $1.orderSeq
        }
        for (index, item) in sorted.enumerated()
        where item.type == .message && item.role == .user {
            guard !rendered.contains(item.id) else { continue }
            var detail = ["id": item.id, "orderSeq": String(item.orderSeq)]
            if index > 0 { detail["prev"] = sorted[index - 1].id }
            if index + 1 < sorted.count { detail["next"] = sorted[index + 1].id }
            log.record(
                kind: "timeline.user_message.unrendered",
                sessionID: sessionID,
                detail: detail
            )
        }
        validateOrder(sessionID: sessionID, items: rows, log: log)
    }
}

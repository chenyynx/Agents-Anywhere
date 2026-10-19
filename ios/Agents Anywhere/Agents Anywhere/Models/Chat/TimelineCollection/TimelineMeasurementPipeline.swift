import Foundation

nonisolated enum TimelineMeasurementContent: Equatable {
    /// No Markdown constructs: TextKit 2 can precalc it cheaply.
    case plainText
    /// Markdown, tables, code fences: the renderer is a SwiftUI view, so the
    /// only measurement consistent with rendering is an offscreen hosting pass.
    case markdown
    /// Attachments/images or other non-text content with an aspect-dependent
    /// height. Also hosting.
    case complex
    /// Fold/inline-notice rows: measured in hosting, but the cell may correct
    /// the height later within its controlled-exception policy.
    case interactive
    case tail
}

nonisolated enum TimelineMeasurementRoute: Equatable {
    case textKit2Precalc
    case hosting
}

nonisolated struct TimelineMeasurementRequest: Equatable {
    let itemID: String
    let key: TimelineHeightKey
    let content: TimelineMeasurementContent
    /// Streaming rows are re-measured on every throttled tick; Markdown
    /// measurement must still go through hosting.
    let isStreaming: Bool
    /// Caller-estimated cost in whole milliseconds. Whole milliseconds keep
    /// budget arithmetic exact; the real pipeline measures throughput and
    /// converts before planning.
    let estimatedCostMilliseconds: Int
}

nonisolated struct TimelineMeasurementPlan: Equatable {
    /// Measured before the snapshot is applied, in the given priority order.
    let measureBeforeApply: [TimelineMeasurementRequest]
    /// Deferred: the row is inserted with displayed/estimate height and marked
    /// pending, then measured outside the scroll path.
    let pending: [TimelineMeasurementRequest]
}

/// Pre-apply measurement planner.
///
/// A history page is planned as a whole (all 100 rows), because the prepend
/// anchor is only exact if every row above it has a real height. Opening
/// plans the visible window ± one screen; streaming plans the throttled rows.
/// The budget is a hard cutoff: the caller measures the prefix before apply
/// and the rest as pending. The budget value comes from the C2 throughput
/// measurement, not from this file.
nonisolated struct TimelineMeasurementPipeline: Equatable {
    let budgetMilliseconds: Int
    private(set) var pendingItemIDs: Set<String>

    init(budgetMilliseconds: Int) {
        self.budgetMilliseconds = max(0, budgetMilliseconds)
        pendingItemIDs = []
    }

    /// Markdown/complex/interactive/tail rows never take the plain-text
    /// precalc path — Textual only exposes `StructuredText` as a view, and a
    /// precalc that disagrees with the renderer would reintroduce the jump
    /// this pipeline exists to remove.
    static func route(for content: TimelineMeasurementContent) -> TimelineMeasurementRoute {
        switch content {
        case .plainText: return .textKit2Precalc
        case .markdown, .complex, .interactive, .tail: return .hosting
        }
    }

    mutating func plan(_ requests: [TimelineMeasurementRequest]) -> TimelineMeasurementPlan {
        var measured: [TimelineMeasurementRequest] = []
        var pending: [TimelineMeasurementRequest] = []
        var used = 0
        for request in requests {
            let cost = max(0, request.estimatedCostMilliseconds)
            if used + cost <= budgetMilliseconds {
                measured.append(request)
                used += cost
            } else {
                pending.append(request)
            }
        }
        let requested = Set(requests.map(\.itemID))
        // Carry an outstanding measurement only while the item is still part
        // of this snapshot; a measured item is no longer pending.
        pendingItemIDs.formIntersection(requested)
        pendingItemIDs.subtract(measured.map(\.itemID))
        pendingItemIDs.formUnion(pending.map(\.itemID))
        return TimelineMeasurementPlan(measureBeforeApply: measured, pending: pending)
    }

    /// Returns true when the completion was for a row inserted as pending, so
    /// the controller knows a height correction (not a first measurement) is
    /// due.
    mutating func complete(_ itemID: String) -> Bool {
        pendingItemIDs.remove(itemID) != nil
    }
}
